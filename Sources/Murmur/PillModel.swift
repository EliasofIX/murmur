import Observation

enum PillPhase: Equatable {
    case listening
    case processing
    case done
    case message(String)
}

@MainActor @Observable
final class PillModel {
    var visible = false
    var phase: PillPhase = .listening
    /// Live loudness source, polled by the waveform every frame (not observed).
    @ObservationIgnored var meter: LevelMeter?
}
