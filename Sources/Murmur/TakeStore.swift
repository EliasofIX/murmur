import Foundation

/// Durably stores the newest dictation as a 16 kHz mono float WAV.
///
/// Audio is appended while recording and flushed every second, so a crash keeps
/// everything already captured. `commit` finishes the file before transcription
/// starts, which is what makes a later retry possible.
final class TakeStore: @unchecked Sendable {
    static let shared = TakeStore()
    static let sampleRate = 16_000

    private let queue = DispatchQueue(label: "murmur.takes")
    private let directory: URL
    private var handle: FileHandle?
    private var frames = 0
    private var syncedFrames = 0

    private var currentURL: URL { directory.appendingPathComponent("current.wav") }
    private var lastURL: URL { directory.appendingPathComponent("last.wav") }
    private var pendingURL: URL { directory.appendingPathComponent("last.pending") }
    private var transcriptURL: URL { directory.appendingPathComponent("last.txt") }

    private init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur/takes")
        queue.sync { recoverInterrupted() }
    }

    /// True when a finished (or crash-recovered) recording is waiting on disk.
    var hasLast: Bool {
        queue.sync {
            guard let size = try? FileManager.default.attributesOfItem(atPath: lastURL.path)[.size] as? Int else { return false }
            return size > 44
        }
    }

    /// True when the saved recording never produced text the user received.
    var isPending: Bool {
        queue.sync { FileManager.default.fileExists(atPath: pendingURL.path) }
    }

    func begin() {
        queue.sync {
            closeHandle()
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                fm.createFile(atPath: currentURL.path, contents: Self.header(dataBytes: 0))
                let handle = try FileHandle(forWritingTo: currentURL)
                try handle.seekToEnd()
                self.handle = handle
                frames = 0
                syncedFrames = 0
            } catch {
                NSLog("Murmur could not start saving the recording: \(error)")
            }
        }
    }

    /// Copies the chunk and writes it off the audio thread.
    func append(_ samples: UnsafeBufferPointer<Float>) {
        guard !samples.isEmpty else { return }
        let copy = Array(samples)
        queue.async { [self] in self.write(copy) }
    }

    /// Drops an in-progress take. The previous saved recording stays.
    func discard() {
        queue.sync {
            closeHandle()
            try? FileManager.default.removeItem(at: currentURL)
        }
    }

    /// Finishes the file, fsyncs it, and makes it the recording a retry will use.
    func commit() {
        queue.sync {
            guard let handle else { return }
            do {
                try patchHeader(handle)
                try handle.synchronize()
                try handle.close()
                self.handle = nil
                let fm = FileManager.default
                if fm.fileExists(atPath: lastURL.path) { try? fm.removeItem(at: lastURL) }
                try fm.moveItem(at: currentURL, to: lastURL)
                fm.createFile(atPath: pendingURL.path, contents: Data())
                try? fm.removeItem(at: transcriptURL)
            } catch {
                NSLog("Murmur could not save the recording: \(error)")
                closeHandle()
            }
        }
    }

    func loadLast() -> [Float]? {
        queue.sync { Self.readWAV(lastURL) }
    }

    /// Remembers a transcript so a later failure can still deliver the words.
    func markDelivered(text: String) {
        queue.sync {
            try? text.write(to: transcriptURL, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: pendingURL)
        }
    }

    func savedTranscript() -> String? {
        queue.sync {
            guard let text = try? String(contentsOf: transcriptURL, encoding: .utf8) else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    // MARK: - Disk

    /// A recording that died mid-take is still the newest one. Promote it.
    private func recoverInterrupted() {
        let fm = FileManager.default
        guard let size = try? fm.attributesOfItem(atPath: currentURL.path)[.size] as? Int, size > 44 else { return }
        if fm.fileExists(atPath: lastURL.path) { try? fm.removeItem(at: lastURL) }
        do {
            try fm.moveItem(at: currentURL, to: lastURL)
            fm.createFile(atPath: pendingURL.path, contents: Data())
            try? fm.removeItem(at: transcriptURL)
            NSLog("Murmur recovered an interrupted recording")
        } catch {
            NSLog("Murmur could not recover the interrupted recording: \(error)")
        }
    }

    private func write(_ samples: [Float]) {
        guard let handle, !samples.isEmpty else { return }
        do {
            let data = samples.withUnsafeBytes { Data($0) }
            try handle.write(contentsOf: data)
            frames += samples.count
            if frames - syncedFrames >= Self.sampleRate {
                try patchHeader(handle)
                try handle.synchronize()
                syncedFrames = frames
            }
        } catch {
            NSLog("Murmur could not write audio: \(error)")
        }
    }

    private func closeHandle() {
        try? handle?.close()
        handle = nil
    }

    private func patchHeader(_ handle: FileHandle) throws {
        let bytes = UInt32(clamping: frames * MemoryLayout<Float>.size)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(dataBytes: bytes))
        try handle.seek(toOffset: UInt64(44) + UInt64(bytes))
    }

    private static func header(dataBytes: UInt32) -> Data {
        var data = Data(capacity: 44)
        func u32(_ value: UInt32) { var le = value.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { var le = value.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        data.append(contentsOf: "RIFF".utf8)
        u32(36 + dataBytes)
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        u32(16)
        u16(3)              // IEEE float
        u16(1)
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * 4))
        u16(4)
        u16(32)
        data.append(contentsOf: "data".utf8)
        u32(dataBytes)
        return data
    }

    /// Reads our own WAVs. A torn header still yields the samples that follow the 44-byte prefix.
    private static func readWAV(_ url: URL) -> [Float]? {
        guard let data = try? Data(contentsOf: url), data.count > 44 else { return nil }
        let count = (data.count - 44) / MemoryLayout<Float>.size
        guard count > 0 else { return nil }
        return data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return [] }
            let pointer = base.advanced(by: 44).assumingMemoryBound(to: Float.self)
            return Array(UnsafeBufferPointer(start: pointer, count: count))
        }
    }
}
