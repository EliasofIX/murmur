import AppKit
import ApplicationServices

/// Copies a transcription onto the clipboard and pastes it into the focused app.
/// The text stays on the clipboard, so it can be pasted again after the dictation.
@MainActor
enum TextInserter {
    static var canPaste: Bool { AXIsProcessTrusted() }

    /// Leaves `text` on the clipboard. Returns true when it was also pasted.
    @discardableResult
    static func insert(_ text: String) -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard pb.setString(text, forType: .string) else { return false }

        guard canPaste else { return false }
        let src = CGEventSource(stateID: .combinedSessionState)
        let v: CGKeyCode = 9
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cgAnnotatedSessionEventTap)
        }
        return true
    }
}
