import AVFoundation
import AppKit
import Observation
import ServiceManagement
import SwiftUI

@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()

    var sounds: Bool { didSet { UserDefaults.standard.set(sounds, forKey: "sounds") } }

    var microphone = false
    var accessibility = false
    var inputMonitoring = false
    var modelReady = false
    var modelError: String?
    var launchAtLogin = SMAppService.mainApp.status == .enabled

    var allPermissionsGranted: Bool { microphone && accessibility && inputMonitoring }

    private init() {
        sounds = UserDefaults.standard.object(forKey: "sounds") as? Bool ?? true
        refresh()
    }

    func refresh() {
        microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibility = AXIsProcessTrusted()
        inputMonitoring = CGPreflightListenEventAccess()
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { NSLog("Launch at login failed: \(error)") }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func requestMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in Task { @MainActor in self.refresh() } }
        } else {
            open("Privacy_Microphone")
        }
    }

    func requestAccessibility() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) { open("Privacy_Accessibility") }
    }

    func requestInputMonitoring() {
        if !CGRequestListenEventAccess() { open("Privacy_ListenEvent") }
    }

    private func open(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}

struct SettingsView: View {
    @Bindable var settings = AppSettings.shared
    @Bindable var files = FileTranscriptModel.shared

    var body: some View {
        GlassPage {
            PillMark(title: "Murmur")
                .frame(maxWidth: .infinity)
            Text("Hold **Left ⌥ Option** and speak. Release to insert the text.\nOr double-tap it to keep listening, then tap once to finish.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            Form {
                LabeledContent("Microphone") { permission("Hears your voice.", granted: settings.microphone, action: settings.requestMicrophone) }
                LabeledContent("Input Monitoring") { permission("Notices the Option key.", granted: settings.inputMonitoring, action: settings.requestInputMonitoring) }
                LabeledContent("Accessibility") { permission("Types the text where your cursor is.", granted: settings.accessibility, action: settings.requestAccessibility) }
                Toggle("Play sounds", isOn: $settings.sounds)
                Toggle("Open at login", isOn: Binding(get: { settings.launchAtLogin }, set: settings.setLaunchAtLogin))
                LabeledContent("Parakeet") { modelState }
                LabeledContent("File transcription") { fileModelState }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Button("Transcribe a File…") {
                NotificationCenter.default.post(name: .showFileTranscript, object: nil)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 440, minHeight: 560)
    }

    private func permission(_ detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if granted {
                Text("Allowed").foregroundStyle(.secondary)
            } else {
                Button("Allow…", action: action).controlSize(.small)
            }
        }
    }

    @ViewBuilder private var modelState: some View {
        if let err = settings.modelError {
            Text(err).foregroundStyle(.orange).lineLimit(2)
        } else if settings.modelReady {
            Text("Ready").foregroundStyle(.secondary)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder private var fileModelState: some View {
        if files.installed {
            Text("Ready").foregroundStyle(.secondary)
        } else if files.canRun {
            Text("Not downloaded").foregroundStyle(.secondary)
        } else {
            Text("Needs 8 GB").foregroundStyle(.secondary)
        }
    }
}
