import CoreGraphics
import Foundation

/// Watches the left Option key globally (listen-only event tap; needs Input Monitoring permission).
final class HotkeyMonitor {
    enum Event {
        case optionDown
        case optionUp
        /// Any other key, modifier or click while Option may be held — means it is a shortcut, not dictation.
        case other(keyCode: Int)
    }

    var handler: ((Event) -> Void)?
    private var tap: CFMachPort?
    private var optionDown = false

    private static let leftOptionKeyCode = 58
    private static let leftOptionDeviceMask: UInt64 = 0x20   // NX_DEVICELALTKEYMASK

    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: hotkeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            guard code == Self.leftOptionKeyCode else {
                handler?(.other(keyCode: code))
                return
            }
            let flags = event.flags
            let down = flags.rawValue & Self.leftOptionDeviceMask != 0
            let otherModifiers = flags.intersection([.maskCommand, .maskControl, .maskShift, .maskSecondaryFn])
            if down, !optionDown {
                optionDown = true
                if otherModifiers.isEmpty { handler?(.optionDown) }
            } else if !down, optionDown {
                optionDown = false
                handler?(.optionUp)
            }
        case .keyDown:
            handler?(.other(keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode))))
        case .leftMouseDown, .rightMouseDown:
            handler?(.other(keyCode: -1))
        default:
            break
        }
    }
}

private func hotkeyCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let refcon {
        Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
    }
    return Unmanaged.passUnretained(event)
}
