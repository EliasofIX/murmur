import AppKit

/// Turns Left-Option gestures into: record → transcribe → insert.
///   • hold ≥ 0.2 s, release → push‑to‑talk
///   • double‑tap → hands‑free; tap once more (or Esc) to finish
@MainActor
final class DictationController {
    private enum State {
        case idle
        case pressed(since: TimeInterval)   // Option is down, deciding between tap and hold
        case latched                        // hands-free listening
        case latchedStopping                // waiting for the key-up of the press that ends hands-free
        case processing
    }

    private let recorder = AudioRecorder()
    private let transcriber: Transcriber
    private let panel: PillPanel
    private let settings = AppSettings.shared

    private var state: State = .idle
    private var lastTapUp: TimeInterval = 0
    private var pillWork: DispatchWorkItem?
    private var autoStop: DispatchWorkItem?

    private let tapThreshold: TimeInterval = 0.2
    private let doubleTapWindow: TimeInterval = 0.4

    init(transcriber: Transcriber, panel: PillPanel) {
        self.transcriber = transcriber
        self.panel = panel
        panel.model.meter = recorder.meter
    }

    func handle(_ event: HotkeyMonitor.Event) {
        let now = ProcessInfo.processInfo.systemUptime
        switch (event, state) {
        case (.optionDown, .idle):
            guard settings.modelReady else {
                panel.present(.message(settings.modelError == nil ? "Warming up…" : "Model unavailable"))
                panel.dismiss(after: 1.4)
                return
            }
            let isSecondTap = now - lastTapUp < doubleTapWindow
            guard beginRecording() else { return }
            state = .pressed(since: now)
            if isSecondTap {
                latch()
            } else {
                // Only show the pill once we know it's a hold, so stray taps never flicker.
                let work = DispatchWorkItem { [weak self] in self?.showListening() }
                pillWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + tapThreshold, execute: work)
            }

        case (.optionUp, .pressed(let since)):
            if now - since < tapThreshold {
                // A quick tap: wait for a second one.
                lastTapUp = now
                cancelRecording(silently: true)
            } else {
                finish()
            }

        case (.optionDown, .latched):
            state = .latchedStopping
            finish()

        case (.optionUp, .latchedStopping), (.optionUp, .latched):
            break

        case (.other(let code), .pressed), (.other(let code), .latched):
            // Esc cancels; any other key means Option was part of a shortcut.
            if code == 53 || { if case .pressed = state { return true } else { return false } }() {
                cancelRecording(silently: code != 53)
            }

        default:
            break
        }
    }

    // MARK: - Recording

    private func beginRecording() -> Bool {
        do {
            try recorder.start()
        } catch {
            panel.present(.message(settings.microphone ? "No microphone available" : "Microphone access needed"))
            panel.dismiss(after: 2)
            if !settings.microphone { settings.requestMicrophone() }
            return false
        }
        scheduleAutoStop()
        return true
    }

    private func showListening() {
        guard case .pressed = state else { return }
        panel.present(.listening)
        feedback(start: true)
    }

    private func latch() {
        state = .latched
        pillWork?.cancel()
        panel.present(.listening)
        feedback(start: true)
    }

    private func scheduleAutoStop() {
        autoStop?.cancel()
        let limit = max(5, transcriber.maxAudioSeconds - 1)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            switch self.state {
            case .pressed, .latched: self.finish()
            default: break
            }
        }
        autoStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + limit, execute: work)
    }

    private func cancelRecording(silently: Bool) {
        pillWork?.cancel(); autoStop?.cancel()
        _ = recorder.stop()
        state = .idle
        if panel.model.visible { panel.dismiss() }
        if !silently { feedback(start: false) }
    }

    private func finish() {
        pillWork?.cancel(); autoStop?.cancel()
        let pcm = recorder.stop()
        let voiced = recorder.voicedSeconds
        state = .processing
        feedback(start: false)

        guard pcm.count > 16_000 / 4, voiced > 0.12 else {
            // Nothing but silence/noise: don't feed it to the model (avoids hallucinated text).
            if panel.model.visible {
                panel.update(.message("Didn’t catch that"))
                panel.dismiss(after: 1.0)
            }
            state = .idle
            return
        }

        panel.present(.processing)
        transcriber.transcribe(pcm, language: settings.languageCode) { [weak self] result in
            DispatchQueue.main.async { self?.complete(result) }
        }
    }

    private func complete(_ result: Result<String, Error>) {
        defer { state = .idle }
        switch result {
        case .success(let text) where !text.isEmpty:
            let pasted = TextInserter.insert(text)
            if pasted {
                panel.update(.done)
                panel.dismiss(after: 0.45)
            } else {
                panel.update(.message("Copied — allow Accessibility to auto‑paste"))
                panel.dismiss(after: 2.4)
            }
        case .success:
            panel.update(.message("Didn’t catch that"))
            panel.dismiss(after: 1.0)
        case .failure(let error):
            NSLog("Transcription error: \(error)")
            panel.update(.message("Transcription failed"))
            panel.dismiss(after: 2)
        }
    }

    private func feedback(start: Bool) {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        guard settings.sounds else { return }
        let sound = NSSound(named: start ? "Pop" : "Tink")
        sound?.volume = 0.35
        sound?.play()
    }
}
