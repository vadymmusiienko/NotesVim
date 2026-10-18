// End-to-end test: drives the real Notes app with synthetic key presses while NotesVim runs,
// then reads the note back through Accessibility and compares.
//
// Only ever edits a note whose first line is "NotesVim scratch". Run via scripts/e2e.sh.
import AppKit
import ApplicationServices
import Carbon

let title = "NotesVim scratch\n"

struct Case {
    let start: String
    let keys: String
    var expected: String = ""
    /// Keyboard layout to type with (input source ID); the commands must still work.
    var layout: String? = nil
    /// Custom verification for results that depend on window size: (body text, caret, element).
    var check: ((String, NSRange, AXUIElement) -> String?)? = nil
}

let longParagraph = Array(repeating: "lorem ipsum dolor sit amet", count: 30).joined(separator: " ")
let manyLines = (1...120).map { "line \($0)" }.joined(separator: "\n")

func line(_ element: AXUIElement, _ index: Int) -> Int {
    var value: CFTypeRef?
    AXUIElementCopyParameterizedAttributeValue(element, "AXLineForIndex" as CFString, index as CFNumber, &value)
    return (value as? NSNumber)?.intValue ?? -1
}

func visible(_ element: AXUIElement) -> NSRange {
    var range = CFRange()
    AXValueGetValue(attribute(element, "AXVisibleCharacterRange") as! AXValue, .cfRange, &range)
    return NSRange(location: range.location, length: range.length)
}

let cases: [Case] = [
    Case(start: "|hello world", keys: "w", expected: "hello |world"),
    Case(start: "hello |world", keys: "dw", expected: "hello| "),
    Case(start: "one two |three", keys: "cwXYZ<Esc>", expected: "one two XY|Z"),
    Case(start: "|line one\nline two\nline three", keys: "jdd", expected: "line one\n|line three"),
    Case(start: "|abc", keys: "x", expected: "|bc"),
    Case(start: "|abc", keys: "xp", expected: "b|ac"),
    Case(start: "|one\ntwo", keys: "yyp", expected: "one\n|one\ntwo"),
    Case(start: "|one two", keys: "veU", expected: "|ONE two"),
    Case(start: "|one two three", keys: "dwu", expected: "|one two three"),
    Case(start: "|abc", keys: "xu<C-r>", expected: "|bc"),
    Case(start: "say \u{201C}hel|lo\u{201D} now", keys: "ci\"bye<Esc>", expected: "say \u{201C}by|e\u{201D} now"),
    Case(start: "|a\nb\nc", keys: "3J", expected: "a b| c"),
    Case(start: "|word", keys: "A!<Esc>", expected: "word|!"),
    Case(start: "|abc", keys: "onew<Esc>", expected: "abc\nne|w"),
    Case(start: "|abc def", keys: "vwd", expected: "|ef"),
    Case(start: "|a b c d", keys: "dw..", expected: "|d"),
    Case(start: "|a👍b", keys: "ll", expected: "a👍|b"),
    Case(start: "|a,b,c", keys: "f,;x", expected: "a,b|c"),
    Case(start: "|one\ntwo\nthree", keys: "Vjd", expected: "|three"),
    Case(start: "|hello", keys: "~~~", expected: "HEL|lo"),
    Case(start: "x |abc", keys: "ihi <Esc>", expected: "x hi| abc"),
    Case(start: "one\n|two", keys: "kA!<Esc>jx", expected: "one!\nt|w"),
    Case(start: "|a\nb\nc", keys: "G", expected: "a\nb\n|c"),
    Case(start: "x |(a, b) y", keys: "di(", expected: "x (|) y"),
    Case(start: "|a b", keys: "2x", expected: "|b"),
    // One undo step per Vim change, even though Notes merges Accessibility edits by default.
    Case(start: "|abcd", keys: "xxu", expected: "|bcd"),
    Case(start: "|abc", keys: "ifoo<Esc>xu", expected: "f|ooabc"),
    Case(start: "|one two three", keys: "dwdwuu", expected: "|one two three"),
    Case(start: "|one\ntwo", keys: "ddpu", expected: "tw|o"),
    Case(start: "|one\ntwo", keys: "yyjp", expected: "one\ntwo\n|one"),
    // j moves by wrapped line inside a long paragraph, and back with k.
    Case(start: "|" + longParagraph, keys: "j", check: { text, caret, body in
        let titleLength = title.utf16.count
        let first = line(body, titleLength)
        let now = line(body, titleLength + caret.location)
        return text == longParagraph && caret.length == 1 && now == first + 1 && caret.location > 0 ? nil : "caret \(caret) on line \(now), paragraph starts on line \(first)"
    }),
    Case(start: "|" + longParagraph, keys: "jk", expected: "|" + longParagraph),
    // Notes scrolls to keep the cursor visible.
    Case(start: "|" + manyLines, keys: "G", check: { _, caret, body in
        let absolute = caret.location + title.utf16.count
        let range = visible(body)
        return range.contains(absolute) ? nil : "caret \(absolute) not visible in \(range)"
    }),
    Case(start: "|" + manyLines, keys: "<C-d><C-d><C-d>", check: { _, caret, body in
        let absolute = caret.location + title.utf16.count
        let range = visible(body)
        return caret.location > 40 && range.contains(absolute) ? nil : "caret \(caret.location) visible \(range)"
    }),
    // Commands keep working on a non-Latin layout; f still searches for the typed letter.
    Case(start: "|hello world", keys: "wx", expected: "hello |orld", layout: "com.apple.keylayout.Russian"),
    Case(start: "|привет мир", keys: "fрx", expected: "п|ивет мир", layout: "com.apple.keylayout.Russian"),
]

