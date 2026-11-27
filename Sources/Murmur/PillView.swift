import AppKit
import SwiftUI

/// Smooths the raw mic level and keeps a short history that radiates out from the centre.
@MainActor
final class WaveState {
    static let bars = 10                // centre + 9 mirrored => 19 bars
    var history = [Float](repeating: 0, count: WaveState.bars)
    var smoothed: Float = 0
    var processing: Float = 0           // 0 = listening, 1 = thinking
    private var lastPush: Double = 0
    private var lastFrame: Double = 0

    func advance(now: Double, target: Float, isProcessing: Bool) {
        let dt = Float(min(max(now - lastFrame, 0), 0.1))
        lastFrame = now
        let rate: Float = target > smoothed ? 24 : 9
        smoothed += (target - smoothed) * min(1, rate * dt)
        processing += ((isProcessing ? 1 : 0) - processing) * min(1, 8 * dt)
        if now - lastPush > 1.0 / 40 {
            lastPush = now
            history.removeLast()
            history.insert(smoothed, at: 0)
        }
    }
}

/// Content that sits *inside* the panel's NSGlassEffectView. No scale/opacity effects here:
/// those would flatten the glass, so all size and fade animation is done by AppKit on the panel.
struct PillContentView: View {
    let model: PillModel
    @State private var wave = WaveState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            switch model.phase {
            case .listening:
                ListeningNotch(wave: wave, meter: model.meter, started: model.recordingStarted)
            case .processing:
                Waveform(wave: wave, meter: model.meter, isProcessing: true, reduceMotion: reduceMotion)
            case .done:
                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
            case .message(let text):
                Text(text)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .padding(.horizontal, 18)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.2), value: model.phase)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch model.phase {
        case .listening: "Listening"
        case .processing: "Transcribing"
        case .done: "Dictation inserted"
        case .message(let text): text
        }
    }
}

/// The listening pill's bars and centre label, at rest. Shared by the windows so they
/// are the same object, opened, rather than a settings icon.
struct PillMark: View {
    var title: String

    var body: some View {
        HStack(spacing: 7) {
            PillMarkBars(innerOnTheRight: true)
            Text(title)
                .font(.title3.weight(.medium).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            PillMarkBars(innerOnTheRight: false)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

private struct PillMarkBars: View {
    var innerOnTheRight: Bool

    var body: some View {
        HStack(spacing: 3.2) {
            ForEach(0..<5, id: \.self) { index in
                let fromCenter = innerOnTheRight ? Double(4 - index) : Double(index)
                let envelope = 1 - 0.45 * pow(fromCenter / 4, 1.5)
                let fade = 1 - 0.5 * fromCenter / 4
                Capsule()
                    .fill(.primary.opacity(0.92 * fade))
                    .frame(width: 3, height: 6 + 16 * envelope)
            }
        }
        .frame(height: 28)
        .accessibilityHidden(true)
    }
}

/// Time in the middle, bars mirrored on either side.
private struct ListeningNotch: View {
    let wave: WaveState
    let meter: LevelMeter?
    let started: Date?

    private static let bars = 5
    private static let step: CGFloat = 6.2
    private static let barWidth: CGFloat = 3
    static let columnWidth: CGFloat = CGFloat(bars - 1) * step + barWidth

    var body: some View {
        TimelineView(.animation) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 7) {
                sideBars(.innerRight, now: now, advances: true)
                ListeningClock(started: started)
                sideBars(.innerLeft, now: now, advances: false)
            }
            .padding(.horizontal, 14)
        }
    }

    private enum InnerEdge { case innerLeft, innerRight }

    private func sideBars(_ edge: InnerEdge, now: Double, advances: Bool) -> some View {
        Canvas { ctx, size in
            if advances {
                wave.advance(now: now, target: meter?.target ?? 0, isProcessing: false)
            }
            let minH: CGFloat = 3.5
            let maxH = size.height * 0.56
            let n = Self.bars
            for d in 0..<n {
                let dist = Double(d)
                let envelope = 1 - 0.45 * pow(dist / Double(n), 1.5)
                let v = min(1, Double(wave.history[d]) * envelope)
                let h = minH + (maxH - minH) * CGFloat(v)
                let x = edge == .innerRight
                    ? size.width - Self.barWidth - CGFloat(d) * Self.step
                    : CGFloat(d) * Self.step
                let rect = CGRect(x: x, y: (size.height - h) / 2, width: Self.barWidth, height: h)
                let fade = 1 - 0.5 * dist / Double(n)
                ctx.fill(
                    Path(roundedRect: rect, cornerRadius: Self.barWidth / 2),
                    with: .color(.primary.opacity(0.92 * fade)))
            }
        }
        .frame(width: Self.columnWidth)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Elapsed recording time, counting up in the middle of the listening pill.
private struct ListeningClock: View {
    let started: Date?

    var body: some View {
        Group {
            if let started {
                Text(
                    timerInterval: started...started.addingTimeInterval(24 * 60 * 60),
                    countsDown: false,
                    showsHours: false
                )
            } else {
                Text("0:00")
            }
        }
        .font(.title3.weight(.medium).monospacedDigit())
        .foregroundStyle(.primary)
        .lineLimit(1)
        .frame(width: 50)
        .accessibilityHidden(true)
    }
}

/// Quiet monochrome level bars that grow outward from the centre as you speak.
private struct Waveform: View {
    let wave: WaveState
    let meter: LevelMeter?
    let isProcessing: Bool
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                wave.advance(now: t, target: meter?.target ?? 0, isProcessing: isProcessing)

                let n = WaveState.bars
                let barWidth: CGFloat = 3
                let step: CGFloat = 6.2
                let minH: CGFloat = 3.5
                let maxH = size.height * 0.56
                let mix = Double(wave.processing)

                for side in [-1, 1] {
                    for d in 0..<n {
                        if side == -1 && d == 0 { continue }
                        let dist = Double(d)
                        let envelope = 1 - 0.45 * pow(dist / Double(n), 1.5)
                        let live = Double(wave.history[d]) * envelope
                        // Thinking: a gentle travelling swell instead of voice.
                        let phase = reduceMotion ? 0 : t * 3.2 - dist * 0.55
                        let swell = 0.14 + 0.1 * sin(phase)
                        let v = min(1, live * (1 - mix) + swell * mix)
                        let h = minH + (maxH - minH) * CGFloat(v)
                        let x = size.width / 2 + CGFloat(side * d) * step - barWidth / 2
                        let rect = CGRect(x: x, y: (size.height - h) / 2, width: barWidth, height: h)
                        let fade = 1 - 0.5 * dist / Double(n)
                        ctx.fill(
                            Path(roundedRect: rect, cornerRadius: barWidth / 2),
                            with: .color(.primary.opacity(0.92 * fade)))
                    }
                }
            }
        }
    }
}
