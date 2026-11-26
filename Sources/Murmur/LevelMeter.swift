import Foundation

/// Thread-safe audio level shared between the capture thread and the UI.
final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var _target: Float = 0

    /// Normalised 0...1 loudness of the most recent audio buffer.
    var target: Float {
        get { lock.lock(); defer { lock.unlock() }; return _target }
        set { lock.lock(); _target = newValue; lock.unlock() }
    }

    static func level(forRMS rms: Float) -> Float {
        let db = 20 * log10(max(rms, 1e-6))
        return min(max((db + 55) / 40, 0), 1)
    }
}
