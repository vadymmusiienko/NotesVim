import Foundation
@testable import VimEngine

/// Plays the role of Notes: holds text and a selection, applies the engine's responses, and
/// types characters itself when the engine lets a key through in Insert mode.
///
/// Text is written with a `|` marking the cursor (the start of the block cursor in Normal
/// mode). Visual selections render as `[selected]`.
final class Harness {
    let engine: VimEngine
    let clipboard: InMemoryClipboard
    private(set) var text: String
    private(set) var selection: NSRange
    private(set) var actions: [HostAction] = []
    var layout: ScreenLayout?

    /// Starts in Normal mode with the cursor where `|` is.
    init(_ marked: String, clipboard: Register? = nil) {
        let caret = (marked as NSString).range(of: "|").location
        text = marked.replacingOccurrences(of: "|", with: "")
        selection = NSRange(location: caret, length: 0)
        self.clipboard = InMemoryClipboard(clipboard)
        engine = VimEngine(clipboard: self.clipboard)
        press(.escape)
        // Escape moved the cursor one character left; put it back where the test asked for it.
        selection = NSRange(location: caret, length: 0)
        if let restored = engine.synchronize(with: snapshot) { selection = restored }
    }

    var snapshot: Snapshot { Snapshot(text: text, selection: selection) }

    var mode: Mode { engine.mode }

    var marked: String {
        let ns = text as NSString
        if engine.mode == .visual || engine.mode == .visualLine {
            return ns.substring(to: selection.location) + "[" + ns.substring(with: selection) + "]"
                + ns.substring(from: selection.location + selection.length)
        }
        return ns.substring(to: selection.location) + "|" + ns.substring(from: selection.location)
    }

    /// Clicks somewhere, like the user would with the mouse.
    func click(_ location: Int) {
        selection = NSRange(location: location, length: 0)
        if let restored = engine.synchronize(with: snapshot) { selection = restored }
    }

    @discardableResult
    func keys(_ sequence: String) -> Harness {
        for key in Harness.parse(sequence) { press(key) }
        return self
    }

    func press(_ key: VimKey) {
        let response = engine.handle(key, in: snapshot, layout: layout)
        guard response.handled else {
            type(key)
            return
        }
        let edited = NSMutableString(string: text)
        for edit in response.edits { edited.replaceCharacters(in: edit.range, with: edit.text) }
        text = edited as String
        if let newSelection = response.selection { selection = newSelection }
        actions += response.actions
        engine.confirm(snapshot)
    }

    private func type(_ key: VimKey) {
        let ns = NSMutableString(string: text)
        switch key.special {
        case .backspace:
            guard selection.location > 0 else { return }
            ns.deleteCharacters(in: NSRange(location: selection.location - 1, length: 1))
            selection = NSRange(location: selection.location - 1, length: 0)
        case .enter:
            ns.replaceCharacters(in: selection, with: "\n")
            selection = NSRange(location: selection.location + 1, length: 0)
        default:
            guard let character = key.literal else { return }
            let string = String(character)
            ns.replaceCharacters(in: selection, with: string)
            selection = NSRange(location: selection.location + string.utf16.count, length: 0)
        }
        text = ns as String
    }

    /// `"d2w"`, `"ihello<Esc>"`, `"<C-r>"`, `"<CR>"`, `"<BS>"`.
    static func parse(_ sequence: String) -> [VimKey] {
        var keys: [VimKey] = []
        var characters = Array(sequence)[...]
        while let character = characters.first {
            characters = characters.dropFirst()
            guard character == "<", let close = characters.firstIndex(of: ">"), close != characters.startIndex else {
                keys.append(.char(character))
                continue
            }
            let name = String(characters[characters.startIndex..<close])
            characters = characters[(close + 1)...]
            switch name {
            case "Esc": keys.append(.escape)
            case "CR": keys.append(.enter)
            case "BS": keys.append(.backspace)
            case "Left": keys.append(.left)
            case "Right": keys.append(.right)
            case "Up": keys.append(.up)
            case "Down": keys.append(.down)
            case let control where control.hasPrefix("C-"): keys.append(.ctrl(control.last!))
            default: keys.append(contentsOf: ("<" + name + ">").map { .char($0) })
            }
        }
        return keys
    }
}

/// Fixed-width soft wrapping, standing in for Notes' layout in `gj` / `gk` tests.
struct WrappedLayout: ScreenLayout {
    let lines: [NSRange]
    let visible: NSRange?

    init(_ text: String, width: Int, visible: NSRange? = nil) {
        var lines: [NSRange] = []
        let ns = text as NSString
        var start = 0
        var index = 0
        while index < ns.length {
            if ns.character(at: index) == 0x0A {
                lines.append(NSRange(location: start, length: index + 1 - start))
                start = index + 1
            } else if index + 1 - start == width {
                lines.append(NSRange(location: start, length: index + 1 - start))
                start = index + 1
            }
            index += 1
        }
        lines.append(NSRange(location: start, length: ns.length - start))
        self.lines = lines
        self.visible = visible
    }

    func lineNumber(at index: Int) -> Int? {
        lines.firstIndex { index >= $0.location && index < $0.location + max($0.length, 1) } ?? lines.indices.last
    }

    func range(ofLine line: Int) -> NSRange? { lines.indices.contains(line) ? lines[line] : nil }

    func visibleRange() -> NSRange? { visible }
}
