import AVFoundation
import AppKit
import Observation
import ServiceManagement
import SwiftUI

@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()

    static let languages: [(code: String?, name: String)] = [
        (nil, "Automatic"), ("en", "English"), ("de", "Deutsch"), ("fr", "Français"),
        ("es", "Español"), ("pt", "Português"), ("ja", "日本語"),
    ]

    var language: String { didSet { UserDefaults.standard.set(language, forKey: "language") } }
    var sounds: Bool { didSet { UserDefaults.standard.set(sounds, forKey: "sounds") } }

    var microphone = false
    var accessibility = false
    var inputMonitoring = false
    var modelReady = false
    var modelError: String?
    var launchAtLogin = SMAppService.mainApp.status == .enabled

    var allPermissionsGranted: Bool { microphone && accessibility && inputMonitoring }

    private init() {
        let d = UserDefaults.standard
        language = d.string(forKey: "language") ?? "auto"
        sounds = d.object(forKey: "sounds") as? Bool ?? true
        refresh()
    }

    var languageCode: String? { language == "auto" ? nil : language }

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

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 44))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, LinearGradient(colors: [.cyan, .blue, .purple, .pink], startPoint: .leading, endPoint: .trailing))
                    Text("Murmur").font(.title2.bold())
                    Text("Hold **Left ⌥ Option** and speak. Release to insert the text.\nOr double‑tap it to keep listening, then tap once to finish.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }

            Section("Permissions") {
                PermissionRow(title: "Microphone", detail: "Hears your voice.", symbol: "mic.fill",
                              granted: settings.microphone, action: settings.requestMicrophone)
                PermissionRow(title: "Input Monitoring", detail: "Notices the Option key.", symbol: "keyboard.fill",
                              granted: settings.inputMonitoring, action: settings.requestInputMonitoring)
                PermissionRow(title: "Accessibility", detail: "Types the text where your cursor is.", symbol: "accessibility.fill",
                              granted: settings.accessibility, action: settings.requestAccessibility)
            }

            Section("Dictation") {
                Picker("Language", selection: $settings.language) {
                    ForEach(AppSettings.languages, id: \.name) { Text($0.name).tag($0.code ?? "auto") }
                }
                Toggle("Play sounds", isOn: $settings.sounds)
                Toggle("Open at login", isOn: Binding(get: { settings.launchAtLogin }, set: settings.setLaunchAtLogin))
            }

            Section("Model") {
                LabeledContent("Granite Speech 4.1 · 2B") {
                    if let err = settings.modelError {
                        Label(err, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(2)
                    } else if settings.modelReady {
                        Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Loading…") }.foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let symbol: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        LabeledContent {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Allow…", action: action).buttonStyle(.glass)
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: symbol) }
        }
    }
}
