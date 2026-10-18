import AppKit
import ApplicationServices
import Carbon.HIToolbox
import VimEngine

/// Connects the keyboard, Notes and the Vim engine.
///
/// Every key press while Notes is frontmost goes through `handleKeyDown`. In Insert mode that
/// is a dictionary lookup and nothing else, unless the key is Escape. In Normal and Visual mode
/// the note body is read through Accessibility, the engine computes the result, and the edits
/// and new selection are written back before the next key is processed. Shortcuts NotesVim
/// sends to Notes (undo, the undo separator) go straight to the Notes process, so NotesVim can
/// wait for them to finish and everything stays strictly sequential.
@MainActor
final class NotesVimController {
    let settings: Settings
    var onStateChange: (() -> Void)?

    private let engine = VimEngine(clipboard: SystemClipboard())
    private let keyboard = KeyboardLayout()
    private let blockCursor = BlockCursorOverlay()
    private lazy var tap = KeyEventTap { [unowned self] type, event in self.handle(type, event) }
    private var notes: NotesApplication?
    private var lastFocusedElement: AXUIElement?
    private var swallowedKeyUps = Set<Int64>()
    private var permissionTimer: Timer?
    private var syncScheduled = false
    /// The arrow key sent to end Notes' undo grouping, until Notes has processed it.
    private var pendingSeparator: (expected: NSRange, caretAfterArrow: Int)?

    /// Set NOTESVIM_DEBUG=1 to trace key handling on stderr.
    private static let debug = ProcessInfo.processInfo.environment["NOTESVIM_DEBUG"] == "1"

    init(settings: Settings) {
        self.settings = settings
    }

