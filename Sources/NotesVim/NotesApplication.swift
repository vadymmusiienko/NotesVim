import AppKit
import ApplicationServices

/// A running instance of Notes: finds the focused note body and reports selection and focus
/// changes, so the block cursor can be restored after mouse clicks, undo, or Find.
@MainActor
final class NotesApplication {
    static let bundleIdentifier = "com.apple.Notes"

    let processIdentifier: pid_t
    private let application: AXUIElement
    private var observer: AXObserver?
    var onChange: (() -> Void)?

    init(processIdentifier: pid_t) {
        self.processIdentifier = processIdentifier
        application = AXUIElementCreateApplication(processIdentifier)
        // Never let a busy Notes stall the keyboard: the event tap gets disabled by the
        // system if a callback takes too long.
        AXUIElementSetMessagingTimeout(application, 0.25)
        startObserving()
    }

    isolated deinit {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
    }

    /// The note body, if that is what has keyboard focus. Search fields, the note list and
    /// sheets are other elements, and keys typed there are left alone.
    func focusedNoteBody() -> AccessibilityText? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
              role as? String == kAXTextAreaRole else { return nil }
        return AccessibilityText(element: element)
    }

    private func startObserving() {
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let notes = Unmanaged<NotesApplication>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { notes.onChange?() }
        }
        var created: AXObserver?
        guard AXObserverCreate(processIdentifier, callback, &created) == .success, let created else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in [kAXSelectedTextChangedNotification, kAXFocusedUIElementChangedNotification] {
            AXObserverAddNotification(created, application, notification as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
    }
}
