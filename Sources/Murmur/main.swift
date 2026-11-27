import AppKit

MainActor.assumeIsolated {
    if ProcessInfo.processInfo.environment["MURMUR_SELFTEST"] != nil {
        FileTranscriptFormat.selfCheck()
        exit(0)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
