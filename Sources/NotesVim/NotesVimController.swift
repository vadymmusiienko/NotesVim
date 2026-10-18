import AppKit
import ApplicationServices
import Carbon.HIToolbox
import VimEngine

/// Connects the keyboard, Notes and the Vim engine.
///
/// Key presses on their way to Notes come through `handleKeyDown`, except while typing in
/// Insert mode, which the event tap lets through by itself. In Normal and Visual mode the note
/// body is read through Accessibility, the engine computes the result, and the edits and new
/// selection are written back before the next key is processed. Shortcuts NotesVim sends to
/// Notes (undo, the undo separator) go straight to the Notes process, so NotesVim can wait for
/// them to finish and everything stays strictly sequential.
@MainActor
final class NotesVimController {
    let settings: Settings
    var onStateChange: (() -> Void)?

    private let engine = VimEngine(clipboard: SystemClipboard())
    private let keyboard = KeyboardLayout()
    private let blockCursor = BlockCursorOverlay()
    private var tap: KeyEventTap?
    private var notes: NotesApplication?
    /// The note body last seen with keyboard focus, to notice when the user opens another note.
    /// Notes shows every note in the same text area, only its identifier changes.
    private var openNote: (element: AXUIElement, identifier: String?)?
    /// Keyboard focus is on the note list, where `j` and `k` move between notes.
    private(set) var isInNoteList = false
    /// `g` was typed in the note list, waiting for the second `g` of `gg`.
    private var pendingListG = false
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
    private(set) var hasPermission = false

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
                self.tap?.invalidate()
                self.tap = nil
                self.openNote = nil
                self.isInNoteList = false
                self.engine.reset()
                self.frontmostApplicationChanged()
            }
        }
        settings.onChange = { [weak self] in self?.settingsChanged() }
        engine.verticalMovesUseScreenLines = settings.verticalMovesUseScreenLines
        checkPermission(prompt: true)
    }

    func openAccessibilitySettings() {
        checkPermission(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Lifecycle

    private func checkPermission(prompt: Bool) {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        hasPermission = AXIsProcessTrustedWithOptions(options)
        if hasPermission {
            permissionTimer?.invalidate()
            permissionTimer = nil
            frontmostApplicationChanged()
            return
        }
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPermission(prompt: false) }
        }
    }

    private func frontmostApplicationChanged() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if hasPermission, frontmost?.bundleIdentifier == NotesApplication.bundleIdentifier, let pid = frontmost?.processIdentifier {
            if notes?.processIdentifier != pid {
                engine.reset()
                openNote = nil
                pendingSeparator = nil
                let application = NotesApplication(processIdentifier: pid)
                application.onChange = { [weak self] in self?.scheduleSync() }
                notes = application
                tap?.invalidate()
                tap = KeyEventTap(processIdentifier: pid) { [weak self] event in self?.handleKeyDown(event) ?? false }
                if tap == nil { trace("could not create the event tap for Notes") }
            }
            scheduleSync()
        }
        // The tap only ever sees keys sent to Notes, so it can stay on while Notes is in the background.
        tap?.isEnabled = settings.isEnabled
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
        openNote = nil
        frontmostApplicationChanged()
    }

    // MARK: Keys

    private func handleKeyDown(_ event: CGEvent) -> Bool {
        guard settings.isEnabled, let notes else { return false }
        // ⌘ shortcuts always belong to Notes.
        if event.flags.contains(.maskCommand) { return false }
        guard let key = keyboard.key(for: event) else { return false }
        if engine.mode == .insert, !key.isEscape, !isInNoteList { return false }

        let body: AccessibilityText
        switch notes.focus() {
        case let .noteBody(focused):
            body = focused
        case .noteList:
            setInNoteList(true)
            return handleNoteListKey(key, in: notes)
        case .other:
            setInNoteList(false)
            return false
        }
        setInNoteList(false)
        noticeOpenedNote(body)
        if engine.mode == .insert, !key.isEscape { return false }

        if key.control, key.command == "h" {
            // Over to the note list, like moving to the window on the left in Vim.
            if notes.focusNoteList() { leaveNoteBody() }
            return true
        }

        settlePendingSeparator(body)
        guard let snapshot = body.snapshot() else {
            // Notes did not answer in time. Swallow Normal mode keys rather than let them type.
            return engine.mode != .insert
        }
        let modeBefore = engine.mode

        let response = engine.handle(key, in: snapshot, layout: body)
        trace("key \(key) sel \(snapshot.selection) -> \(engine.mode) edits \(response.edits) sel \(String(describing: response.selection)) actions \(response.actions)")
        guard response.handled else { return false }
        apply(response, to: body, text: snapshot.text, leftInsertMode: modeBefore == .insert && engine.mode != .insert)
        stateChanged()
        return true
    }

    /// The note list has no text to edit: `j` and `k` move to the next and previous note (Notes
    /// shows it right away), `gg` and `G` to the first and last one, and `l` or `Ctrl-l` (the
    /// way back from `Ctrl-h`) goes into the note.
    /// Other characters are ignored rather than starting Notes' type-to-select search; special
    /// keys and shortcuts work as usual.
    private func handleNoteListKey(_ key: VimKey, in notes: NotesApplication) -> Bool {
        let afterG = pendingListG
        pendingListG = false
        if key.control, key.command == "l" {
            notes.focusNoteBody()
            return true
        }
        guard !key.control, key.special == nil else { return false }
        switch key.command {
        case "j": post(CGKeyCode(kVK_DownArrow), flags: [])
        case "k": post(CGKeyCode(kVK_UpArrow), flags: [])
        case "G": post(CGKeyCode(kVK_DownArrow), flags: .maskAlternate)
        case "g" where afterG: post(CGKeyCode(kVK_UpArrow), flags: .maskAlternate)
        case "g": pendingListG = true
        case "l": notes.focusNoteBody()
        default: break
        }
        return true
    }

    private func setInNoteList(_ inList: Bool) {
        guard inList != isInNoteList else { return }
        pendingListG = false
        trace(inList ? "note list focused" : "note list lost focus")
        isInNoteList = inList
        stateChanged()
    }

    /// Focus moved away from the note body. Coming back opens the note afresh.
    private func leaveNoteBody() {
        guard openNote != nil else { return }
        trace("note body lost focus")
        openNote = nil
        engine.reset()
        pendingSeparator = nil
        stateChanged()
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
            if let snapshot = body.snapshot(), let selection = engine.synchronize(with: snapshot) {
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

    private func scheduleSync(after delay: TimeInterval = 0) {
        guard !syncScheduled else { return }
        syncScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                self?.syncScheduled = false
                self?.syncNow()
            }
        }
    }

    /// Runs after selection or focus changes reported by Notes: mouse clicks, Find, the undo
    /// separator, opening another note. Puts the block cursor back where the caret now is.
    private func syncNow() {
        guard settings.isEnabled, isNotesActive, let notes else { return }
        // Notes is still placing the caret or extending a selection with the mouse.
        if NSEvent.pressedMouseButtons != 0 {
            scheduleSync(after: 0.03)
            return
        }
        let focus = notes.focus()
        if case .noteList = focus { setInNoteList(true) } else { setInNoteList(false) }
        guard case let .noteBody(body) = focus else {
            // Focus is in the note list, the search field or a sheet.
            leaveNoteBody()
            return
        }
        guard !noticeOpenedNote(body), engine.mode != .insert else { return }
        if let pending = pendingSeparator, let current = body.selection(), current != pending.expected {
            settlePendingSeparator(body)
            return
        }
        guard let snapshot = body.snapshot() else { return }
        if let selection = engine.synchronize(with: snapshot) {
            trace("sync \(snapshot.selection) -> block \(selection)")
            body.select(selection)
            if let actual = body.snapshot() { engine.confirm(actual) }
        }
        stateChanged()
    }

    /// Starts over when the note body gets focus or shows another note: in Normal mode to read
    /// and move around an existing note, in Insert mode for a new, empty one so typing can start
    /// right away. Returns whether that happened.
    @discardableResult
    private func noticeOpenedNote(_ body: AccessibilityText) -> Bool {
        let identifier = body.noteIdentifier
        if let openNote, CFEqual(openNote.element, body.element), openNote.identifier == identifier { return false }
        openNote = (body.element, identifier)
        pendingSeparator = nil
        if let snapshot = body.snapshot(), !snapshot.text.isEmpty {
            let selection = engine.enterNormalMode(in: snapshot)
            trace("opened note \(identifier ?? "?"), Normal mode, block \(selection)")
            body.select(selection)
            if let actual = body.snapshot() { engine.confirm(actual) }
        } else {
            trace("opened empty note \(identifier ?? "?"), Insert mode")
            engine.reset()
        }
        stateChanged()
        return true
    }

    private func stateChanged() {
        tap?.passesTypingKeys = engine.mode == .insert && !isInNoteList
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
