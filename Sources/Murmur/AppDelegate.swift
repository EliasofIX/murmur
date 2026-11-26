import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings.shared
    private let transcriber = Transcriber()
    private let hotkey = HotkeyMonitor()
    private var panel: PillPanel!
    private var controller: DictationController!
    private var statusItem: NSStatusItem!
    private var statusLine: NSMenuItem!
    private var settingsWindow: NSWindow?
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = PillPanel()
        controller = DictationController(transcriber: transcriber, panel: panel)
        hotkey.handler = { [weak self] event in self?.controller.handle(event) }

        buildMenu()
        loadModel()
        if ProcessInfo.processInfo.environment["MURMUR_PREVIEW"] != nil { startPreview(); return }

        // Permissions can be granted at any time; keep trying until the key tap works.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()

        if !settings.allPermissionsGranted || UserDefaults.standard.bool(forKey: "welcomed") == false {
            UserDefaults.standard.set(true, forKey: "welcomed")
            showSettings()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    private func tick() {
        settings.refresh()
        _ = hotkey.start()
        updateStatus()
    }

    private func loadModel() {
        transcriber.load { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success: self.settings.modelReady = true
                case .failure(let e): self.settings.modelError = e.localizedDescription
                }
                self.updateStatus()
            }
        }
    }

    // MARK: - Menu bar

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Murmur")
        let menu = NSMenu()
        statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        let prefs = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Murmur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func updateStatus() {
        if let err = settings.modelError { statusLine.title = err }
        else if !settings.modelReady { statusLine.title = "Loading model…" }
        else if !settings.inputMonitoring { statusLine.title = "Needs Input Monitoring permission" }
        else if !settings.microphone { statusLine.title = "Needs Microphone permission" }
        else { statusLine.title = "Ready — hold Left ⌥ to dictate" }
        let warn = settings.modelError != nil || !settings.allPermissionsGranted
        statusItem.button?.image = NSImage(
            systemSymbolName: warn ? "waveform.badge.exclamationmark" : "waveform",
            accessibilityDescription: "Murmur")
    }

    /// Dev aid: shows the pill with a synthetic voice (MURMUR_PREVIEW=1).
    private func startPreview() {
        let meter = LevelMeter()
        panel.model.meter = meter
        panel.present(.listening)
        Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            let t = ProcessInfo.processInfo.systemUptime
            let env = max(0, sin(t * 1.3)) * (0.5 + 0.5 * sin(t * 7.1))
            meter.target = Float(min(1, 0.15 + env * 0.8))
        }
    }

    @objc private func openSettings() { showSettings() }

    private func showSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: host)
            window.title = "Murmur"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
