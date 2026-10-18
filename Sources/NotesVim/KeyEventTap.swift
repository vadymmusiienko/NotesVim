import Carbon.HIToolbox
import CoreGraphics
import Foundation
import os

/// Intercepts the key presses the window server delivers to Notes, and only those. Keys typed
/// into Raycast, Spotlight and other launchers never reach it, even though Notes stays the
/// active app while their panels are open.
///
/// The tap runs on its own thread and never waits for anything. In Insert mode it lets keys
/// through right there, so typing is exactly as fast as without NotesVim. Keys the Vim engine
/// has to see are swallowed and handed to the main thread in order. The main thread can then
/// take its time, including waiting for Notes to carry out shortcuts NotesVim posts to it:
/// those carry `syntheticEventMarker` and pass straight through. A key the main thread decides
/// not to handle after all is posted to Notes again.
final class KeyEventTap: @unchecked Sendable {
    /// Marks events NotesVim posts itself (shortcuts like ⌘Z) so the tap lets them through.
    static let syntheticEventMarker: Int64 = 0x4E56_494D // "NVIM"

    let processIdentifier: pid_t
    /// Return true when the key press was handled, false to have it typed into Notes.
    private let handler: @MainActor (CGEvent) -> Bool
    private let state = OSAllocatedUnfairLock(initialState: State())
    private var port: CFMachPort!
    private var runLoop: CFRunLoop?

    private struct State {
        var enabled = false
        var passesTypingKeys = true
        /// Key presses handed to the main thread and not decided on yet.
        var queued = 0
        var held: [Int64: HeldKey] = [:]
    }

    /// A physical key whose presses were swallowed. Its release is swallowed as well if the
    /// main thread handled a press, and passed on to Notes otherwise.
    private struct HeldKey {
        var queued = 0
        var handled = false
        var released = false
    }

    /// Fails without the Accessibility permission.
    init?(processIdentifier: pid_t, handler: @escaping @MainActor (CGEvent) -> Bool) {
        self.processIdentifier = processIdentifier
        self.handler = handler
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<KeyEventTap>.fromOpaque(refcon).takeUnretainedValue()
            return tap.process(type, event).map { Unmanaged.passUnretained($0) }
        }
        guard let port = CGEvent.tapCreateForPid(pid: processIdentifier, place: .headInsertEventTap, options: .defaultTap,
                                                 eventsOfInterest: mask, callback: callback,
                                                 userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return nil }
        CGEvent.tapEnable(tap: port, enable: false)
        self.port = port

        // The thread keeps the tap alive until `invalidate()` stops its run loop.
        let started = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(runLoop, CFMachPortCreateRunLoopSource(nil, self.port, 0), .commonModes)
            started.signal()
            CFRunLoopRun()
        }
        thread.name = "NotesVim key tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        started.wait()
    }

    /// Switched off, every key goes to Notes untouched.
    var isEnabled: Bool {
        get { state.withLock { $0.enabled } }
        set {
            state.withLock { $0.enabled = newValue }
            CGEvent.tapEnable(tap: port, enable: newValue)
        }
    }

    /// True in Insert mode: keys go to Notes directly, except those that may leave Insert mode
    /// (Escape and Control combinations, which include Ctrl-[).
    var passesTypingKeys: Bool {
        get { state.withLock { $0.passesTypingKeys } }
        set { state.withLock { $0.passesTypingKeys = newValue } }
    }

    /// Removes the tap. Call before letting go of it.
    func invalidate() {
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        if let runLoop { CFRunLoopStop(runLoop) }
    }

    // MARK: Tap thread

    private func process(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if isEnabled { CGEvent.tapEnable(tap: port, enable: true) }
            return event
        case .keyDown, .keyUp:
            if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker { return event }
            return type == .keyDown ? keyDown(event) : keyUp(event)
        default:
            return event
        }
    }

    private func keyDown(_ event: CGEvent) -> CGEvent? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let swallow = state.withLock { state in
            // Anything after a queued key waits its turn, so keys reach Notes in order.
            if state.queued == 0 {
                // ⌘ shortcuts always belong to Notes.
                if flags.contains(.maskCommand) { return false }
                if state.passesTypingKeys, keyCode != kVK_Escape, !flags.contains(.maskControl) { return false }
            }
            state.queued += 1
            state.held[keyCode, default: HeldKey()].queued += 1
            state.held[keyCode]?.released = false
            return true
        }
        guard swallow else { return event }
        nonisolated(unsafe) let pressed = event.copy() ?? event
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.deliver(pressed) }
        }
        return nil
    }

    private func keyUp(_ event: CGEvent) -> CGEvent? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let swallow = state.withLock { state in
            guard var held = state.held[keyCode] else { return false }
            if held.queued > 0 {
                // Decided once the main thread gets to the press.
                held.released = true
                state.held[keyCode] = held
                return true
            }
            state.held[keyCode] = nil
            return held.handled
        }
        return swallow ? nil : event
    }

    // MARK: Main thread

    @MainActor private func deliver(_ event: CGEvent) {
        let handled = handler(event)
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        state.withLockUnchecked { state in
            state.queued -= 1
            var held = state.held[keyCode] ?? HeldKey()
            held.queued -= 1
            // Posting while holding the lock keeps the tap thread from passing later keys first.
            if handled { held.handled = true } else { post(event) }
            if held.queued > 0 || (held.handled && !held.released) {
                state.held[keyCode] = held
            } else {
                if held.released, !held.handled, let release = event.copy() {
                    release.type = .keyUp
                    post(release)
                }
                state.held[keyCode] = nil
            }
        }
    }

    private func post(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        event.postToPid(processIdentifier)
    }
}
