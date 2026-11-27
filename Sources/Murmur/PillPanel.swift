import AppKit
import ObjectiveC
import SwiftUI

/// Click-through status panel whose content view is the system `NSGlassEffectView` in the clear style.
///
/// Clear Liquid Glass draws its rim only while the window is key. An inactive window falls back
/// to the full-face frost, which ignores how far the Appearance slider is toward clear. The pill
/// becomes key while it is on screen and resigns when it hides. It never activates Murmur, so
/// the app the user is dictating into stays frontmost. Clicks pass through.
@MainActor
final class PillPanel: NSPanel {
    static let pillHeight: CGFloat = 52

    let model = PillModel()
    /// Real `NSGlassEffectView` loaded by name. The Command Line Tools SDK does not export the class.
    private let glass: NSView
    private var hideWork: DispatchWorkItem?
    private var centre = CGPoint.zero      // pill centre-x / bottom-y in screen coordinates
    private var shown = false
    /// `orderOut` makes the next glass surface in this process resolve as frost, so the panel
    /// is ordered in once and later hidden with alpha.
    private var ordered = false

    init() {
        let glassClass = NSClassFromString("NSGlassEffectView") as! NSView.Type
        let view = glassClass.init(frame: .zero)
        view.setValue(1, forKey: "style") // .clear — follows the system clearness slider
        view.setValue(Self.pillHeight / 2, forKey: "cornerRadius")
        glass = view
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 148, height: Self.pillHeight),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isMovable = false
        isRestorable = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        titlebarSeparatorStyle = .none
        setTitlebarHeight(0)
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(kind)?.isHidden = true
        }

        let host = NSHostingView(rootView: PillContentView(model: model))
        host.sizingOptions = []
        view.setValue(host, forKey: "contentView")
        contentView = view
    }

    /// Private AppKit entry. The zero titlebar is what lets clear glass draw the rim shader.
    private func setTitlebarHeight(_ height: CGFloat) {
        let sel = NSSelectorFromString("setTitlebarHeight:")
        guard let method = class_getInstanceMethod(type(of: self), sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, CGFloat) -> Void
        unsafeBitCast(method_getImplementation(method), to: Fn.self)(self, sel, height)
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    // MARK: - Presentation

    func present(_ phase: PillPhase) {
        hideWork?.cancel()
        let wasShown = shown
        if !wasShown { locate() }
        model.phase = phase
        let target = frame(for: phase)
        if !wasShown {
            shown = true
            model.visible = true
            if !ordered {
                setFrame(target, display: false)
                alphaValue = 0
                orderFrontRegardless()
                ordered = true
            }
        }
        // Active glass, without becoming the frontmost app.
        makeKey()
        animate(to: target, alpha: 1, duration: wasShown ? 0.35 : 0.28)
    }

    func update(_ phase: PillPhase) {
        model.phase = phase
        animate(to: frame(for: phase), alpha: 1, duration: 0.35)
    }

    func dismiss(after delay: TimeInterval = 0) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.shown else { return }
            self.shown = false
            self.model.visible = false
            self.animate(to: self.frame, alpha: 0, duration: 0.22) { [weak self] in
                guard let self, !self.shown else { return }
                self.resignKey()
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Geometry

    private func locate() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        centre = CGPoint(x: visible.midX, y: visible.minY + 24)
    }

    private func width(for phase: PillPhase) -> CGFloat {
        switch phase {
        case .listening:
            return 156          // time in the middle, bars mirrored on either side
        case .processing:
            return 148
        case .done:
            return Self.pillHeight
        case .message(let text):
            let font = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .medium)
            let w = (text as NSString).size(withAttributes: [.font: font]).width
            return max(120, ceil(w) + 40)
        }
    }

    private func frame(for phase: PillPhase) -> CGRect {
        let w = width(for: phase)
        return CGRect(x: centre.x - w / 2, y: centre.y, width: w, height: Self.pillHeight)
    }

    private func animate(to frame: CGRect, alpha: CGFloat, duration: TimeInterval, completion: (@MainActor () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.0)
            self.animator().setFrame(frame, display: true)
            self.animator().alphaValue = alpha
        } completionHandler: {
            MainActor.assumeIsolated { completion?() }
        }
    }
}
