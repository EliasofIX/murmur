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

    var canRetryLast: Bool {
        if case .idle = state {} else { return false }
        return TakeStore.shared.hasLast
    }

    /// Runs the saved recording again and inserts whatever text comes back.
    func retryLast() {
        guard canRetryLast else { return }
        guard settings.modelReady else {
            panel.present(.message(settings.modelError == nil ? "Warming up…" : "Model unavailable"))
            panel.dismiss(after: 1.4)
            return
        }
        guard let pcm = TakeStore.shared.loadLast(), pcm.count > 16_000 / 4 else {
            panel.present(.message("No recording to retry"))
            panel.dismiss(after: 1.4)
            return
        }
        state = .processing
        panel.present(.processing)
        transcribe(pcm)
    }

    func showSavedTakeNotice() {
        guard TakeStore.shared.isPending else { return }
        panel.present(.message("Saved — retry from the menu"))
        panel.dismiss(after: 2.6)
    }

    private func beginRecording() -> Bool {
        TakeStore.shared.begin()
        recorder.onSamples = { TakeStore.shared.append($0) }
        do {
            try recorder.start()
        } catch {
            panel.present(.message(settings.microphone ? "No microphone available" : "Microphone access needed"))
            panel.dismiss(after: 2)
            if !settings.microphone { settings.requestMicrophone() }
            TakeStore.shared.discard()
            return false
        }
        panel.model.recordingStarted = Date()
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
        autoStop = nil
        // Parakeet reports no audio ceiling (0). Only stop early when a model actually has one.
        guard transcriber.maxAudioSeconds > 0 else { return }
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
        TakeStore.shared.discard()
        state = .idle
        if panel.model.visible {
            panel.dismiss()
            // Keep the readout through the fade, then drop it once the pill is gone.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, case .idle = self.state else { return }
                self.panel.model.recordingStarted = nil
            }
        } else {
            panel.model.recordingStarted = nil
        }
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
            TakeStore.shared.discard()
            panel.model.recordingStarted = nil
            if panel.model.visible {
                panel.update(.message("Didn’t catch that"))
                panel.dismiss(after: 1.0)
            }
            state = .idle
            return
        }

        // On disk before the model runs, so a crash or an out-of-memory kill keeps the take.
        TakeStore.shared.commit()
        panel.model.recordingStarted = nil
        panel.present(.processing)
        transcribe(pcm)
    }

    private func transcribe(_ pcm: [Float]) {
        transcriber.transcribe(pcm, language: nil) { [weak self] result in
            DispatchQueue.main.async { self?.complete(result) }
        }
    }

    private func complete(_ result: Result<String, Error>) {
        defer { state = .idle }
        switch result {
        case .success(let text) where !text.isEmpty:
            deliver(text)
        case .success:
            panel.update(.message("Didn’t catch that"))
            panel.dismiss(after: 1.0)
        case .failure(let error):
            NSLog("Transcription error: \(error)")
            if let saved = TakeStore.shared.savedTranscript() {
                deliver(saved)
            } else if TakeStore.shared.hasLast {
                panel.update(.message("Saved — retry from the menu"))
                panel.dismiss(after: 2.4)
            } else {
                panel.update(.message("Transcription failed"))
                panel.dismiss(after: 2)
            }
        }
    }

    /// Writes the text to disk and the clipboard, then pastes it if Accessibility allows.
    private func deliver(_ text: String) {
        TakeStore.shared.markDelivered(text: text)
        let pasted = TextInserter.insert(text)
        if pasted {
            panel.update(.done)
            panel.dismiss(after: 0.45)
        } else {
            panel.update(.message("Copied — allow Accessibility to auto‑paste"))
            panel.dismiss(after: 2.4)
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