    var mode: Mode { engine.mode }
    var isNotesActive: Bool { notes != nil && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == NotesApplication.bundleIdentifier }
    var hasPermission: Bool { tap.isInstalled }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.frontmostApplicationChanged() }
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = application?.processIdentifier
            MainActor.assumeIsolated {
                guard let self, pid == self.notes?.processIdentifier else { return }
                self.notes = nil
                self.engine.reset()
                self.frontmostApplicationChanged()
            }
        }
        settings.onChange = { [weak self] in self?.settingsChanged() }
        engine.verticalMovesUseScreenLines = settings.verticalMovesUseScreenLines
        installTapWhenPermitted(prompt: true)
    }

    func openAccessibilitySettings() {
        installTapWhenPermitted(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Lifecycle

    private func installTapWhenPermitted(prompt: Bool) {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        if AXIsProcessTrustedWithOptions(options), tap.install() {
            permissionTimer?.invalidate()
            permissionTimer = nil
            frontmostApplicationChanged()
            return
        }
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.installTapWhenPermitted(prompt: false) }
        }
    }

    private func frontmostApplicationChanged() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier == NotesApplication.bundleIdentifier, let pid = frontmost?.processIdentifier {
            if notes?.processIdentifier != pid {
                engine.reset()
                pendingSeparator = nil
                let application = NotesApplication(processIdentifier: pid)
                application.onChange = { [weak self] in self?.scheduleSync() }
                notes = application
            }
            tap.isEnabled = settings.isEnabled && tap.isInstalled
            scheduleSync()
        } else {
            tap.isEnabled = false
            swallowedKeyUps.removeAll()
        }
        stateChanged()
    }

    private func settingsChanged() {
        engine.verticalMovesUseScreenLines = settings.verticalMovesUseScreenLines
        if !settings.isEnabled, engine.mode != .insert {
            // Leave the note with a normal caret rather than a stray one-character selection.
            if let body = notes?.focusedNoteBody(), let selection = body.selection() {
                body.select(NSRange(location: selection.location, length: 0))
            }
            engine.reset()
        }
        frontmostApplicationChanged()
    }

    // MARK: Keys

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp { return swallowedKeyUps.remove(keyCode) != nil }
        guard handleKeyDown(event) else { return false }
        swallowedKeyUps.insert(keyCode)
        return true
    }

    private func handleKeyDown(_ event: CGEvent) -> Bool {
        guard settings.isEnabled, let notes else { return false }
        // ⌘ shortcuts always belong to Notes.
        if event.flags.contains(.maskCommand) { return false }
        guard let key = keyboard.key(for: event) else { return false }
        if engine.mode == .insert, !key.isEscape { return false }

        guard let body = notes.focusedNoteBody() else { return false }
        if let last = lastFocusedElement, !CFEqual(last, body.element) {
            trace("focused element changed, back to Insert mode")
            engine.reset()
            pendingSeparator = nil
            stateChanged()
        }
        lastFocusedElement = body.element
        if engine.mode == .insert, !key.isEscape { return false }

        settlePendingSeparator(body)
        guard let snapshot = body.snapshot() else {
            // Notes did not answer in time. Swallow Normal mode keys rather than let them type.
            return engine.mode != .insert
        }
        let modeBefore = engine.mode
        if engine.mode != .insert {
            _ = engine.synchronize(with: snapshot, textChangeResetsMode: true)
            if engine.mode == .insert, !key.isEscape {
                trace("text changed outside NotesVim, back to Insert mode")
                stateChanged()
                return false
            }
        }

        let response = engine.handle(key, in: snapshot, layout: body)
        trace("key \(key) sel \(snapshot.selection) -> \(engine.mode) edits \(response.edits) sel \(String(describing: response.selection)) actions \(response.actions)")
        guard response.handled else { return false }
        apply(response, to: body, text: snapshot.text, leftInsertMode: modeBefore == .insert && engine.mode != .insert)
        stateChanged()
        return true
    }

    private func apply(_ response: Response, to body: AccessibilityText, text: String, leftInsertMode: Bool) {
        let current = NSMutableString(string: text)
        for edit in response.edits {
            let separate = edit.ownUndoStep(in: current)
            body.replace(separate.range, with: separate.text)
            current.replaceCharacters(in: edit.range, with: edit.text)
        }
        if let selection = response.selection {
            body.select(selection)
        }
        if !response.actions.isEmpty {
            for action in response.actions { perform(action, in: body) }
            if let snapshot = body.snapshot(), let selection = engine.synchronize(with: snapshot, textChangeResetsMode: false) {
                body.select(selection)
            }
        }
        guard engine.mode != .insert, let actual = body.snapshot() else { return }
        engine.confirm(actual)
        if !response.edits.isEmpty || leftInsertMode {
            sendUndoSeparator(expected: actual)
        }
    }

    /// Sends a shortcut to Notes and, for those that change the text or selection, waits until
    /// Notes has carried it out.
    private func perform(_ action: HostAction, in body: AccessibilityText) {
        let (character, flags, waits): (Character, CGEventFlags, Bool) = switch action {
        case .undo: ("z", .maskCommand, true)
        case .redo: ("z", [.maskCommand, .maskShift], true)
        case .indent: ("]", .maskCommand, false)
        case .outdent: ("[", .maskCommand, false)
        case .find: ("f", .maskCommand, false)
        case .findNext: ("g", .maskCommand, true)
        case .findPrevious: ("g", [.maskCommand, .maskShift], true)
        }
        guard let keyCode = keyboard.keyCode(for: character) else { return }
        let before = body.snapshot()
        post(keyCode, flags: flags)
        if waits {
            // Nothing to undo leaves everything unchanged; give up after a short while.
            wait(upTo: 0.25) { body.snapshot() != before }
        }
    }

    /// Notes merges consecutive Accessibility edits into one "typing" undo step, so `dw dw u`
    /// would undo both deletions together with whatever was typed before. A real keyboard
    /// navigation event ends that grouping. Sending one after every change gives one undo step
    /// per Vim change, and one for a whole Insert session, just like Vim, while keeping Notes'
    /// own undo, which also brings formatting back.
    ///
    /// The arrow always moves the selection, so its arrival is observable. Before the next
    /// command runs, NotesVim waits for it (usually it is long done) and restores the cursor.
    private func sendUndoSeparator(expected: Snapshot) {
        let text = expected.text as NSString
        let selection = expected.selection
        guard text.length > 0 else { return }
        let caretAfterArrow: Int
        let key: Int
        if selection.length > 0 {
            (key, caretAfterArrow) = (kVK_LeftArrow, selection.location)
        } else if selection.location < text.length {
            let next = text.rangeOfComposedCharacterSequence(at: selection.location)
            (key, caretAfterArrow) = (kVK_RightArrow, next.location + next.length)
        } else {
            (key, caretAfterArrow) = (kVK_LeftArrow, text.rangeOfComposedCharacterSequence(at: text.length - 1).location)
        }
        pendingSeparator = (selection, caretAfterArrow)
        post(CGKeyCode(key), flags: [])
    }

    /// Waits until Notes has processed the undo separator, then restores the cursor it moved.
    private func settlePendingSeparator(_ body: AccessibilityText) {
        guard let pending = pendingSeparator else { return }
        pendingSeparator = nil
        var current = body.selection()
        let started = Date()
        if current == pending.expected {
            wait(upTo: 0.15) {
                current = body.selection()
                return current != pending.expected
            }
        }
        trace("separator settled after \(Int(Date().timeIntervalSince(started) * 1000)) ms, selection \(String(describing: current)), expected \(pending.expected)")
        if let current, current.length == 0, current.location == pending.caretAfterArrow {
            body.select(pending.expected)
        }
    }

    private func wait(upTo timeout: TimeInterval, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { usleep(1_000) }
    }

    /// Posts a key press directly to Notes. Events sent this way do not pass through the event
    /// tap, so NotesVim can wait for Notes to handle them without deadlocking.
    private func post(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let notes else { return }
        let source = CGEventSource(stateID: .privateState)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: KeyEventTap.syntheticEventMarker)
            event.postToPid(notes.processIdentifier)
        }
    }

    // MARK: Keeping the block cursor in place

    private func scheduleSync() {
        guard !syncScheduled else { return }
        syncScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.syncScheduled = false
                self?.syncNow()
            }
        }
    }

    /// Runs after selection or focus changes reported by Notes: mouse clicks, Find, the undo
    /// separator. Puts the block cursor back where the caret now is, or drops to Insert mode if
    /// the user moved to a different note.
    private func syncNow() {
        guard settings.isEnabled, engine.mode != .insert, isNotesActive, let body = notes?.focusedNoteBody() else { return }
        if let last = lastFocusedElement, !CFEqual(last, body.element) {
            trace("focused element changed, back to Insert mode")
            engine.reset()
            pendingSeparator = nil
            stateChanged()
            return
        }
        if let pending = pendingSeparator, let current = body.selection(), current != pending.expected {
            settlePendingSeparator(body)
            return
        }
        guard let snapshot = body.snapshot() else { return }
        let before = engine.mode
        if let selection = engine.synchronize(with: snapshot, textChangeResetsMode: true) {
            trace("sync \(snapshot.selection) -> block \(selection)")
            body.select(selection)
            if let actual = body.snapshot() { engine.confirm(actual) }
        }
        if before != engine.mode { trace("sync changed mode \(before) -> \(engine.mode)") }
        stateChanged()
    }

    private func stateChanged() {
        onStateChange?()
        updateBlockCursor()
    }

    /// Notes can only show the block cursor as a selection, which is impossible where there is
    /// no character (empty lines, the end of the note). The overlay covers those spots.
    private func updateBlockCursor() {
        guard settings.isEnabled, engine.mode == .normal, isNotesActive,
              let expected = engine.expectedSnapshot, expected.selection.length == 0 else {
            blockCursor.hide()
            return
        }
        let text = expected.text as NSString
        blockCursor.show { [weak self] in
            guard let self, self.engine.mode == .normal, self.isNotesActive,
                  let body = self.notes?.focusedNoteBody(), body.selection() == expected.selection else { return nil }
            return body.emptyCursorBounds(at: expected.selection.location, in: text)
        }
    }

    private func trace(_ message: @autoclosure () -> String) {
        guard Self.debug else { return }
        FileHandle.standardError.write(Data("[NotesVim] \(message())\n".utf8))
    }
}
