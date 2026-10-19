// Plays the README demo in Notes with real key presses, shows a caption for every command, and
// records the Notes window with screencapture. Run through scripts/record-demo.sh.
//
// Usage: demo-driver <output.mov>
import AppKit
import ApplicationServices

// MARK: Notes window

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return value
}

func frame(of element: AXUIElement) -> CGRect {
    var origin = CGPoint.zero, size = CGSize.zero
    if let value = attribute(element, kAXPositionAttribute) { AXValueGetValue(value as! AXValue, .cgPoint, &origin) }
    if let value = attribute(element, kAXSizeAttribute) { AXValueGetValue(value as! AXValue, .cgSize, &size) }
    return CGRect(origin: origin, size: size)
}

func setFrame(_ element: AXUIElement, _ rect: CGRect) {
    var origin = rect.origin, size = rect.size
    AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &origin)!)
    AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
}

let notesApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes")[0]
let notes = AXUIElementCreateApplication(notesApp.processIdentifier)
let window = attribute(notes, kAXFocusedWindowAttribute) as! AXUIElement
guard (attribute(window, kAXTitleAttribute) as? String)?.hasPrefix("NotesVim Demo") == true else {
    fatalError("Notes is not showing the NotesVim Demo folder. Refusing to record anything else.")
}
func findTextArea(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
    if attribute(element, kAXRoleAttribute) as? String == "AXTextArea" { return element }
    guard depth < 5 else { return nil }
    for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        if let found = findTextArea(in: child, depth: depth + 1) { return found }
    }
    return nil
}
guard let body = findTextArea(in: window),
      (attribute(body, kAXValueAttribute) as? String)?.hasPrefix("Weekend trip") == true else {
    fatalError("The Weekend trip demo note must be open.")
}
AXUIElementSetAttributeValue(body, kAXFocusedAttribute as CFString, kCFBooleanTrue)
usleep(300_000)

let originalFrame = frame(of: window)
let recordingFrame = CGRect(x: 80, y: 80, width: 660, height: 420)
setFrame(window, recordingFrame)
usleep(400_000)

// Start in Insert mode at the beginning of the second line.
var start = CFRange(location: ("Weekend trip\n" as NSString).length, length: 0)
AXUIElementSetAttributeValue(body, kAXSelectedTextRangeAttribute as CFString, AXValueCreate(.cfRange, &start)!)

// Keep the mouse pointer out of the picture.
CGWarpMouseCursorPosition(CGPoint(x: recordingFrame.maxX + 300, y: recordingFrame.maxY + 200))

// MARK: Caption

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

final class Caption {
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let keys = NSTextField(labelWithString: "")
    let text = NSTextField(labelWithString: "")
    let noteBody: CGRect

    init(noteBody: CGRect) {
        self.noteBody = noteBody
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        let background = NSView()
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.86).cgColor
        background.layer?.cornerRadius = 12
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        keys.font = .monospacedSystemFont(ofSize: 19, weight: .bold)
        keys.textColor = NSColor(srgbRed: 1.0, green: 0.82, blue: 0.30, alpha: 1)
        text.font = .systemFont(ofSize: 17, weight: .medium)
        text.textColor = NSColor(white: 0.92, alpha: 1)
        let stack = NSStackView(views: [keys, text])
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 11, left: 18, bottom: 11, right: 18)
        background.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
    }

    func show(_ keyLabel: String, _ description: String) {
        keys.stringValue = keyLabel
        text.stringValue = description
        panel.contentView?.layoutSubtreeIfNeeded()
        let size = panel.contentView!.fittingSize
        // Centred near the bottom of the note body (Accessibility coordinates are top-left based).
        let screenHeight = NSScreen.screens[0].frame.maxY
        let origin = NSPoint(x: (noteBody.midX - size.width / 2).rounded(), y: (screenHeight - noteBody.maxY + 28).rounded())
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}

let caption = Caption(noteBody: frame(of: body))

// MARK: Keys

let codes: [Character: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
    "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
    "n": 45, "m": 46, ".": 47, " ": 49, ",": 43,
]

@Sendable func press(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
        event.flags = flags
        event.post(tap: .cghidEventTap)
        usleep(15_000)
    }
}

/// Types `keys` like a person would. `<Esc>` and `<C-x>` are special keys.
@Sendable func typeKeys(_ keys: String, gap: useconds_t = 140_000) {
    var rest = Substring(keys)
    while let character = rest.first {
        if character == "<", let close = rest.firstIndex(of: ">") {
            let name = rest[rest.index(after: rest.startIndex)..<close]
            rest = rest[rest.index(after: close)...]
            if name == "Esc" { press(53) } else if name.hasPrefix("C-"), let code = codes[name.last!] { press(code, .maskControl) }
        } else {
            rest = rest.dropFirst()
            if let code = codes[character] { press(code) } else if let code = codes[Character(character.lowercased())] { press(code, .maskShift) }
        }
        usleep(gap)
    }
}

func pause(_ seconds: Double) { usleep(useconds_t(seconds * 1_000_000)) }

func step(_ keyLabel: String, _ description: String, keys: String, gap: useconds_t = 140_000, after: Double = 1.1) {
    DispatchQueue.main.sync { caption.show(keyLabel, description) }
    pause(0.45)
    typeKeys(keys, gap: gap)
    pause(after)
}

// MARK: Recording

let output = CommandLine.arguments[1]
// Records until interrupted, like pressing Ctrl-C in the terminal.
let recorder = Process()
recorder.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
recorder.arguments = ["-x", "-v", "-R",
                      "\(Int(recordingFrame.minX)),\(Int(recordingFrame.minY)),\(Int(recordingFrame.width)),\(Int(recordingFrame.height))", output]

Thread {
    try! recorder.run()
    pause(1.5)
    step("Esc", "Normal mode: the cursor becomes a block", keys: "<Esc>")
    step("w w w", "jump word by word", keys: "www", gap: 380_000)
    step("j", "down a line", keys: "j")
    step("fn", "find the next “n”", keys: "fn")
    step("ciw", "change the word…", keys: "ciw", after: 0.5)
    step("ten", "…then type", keys: "ten", gap: 160_000, after: 0.4)
    step("Esc", "back to Normal mode", keys: "<Esc>")
    step("j dd", "delete a line", keys: "jdd", gap: 380_000)
    step("p", "put it back below", keys: "p")
    step("u u", "undo, twice", keys: "uu", gap: 600_000)
    step("o", "open a new line and type", keys: "o", after: 0.3)
    step("o", "open a new line and type", keys: "Charge the phone.", gap: 70_000, after: 0.3)
    step("Esc", "back to Normal mode", keys: "<Esc>")
    step("gg", "to the top", keys: "gg")
    step("Ctrl-h", "over to the note list", keys: "<C-h>")
    step("j j", "next notes", keys: "jj", gap: 700_000)
    step("l", "into the note", keys: "l")
    step("j j", "and keep going", keys: "jj", gap: 380_000, after: 1.4)
    DispatchQueue.main.sync { caption.hide() }
    pause(0.6)
    recorder.interrupt()
    recorder.waitUntilExit()
    setFrame(window, originalFrame)
    exit(0)
}.start()

app.run()
