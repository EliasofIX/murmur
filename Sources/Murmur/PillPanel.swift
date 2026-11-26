import AppKit
import SwiftUI

/// A tight, borderless, click-through panel whose content view *is* the system `NSGlassEffectView`,
/// so the glass honours the user's Liquid Glass clarity setting. Size/fade animations run on the window.
@MainActor
final class PillPanel: NSPanel {
    static let pillHeight: CGFloat = 52

    let model = PillModel()
    private let glass = NSGlassEffectView()
    private var hideWork: DispatchWorkItem?
    private var centre = CGPoint.zero      // pill centre-x / bottom-y in screen coordinates
    private var shown = false

    init() {
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 132, height: Self.pillHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        glass.style = .regular
        glass.cornerRadius = Self.pillHeight / 2
        let host = NSHostingView(rootView: PillContentView(model: model))
        host.sizingOptions = []
        glass.contentView = host
        contentView = glass
    }

    /// A borderless panel resolves Liquid Glass as a full-face frost with the lens drawn on top of it.
    /// The backdrop filter is the same one system glass uses; zeroing its blur slab leaves the rim.
    private func clearFrost() {
        let rim = glass.cornerRadius
        func walkLayer(_ layer: CALayer) {
            for filter in layer.filters ?? [] {
                let obj = filter as AnyObject
                guard obj.value(forKey: "inputBlurRadius") != nil else { continue }
                obj.setValue(0, forKey: "inputBlurRadius")
                obj.setValue(0, forKey: "inputBlurOpacity0")
                obj.setValue(0, forKey: "inputBlurOpacity1")
                obj.setValue(0, forKey: "inputBlurOpacity2")
                obj.setValue(0, forKey: "inputBlurOpacity3")
                obj.setValue(0, forKey: "inputBlurFillBlurRadius")
                obj.setValue(0, forKey: "inputBlurFillDarkenOpacity")
                obj.setValue(-rim, forKey: "inputBlurDistance0")
                obj.setValue(rim / 4, forKey: "inputOuterRefractionHeight")
            }
            layer.sublayers?.forEach(walkLayer)
        }
        func walkView(_ view: NSView) {
            if let layer = view.layer { walkLayer(layer) }
            view.subviews.forEach(walkView)
        }
        if let contentView { walkView(contentView) }
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

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
            setFrame(scaled(target, by: 0.55), display: false)
            alphaValue = 0
            orderFrontRegardless()
            // The filter does not exist until the panel is on screen, and the pop-in rebuilds it.
            DispatchQueue.main.async { [weak self] in self?.clearFrost() }
        }
        animate(to: target, alpha: 1, duration: wasShown ? 0.35 : 0.42)
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
            self.animate(to: self.scaled(self.frame, by: 0.7), alpha: 0, duration: 0.28) { [weak self] in
                guard let self, !self.shown else { return }
                self.orderOut(nil)
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
        case .listening, .processing:
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

    private func scaled(_ r: CGRect, by f: CGFloat) -> CGRect {
        let w = r.width * f, h = r.height * f
        return CGRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h)
    }

    private func animate(to frame: CGRect, alpha: CGFloat, duration: TimeInterval, completion: (@MainActor () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.0)
            self.animator().setFrame(frame, display: true)
            self.animator().alphaValue = alpha
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.clearFrost()
                completion?()
                DispatchQueue.main.async { self?.clearFrost() }
            }
        }
    }
}
