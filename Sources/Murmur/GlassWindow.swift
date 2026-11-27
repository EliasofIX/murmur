import AppKit
import SwiftUI

/// A document window on regular Liquid Glass. Regular blurs and lifts the luminosity of
/// whatever is behind the window, so body text stays readable. The listening pill stays clear.
enum GlassWindow {
    @MainActor
    static func make(title: String, size: NSSize, resizable: Bool, root: some View) -> NSWindow {
        let glassClass = NSClassFromString("NSGlassEffectView") as! NSView.Type
        let glass = glassClass.init(frame: NSRect(origin: .zero, size: size))
        glass.setValue(0, forKey: "style") // NSGlassEffectViewStyleRegular
        glass.setValue(20.0, forKey: "cornerRadius")

        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        host.frame = glass.bounds
        host.autoresizingMask = [.width, .height]
        glass.setValue(host, forKey: "contentView")

        var mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if resizable { mask.insert(.resizable) }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: mask,
            backing: .buffered,
            defer: false)
        window.title = title
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = glass
        window.contentMinSize = NSSize(width: min(440, size.width), height: min(480, size.height))
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

/// Clear page padding that keeps content below the traffic lights.
struct GlassPage<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            content()
        }
        .padding(.horizontal, 22)
        .padding(.top, 36)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.clear)
    }
}
