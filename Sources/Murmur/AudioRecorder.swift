import AVFoundation

enum RecorderError: Error { case noInput }

/// Captures the default microphone as 16 kHz mono float PCM.
final class AudioRecorder: @unchecked Sendable {
    let meter = LevelMeter()
    /// Each converted chunk, on the audio thread. The buffer is only valid for the call.
    var onSamples: ((UnsafeBufferPointer<Float>) -> Void)?

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var samples: [Float] = []
    private var voicedSamples = 0

    /// Seconds of audio that were clearly louder than the noise floor.
    var voicedSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(voicedSamples) / 16_000
    }

    func start() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInput }
        converter = AVAudioConverter(from: format, to: outFormat)

        lock.lock()
        samples.removeAll(keepingCapacity: true)
        samples.reserveCapacity(16_000 * 30)
        voicedSamples = 0
        lock.unlock()
        meter.target = 0

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    /// Stops capture and returns everything recorded.
    func stop() -> [Float] {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        meter.target = 0
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    var duration: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(samples.count) / 16_000
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData?[0], out.frameLength > 0 else { return }
        let count = Int(out.frameLength)
        let chunk = UnsafeBufferPointer(start: channel, count: count)

        var sum: Float = 0
        for s in chunk { sum += s * s }
        let rms = (sum / Float(count)).squareRoot()
        meter.target = LevelMeter.level(forRMS: rms)
        onSamples?(chunk)

        lock.lock()
        samples.append(contentsOf: chunk)
        if rms > 0.006 { voicedSamples += count }   // about -44 dBFS
        lock.unlock()
    }
}
