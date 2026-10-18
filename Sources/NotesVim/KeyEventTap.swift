import CoreGraphics
import Foundation

/// A session-wide keyboard event tap that is only switched on while Notes is frontmost.
/// While it is off, NotesVim adds zero overhead to typing in other apps.
@MainActor
final class KeyEventTap {
    /// Marks events NotesVim posts itself (shortcuts like ⌘Z) so the tap lets them through.
    static let syntheticEventMarker: Int64 = 0x4E56_494D // "NVIM"

    /// Return true to swallow the event.
    private let handler: (CGEventType, CGEvent) -> Bool
    private var port: CFMachPort?
    private var source: CFRunLoopSource?

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue, let port else { return }
            CGEvent.tapEnable(tap: port, enable: isEnabled)
        }
    }

    var isInstalled: Bool { port != nil }

    init(handler: @escaping (CGEventType, CGEvent) -> Bool) {
        self.handler = handler
    }

    isolated deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port { CFMachPortInvalidate(port) }
    }

    /// Requires the Accessibility permission. Returns false when it is missing.
    func install() -> Bool {
        guard port == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<KeyEventTap>.fromOpaque(refcon).takeUnretainedValue()
            nonisolated(unsafe) let event = event
            let swallow = MainActor.assumeIsolated { tap.process(type, event) }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: isEnabled)
        self.port = port
        self.source = source
        return true
    }

    private func process(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if isEnabled, let port { CGEvent.tapEnable(tap: port, enable: true) }
            return false
        case .keyDown, .keyUp:
            if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker { return false }
            return handler(type, event)
        default:
            return false
        }
    }
}
