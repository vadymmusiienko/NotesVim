import Foundation

public enum Mode: Equatable, Sendable {
    case insert
    case normal
    case visual
    case visualLine

    var isVisual: Bool { self == .visual || self == .visualLine }
}

/// A key press as the engine sees it.
///
/// `command` is the character used to interpret Vim commands, `literal` is the character
/// actually typed. They differ on non-Latin keyboard layouts: on a Ukrainian layout the
/// physical `J` key types "о" (literal) but still means `j` (command), while `fо` must
/// search for "о".
public struct VimKey: Hashable, Sendable {
    public enum Special: Hashable, Sendable {
        case escape, enter, backspace, tab, left, right, up, down
    }

    public var special: Special?
    public var command: Character?
    public var literal: Character?
    public var control: Bool

    public init(special: Special? = nil, command: Character? = nil, literal: Character? = nil, control: Bool = false) {
        self.special = special
        self.command = command
        self.literal = literal
        self.control = control
    }

    public static func char(_ character: Character, literal: Character? = nil) -> VimKey {
        VimKey(command: character, literal: literal ?? character)
    }

    public static func ctrl(_ character: Character) -> VimKey {
        VimKey(command: character, literal: character, control: true)
    }

    public static let escape = VimKey(special: .escape)
    public static let enter = VimKey(special: .enter)
    public static let backspace = VimKey(special: .backspace)
    public static let tab = VimKey(special: .tab)
    public static let left = VimKey(special: .left)
    public static let right = VimKey(special: .right)
    public static let up = VimKey(special: .up)
    public static let down = VimKey(special: .down)

    public var isEscape: Bool { special == .escape || (control && command == "[") }
}

/// What the focused text element currently contains.
public struct Snapshot: Equatable, Sendable {
    public var text: String
    public var selection: NSRange

    public init(text: String, selection: NSRange) {
        self.text = text
        self.selection = selection
    }
}

/// Replace `range` with `text`. Edits in a list are applied one after another,
/// each in the coordinates of the text produced by the previous one.
public struct Edit: Equatable, Sendable {
    public var range: NSRange
    public var text: String

    public init(range: NSRange, text: String) {
        self.range = range
        self.text = text
    }

    public init(_ start: Int, _ end: Int, _ text: String) {
        self.init(range: NSRange(location: start, length: end - start), text: text)
    }
}

extension Edit {
    /// Notes (like other Cocoa text views) treats a one-character insertion or deletion as
    /// typing and merges it into the undo step of any edit it touches, even across cursor
    /// movement, so `x x u` would bring back both characters. Rewriting a neighbouring
    /// character as itself turns it into an ordinary replacement with its own undo step.
    ///
    /// The left neighbour is preferred: the replacement takes the formatting of the first
    /// replaced character, which is then the neighbour itself. Line breaks (they carry list
    /// and checklist styles) and attachments are never rewritten.
    public func ownUndoStep(in text: NSString) -> Edit {
        guard range.length + self.text.utf16.count == 1 else { return self }
        func rewritable(_ range: NSRange) -> Bool {
            let string = text.substring(with: range)
            return !string.contains("\n") && !string.contains("\u{FFFC}")
        }
        if range.location > 0 {
            let left = text.rangeOfComposedCharacterSequence(at: range.location - 1)
            if rewritable(left) {
                return Edit(range: NSRange(location: left.location, length: left.length + range.length),
                            text: text.substring(with: left) + self.text)
            }
        }
        let end = range.location + range.length
        if end < text.length {
            let right = text.rangeOfComposedCharacterSequence(at: end)
            if rewritable(right) {
                return Edit(range: NSRange(location: range.location, length: range.length + right.length),
                            text: self.text + text.substring(with: right))
            }
        }
        return self
    }
}

/// Things the engine cannot do through text edits and asks the host app to do instead,
/// typically by sending the matching Notes keyboard shortcut.
public enum HostAction: Equatable, Sendable {
    case undo, redo, indent, outdent, find, findNext, findPrevious
}

public struct Response: Equatable, Sendable {
    /// When false the key must reach the app untouched.
    public var handled: Bool
    public var edits: [Edit]
    /// Selection to set once the edits are applied. `nil` leaves it alone.
    public var selection: NSRange?
    public var actions: [HostAction]

    public init(handled: Bool, edits: [Edit] = [], selection: NSRange? = nil, actions: [HostAction] = []) {
        self.handled = handled
        self.edits = edits
        self.selection = selection
        self.actions = actions
    }

    public static let pass = Response(handled: false)
    public static let swallow = Response(handled: true)
}

public struct Register: Equatable, Sendable {
    public var text: String
    public var linewise: Bool

    public init(text: String, linewise: Bool) {
        self.text = text
        self.linewise = linewise
    }
}

/// Backing store for yank, delete and put.
public protocol Clipboard: AnyObject {
    func read() -> Register?
    func write(_ register: Register)
}

public final class InMemoryClipboard: Clipboard {
    public var register: Register?

    public init(_ register: Register? = nil) { self.register = register }

    public func read() -> Register? { register }
    public func write(_ register: Register) { self.register = register }
}

/// Visual (wrapped) line geometry, used by `gj`, `gk`, `H`, `M`, `L` and the paging keys.
public protocol ScreenLayout {
    func lineNumber(at index: Int) -> Int?
    func range(ofLine line: Int) -> NSRange?
    func visibleRange() -> NSRange?
}