// US / ABC key codes.
let plain: [Character: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
    "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
    "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
    "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50, " ": 49,
]
let shifted: [Character: Character] = [
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
    "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
]

func post(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
        event.flags = flags
        event.post(tap: .cghidEventTap)
        usleep(12_000)
    }
    usleep(30_000)
}

let russian: [Character: Character] = [
    "й": "q", "ц": "w", "у": "e", "к": "r", "е": "t", "н": "y", "г": "u", "ш": "i", "щ": "o", "з": "p",
    "ф": "a", "ы": "s", "в": "d", "а": "f", "п": "g", "р": "h", "о": "j", "л": "k", "д": "l",
    "я": "z", "ч": "x", "с": "c", "м": "v", "и": "b", "т": "n", "ь": "m",
]

func selectInputSource(_ identifier: String) {
    let filter = [kTISPropertyInputSourceID as String: identifier] as CFDictionary
    guard let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
          let source = sources.first else { fatalError("input source \(identifier) is not enabled") }
    TISSelectInputSource(source)
    usleep(200_000)
}

func currentInputSource() -> String {
    let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    return Unmanaged<CFString>.fromOpaque(TISGetInputSourceProperty(source, kTISPropertyInputSourceID)).takeUnretainedValue() as String
}

func type(_ keys: String) {
    var rest = Substring(keys)
    while let character = rest.first {
        if character == "<", let close = rest.firstIndex(of: ">") {
            let name = rest[rest.index(after: rest.startIndex)..<close]
            rest = rest[rest.index(after: close)...]
            switch name {
            case "Esc": post(53)
            case "CR": post(36)
            case "BS": post(51)
            default:
                if name.hasPrefix("C-"), let code = plain[name.last!] { post(code, .maskControl) }
            }
            continue
        }
        rest = rest.dropFirst()
        if let latin = russian[character], let code = plain[latin] {
            post(code)
        } else if let code = plain[character] {
            post(code)
        } else if let base = shifted[character], let code = plain[base] {
            post(code, .maskShift)
        } else if character.isUppercase, let code = plain[Character(character.lowercased())] {
            post(code, .maskShift)
        } else {
            fatalError("no key code for \(character)")
        }
    }
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return value
}

func range(_ element: AXUIElement) -> NSRange {
    var range = CFRange()
    AXValueGetValue(attribute(element, kAXSelectedTextRangeAttribute) as! AXValue, .cfRange, &range)
    return NSRange(location: range.location, length: range.length)
}

func select(_ element: AXUIElement, _ range: NSRange) {
    var cfRange = CFRange(location: range.location, length: range.length)
    AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, AXValueCreate(.cfRange, &cfRange)!)
}

func noteBody() -> AXUIElement {
    let notes = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes")[0]
    let app = AXUIElementCreateApplication(notes.processIdentifier)
    guard let focused = attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else {
        fatalError("Notes has no focused element")
    }
    let element = focused as! AXUIElement
    guard attribute(element, kAXRoleAttribute) as? String == "AXTextArea",
          let value = attribute(element, kAXValueAttribute) as? String, value.hasPrefix(title) else {
        fatalError("The focused note is not the NotesVim scratch note. Refusing to edit it.")
    }
    return element
}

func marked(_ text: String, _ selection: NSRange) -> String {
    let ns = text as NSString
    if selection.length > 1 {
        return ns.substring(to: selection.location) + "[" + ns.substring(with: selection) + "]"
            + ns.substring(from: selection.location + selection.length)
    }
    return ns.substring(to: selection.location) + "|" + ns.substring(from: selection.location)
}

let filter = CommandLine.arguments.dropFirst().first
var failures = 0
let notes = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes")[0]
notes.activate()
usleep(400_000)

for (index, testCase) in cases.enumerated() {
    if let filter, !testCase.keys.contains(filter) { continue }
    let body = noteBody()
    let current = attribute(body, kAXValueAttribute) as! String
    let caret = (testCase.start as NSString).range(of: "|").location
    let start = testCase.start.replacingOccurrences(of: "|", with: "")
    // Replace everything below the title line.
    select(body, NSRange(location: title.utf16.count, length: current.utf16.count - title.utf16.count))
    AXUIElementSetAttributeValue(body, kAXSelectedTextAttribute as CFString, start as CFString)
    usleep(150_000)
    type("<Esc>")
    usleep(150_000)
    select(body, NSRange(location: title.utf16.count + caret, length: 0))
    usleep(250_000)
    let originalLayout = currentInputSource()
    if let layout = testCase.layout { selectInputSource(layout) }
    type(testCase.keys)
    usleep(450_000)
    if testCase.layout != nil { selectInputSource(originalLayout) }

    let text = attribute(body, kAXValueAttribute) as! String
    var selection = range(body)
    let bodyText = String(text.dropFirst(title.count))
    selection.location -= title.utf16.count
    let problem: String?
    if let check = testCase.check {
        problem = check(bodyText, selection, body)
    } else {
        let result = selection.location >= 0 ? marked(bodyText, selection) : "selection in title: \(selection)"
        problem = result == testCase.expected ? nil : "expected \(testCase.expected.debugDescription)\n     got      \(result.debugDescription)"
    }
    if problem != nil { failures += 1 }
    let name = testCase.start.count > 40 ? String(testCase.start.prefix(40)) + "…" : testCase.start
    print("\(problem == nil ? "PASS" : "FAIL") #\(index) \(testCase.keys.debugDescription) on \(name.debugDescription)"
        + (problem.map { "\n     \($0)" } ?? ""))
}
type("<Esc>")
print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
