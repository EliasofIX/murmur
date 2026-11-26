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

/// Wraps transcribe.cpp (Metal) running Granite Speech 4.1. All calls are serialised on one queue.
final class Transcriber: @unchecked Sendable {
    static let modelName = "granite-speech-4.1-2b-Q5_K_M.gguf"
    static var modelURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur/models/\(modelName)")
    }

    private let queue = DispatchQueue(label: "murmur.transcribe", qos: .userInteractive)
    private var session: OpaquePointer?
    private(set) var maxAudioSeconds: Double = 60

    func load(_ completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            let path = Self.modelURL.path
            guard FileManager.default.fileExists(atPath: path) else {
                return completion(.failure(TranscriberError.modelMissing(path)))
            }
            _ = transcribe_init_backends_default()
            var lp = transcribe_model_load_params()
            transcribe_model_load_params_init(&lp)
            var sp = transcribe_session_params()
            transcribe_session_params_init(&sp)
            var s: OpaquePointer?
            let status = transcribe_open(path, &lp, &sp, &s)
            guard status == TRANSCRIBE_OK, let s else {
                return completion(.failure(TranscriberError.load(Int32(status.rawValue))))
            }
            session = s

            var limits = transcribe_session_limits()
            transcribe_session_limits_init(&limits)
            if transcribe_session_get_limits(s, &limits) == TRANSCRIBE_OK, limits.effective_max_audio_ms > 0 {
                maxAudioSeconds = Double(limits.effective_max_audio_ms) / 1000
            }

            // Warm up: compiles the Metal pipelines so the first real dictation is fast.
            var noise = [Float](repeating: 0, count: 16_000 * 2)
            for i in noise.indices { noise[i] = Float.random(in: -0.02...0.02) }
            _ = try? run(noise, language: nil)
            completion(.success(()))
        }
    }

    func transcribe(_ pcm: [Float], language: String?, completion: @escaping @Sendable (Result<String, Error>) -> Void) {
        queue.async { [self] in
            completion(Result { try run(pcm, language: language) })
        }
    }

    private func run(_ pcm: [Float], language: String?) throws -> String {
        guard let session else { throw TranscriberError.load(-1) }
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
        guard status == TRANSCRIBE_OK else { throw TranscriberError.run(Int32(status.rawValue)) }
        guard let c = transcribe_full_text(session) else { return "" }
        return String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
