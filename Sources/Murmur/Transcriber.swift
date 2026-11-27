import CTranscribe
import Foundation

enum TranscriberError: LocalizedError {
    case modelMissing(String)
    case load(Int32)
    case run(Int32)

    var errorDescription: String? {
        switch self {
        case .modelMissing(let p): "Model not found at \(p)"
        case .load(let c): "Could not load model (code \(c))"
        case .run(let c): "Transcription failed (code \(c))"
        }
    }
}

/// Wraps transcribe.cpp (Metal) running Parakeet TDT 0.6B v3. All calls are serialised on one queue.
final class Transcriber: @unchecked Sendable {
    static let modelName = "parakeet-tdt-0.6b-v3-Q5_K_M.gguf"
    static var modelURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur/models/\(modelName)")
    }

    private let queue = DispatchQueue(label: "murmur.transcribe", qos: .userInteractive)
    private var session: OpaquePointer?
    /// Longest clip this session will accept, in seconds. `0` means the model has no ceiling.
    private(set) var maxAudioSeconds: Double = 0

    func load(_ completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            do {
                try openSession()
                // Warm up: compiles the Metal pipelines so the first real dictation is fast.
                var noise = [Float](repeating: 0, count: 16_000 * 2)
                for i in noise.indices { noise[i] = Float.random(in: -0.02...0.02) }
                _ = try? run(noise, language: nil)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func transcribe(_ pcm: [Float], language: String?, completion: @escaping @Sendable (Result<String, Error>) -> Void) {
        queue.async { [self] in
            completion(Result { try transcribeReliably(pcm, language: language) })
        }
    }

    /// One pass when the clip fits in the model. A longer clip is cut into pieces that fit.
    /// A killed process cannot be caught here; the recording is already on disk by then.
    private func transcribeReliably(_ pcm: [Float], language: String?) throws -> String {
        let rate = 16_000
        if maxAudioSeconds > 0, Double(pcm.count) / Double(rate) > maxAudioSeconds {
            let piece = max(rate * 5, Int(maxAudioSeconds * Double(rate)) - rate)
            return try transcribeInPieces(pcm, language: language, piece: piece)
        }
        do { return try run(pcm, language: language) }
        catch {
            NSLog("Murmur transcription failed: \(error)")
            if isFatal(error) { throw error }
            Thread.sleep(forTimeInterval: 0.4)
            try openSession()
            do { return try run(pcm, language: language) }
            catch let retry {
                NSLog("Murmur transcription retry failed: \(retry)")
                if isFatal(retry) || pcm.count <= rate * 20 { throw retry }
                return try transcribeInPieces(pcm, language: language, piece: rate * 20)
            }
        }
    }

    private func transcribeInPieces(_ pcm: [Float], language: String?, piece: Int) throws -> String {
        var parts: [String] = []
        var start = 0
        while start < pcm.count {
            var end = min(pcm.count, start + piece)
            if end < pcm.count { end = quietSplit(pcm, near: end, limit: piece) }
            let slice = Array(pcm[start..<end])
            let text = try runPiece(slice, language: language)
            if !text.isEmpty { parts.append(text) }
            start = end
        }
        return parts.joined(separator: " ")
    }

    private func runPiece(_ pcm: [Float], language: String?) throws -> String {
        do { return try run(pcm, language: language) }
        catch {
            NSLog("Murmur chunk failed, reloading: \(error)")
            if isFatal(error) { throw error }
            try openSession()
            return try run(pcm, language: language)
        }
    }

    /// Splits near a quiet moment so a word is less likely to be cut in half.
    private func quietSplit(_ pcm: [Float], near: Int, limit: Int) -> Int {
        let window = 320
        let radius = min(16_000, limit / 4)
        let lower = max(window, near - radius)
        let upper = min(pcm.count - window, near + radius)
        guard lower < upper else { return near }
        var best = near
        var bestEnergy = Float.greatestFiniteMagnitude
        var index = lower
        while index < upper {
            var sum: Float = 0
            for sample in pcm[index..<(index + window)] { sum += sample * sample }
            if sum < bestEnergy {
                bestEnergy = sum
                best = index + window / 2
            }
            index += window
        }
        return best
    }

    private func isFatal(_ error: Error) -> Bool {
        guard case TranscriberError.run(let code) = error else { return false }
        return code == numeric(TRANSCRIBE_ERR_INPUT_TOO_SHORT)
            || code == numeric(TRANSCRIBE_ERR_INVALID_ARG)
            || code == numeric(TRANSCRIBE_ERR_UNSUPPORTED_LANGUAGE)
            || code == numeric(TRANSCRIBE_ERR_NOT_IMPLEMENTED)
    }

    private func numeric(_ status: transcribe_status) -> Int32 { Int32(status.rawValue) }

    private func openSession() throws {
        if let session {
            transcribe_close(session)
            self.session = nil
        }
        let path = Self.modelURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw TranscriberError.modelMissing(path)
        }
        _ = transcribe_init_backends_default()
        var lp = transcribe_model_load_params()
        transcribe_model_load_params_init(&lp)
        var sp = transcribe_session_params()
        transcribe_session_params_init(&sp)
        var opened: OpaquePointer?
        let status = transcribe_open(path, &lp, &sp, &opened)
        guard status == TRANSCRIBE_OK, let opened else {
            throw TranscriberError.load(Int32(status.rawValue))
        }
        session = opened

        var limits = transcribe_session_limits()
        transcribe_session_limits_init(&limits)
        if transcribe_session_get_limits(opened, &limits) == TRANSCRIBE_OK, limits.effective_max_audio_ms > 0 {
            maxAudioSeconds = Double(limits.effective_max_audio_ms) / 1000
        } else {
            maxAudioSeconds = 0
        }
    }

    private func run(_ pcm: [Float], language: String?) throws -> String {
        guard let session else { throw TranscriberError.load(-1) }
        guard pcm.count <= Int(Int32.max) else { throw TranscriberError.run(numeric(TRANSCRIBE_ERR_INPUT_TOO_LONG)) }
        var rp = transcribe_run_params()
        transcribe_run_params_init(&rp)
        rp.task = TRANSCRIBE_TASK_TRANSCRIBE
        rp.timestamps = TRANSCRIBE_TIMESTAMPS_NONE

        func go() -> transcribe_status {
            pcm.withUnsafeBufferPointer { transcribe_run(session, $0.baseAddress, Int32($0.count), &rp) }
        }
        let status: transcribe_status
        if let language {
            status = language.withCString { rp.language = $0; return go() }
        } else {
            status = go()
        }
        // Truncation and repetition still leave a readable partial transcript.
        let usable = status == TRANSCRIBE_OK
            || status == TRANSCRIBE_ERR_OUTPUT_TRUNCATED
            || status == TRANSCRIBE_ERR_OUTPUT_REPETITION
        guard usable else { throw TranscriberError.run(Int32(status.rawValue)) }
        guard let c = transcribe_full_text(session) else { return "" }
        return String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
