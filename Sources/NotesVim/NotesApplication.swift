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

    /// What has keyboard focus inside Notes.
    enum Focus {
        case noteBody(AccessibilityText)
        /// The list of notes next to the note body.
        case noteList
        /// The search field, the folder list, a sheet, ...
        case other
    }

    func focus() -> Focus {
        guard let element = copyElement(application, kAXFocusedUIElementAttribute) else { return .other }
        if Self.isNoteBody(element) { return .noteBody(AccessibilityText(element: element)) }
        if Self.isNoteList(element) { return .noteList }
        return .other
    }

    /// The note body, if that is what has keyboard focus. Search fields, the note list and
    /// sheets are other elements, and keys typed there are left alone.
    func focusedNoteBody() -> AccessibilityText? {
        if case let .noteBody(body) = focus() { return body }
        return nil
    }

    /// Moves keyboard focus to the note list. Fails when the list is hidden.
    @discardableResult
    func focusNoteList() -> Bool { focusElement(where: Self.isNoteList) }

    /// Moves keyboard focus into the body of the note selected in the list.
    @discardableResult
    func focusNoteBody() -> Bool { focusElement(where: Self.isNoteBody) }

    private static func isNoteBody(_ element: AXUIElement) -> Bool {
        string(element, kAXRoleAttribute) == kAXTextAreaRole
    }

    private static func isNoteList(_ element: AXUIElement) -> Bool {
        string(element, kAXRoleAttribute) == kAXTableRole
            && string(element, kAXIdentifierAttribute)?.hasPrefix("ICMNoteListTableView") == true
    }

    private func focusElement(where matches: (AXUIElement) -> Bool) -> Bool {
        guard let window = copyElement(application, kAXFocusedWindowAttribute),
              let element = Self.find(in: window, depth: 0, where: matches) else { return false }
        return AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    /// Searches the window's split views. Rows, text and toolbars are not looked into: the note
    /// list and the note body sit a few levels below the window.
    private static func find(in element: AXUIElement, depth: Int, where matches: (AXUIElement) -> Bool) -> AXUIElement? {
        if matches(element) { return element }
        let role = string(element, kAXRoleAttribute)
        guard depth < 5, ![kAXTableRole, kAXTextAreaRole, kAXToolbarRole, kAXRowRole].contains(role),
              let children = copy(element, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        for child in children {
            if let found = find(in: child, depth: depth + 1, where: matches) { return found }
        }
        return nil
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copy(element, attribute) as? String
    }

    private func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = Self.copy(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
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
