import Foundation

enum Token: Equatable {
    case ch(Character, literal: Character)
    case ctrl(Character)
    case escape
    case enter
    case unknown

    init(_ key: VimKey) {
        if key.isEscape {
            self = .escape
            return
        }
        switch key.special {
        case .escape: self = .escape
        case .enter: self = .enter
        case .backspace, .left: self = .ch("h", literal: "h")
        case .right: self = .ch("l", literal: "l")
        case .up: self = .ch("k", literal: "k")
        case .down: self = .ch("j", literal: "j")
        case .tab: self = .unknown
        case nil:
            guard let command = key.command else {
                self = .unknown
                return
            }
            if key.control {
                self = .ctrl(Character(command.lowercased()))
            } else {
                self = .ch(command, literal: key.literal ?? command)
            }
        }
    }

    var char: Character? {
        if case let .ch(character, _) = self { return character }
        return nil
    }

    var literal: Character? {
        switch self {
        case let .ch(_, literal): return literal
        case .enter: return "\n"
        default: return nil
        }
    }
}

enum Motion: Equatable {
    case left, right, down, up
    case screenDown, screenUp
    case wordForward(big: Bool), wordBackward(big: Bool)
    case wordEnd(big: Bool), wordEndBackward(big: Bool)
    case lineStart, firstNonBlank, lineEnd
    case firstNonBlankOfLine // _
    case nextLineFirstNonBlank, previousLineFirstNonBlank // + and Enter, -
    case firstLine, lastLine // gg, G
    case paragraphForward, paragraphBackward
    case find(Character, forward: Bool, till: Bool)
    case repeatFind(reverse: Bool)
    case matchPair
    case halfPageDown, halfPageUp, pageDown, pageUp
    case screenTop, screenMiddle, screenBottom

    var isVertical: Bool {
        switch self {
        case .down, .up, .screenDown, .screenUp, .halfPageDown, .halfPageUp, .pageDown, .pageUp: return true
        default: return false
        }
    }
}

enum TextObject: Equatable {
    case word(big: Bool, around: Bool)
    case quote(Character, around: Bool)
    case block(open: Character, close: Character, around: Bool)
    case paragraph(around: Bool)
}

enum Operator: Equatable {
    case delete, change, yank
}

enum OperatorTarget: Equatable {
    case motion(Motion)
    case textObject(TextObject)
    case line
}

enum InsertKind: Equatable {
    case before, after, firstNonBlank, lineStart, lineEnd, openBelow, openAbove

    var opensLine: Bool { self == .openBelow || self == .openAbove }
}

enum VisualOperation: Equatable {
    case delete, deleteLines, change, changeLines, yank, yankLines
    case toggleCase, lowercase, uppercase, replace(Character), join, put, indent, outdent
}

enum Command: Equatable {
    case move(Motion)
    case operate(Operator, OperatorTarget)
    case deleteChar, deleteCharBefore
    case substitute, substituteLine
    case deleteToEnd, changeToEnd, yankLine
    case replace(Character)
    case toggleCase
    case join
    case put(before: Bool)
    case insert(InsertKind)
    case undo, redo, repeatLast
    case visual(linewise: Bool)
    case indent, outdent
    case search, searchNext, searchPrevious
    case escape
    // Visual mode only
    case swapVisualEnds
    case selectTextObject(TextObject)
    case visualOperation(VisualOperation)
}

struct ParsedCommand: Equatable {
    var command: Command
    var count: Int?
}

enum ParseResult: Equatable {
    case incomplete
    case invalid
    case complete(ParsedCommand)
}

/// Parses a pending key sequence such as `2d3w`, `ci"` or `gg` into a command.
struct Parser {
    private let tokens: [Token]
    private var index = 0

    static func parse(_ tokens: [Token], visual: Bool) -> ParseResult {
        var parser = Parser(tokens: tokens)
        return visual ? parser.parseVisual() : parser.parseNormal()
    }

    private init(tokens: [Token]) { self.tokens = tokens }

    private mutating func next() -> Token? {
        guard index < tokens.count else { return nil }
        defer { index += 1 }
        return tokens[index]
    }

    private mutating func readCount() -> Int? {
        var count: Int?
        while index < tokens.count, let character = tokens[index].char, let digit = character.wholeNumberValue,
              character.isASCII, digit > 0 || count != nil {
            count = min((count ?? 0) * 10 + digit, 99_999)
            index += 1
        }
        return count
    }

    private static func multiply(_ a: Int?, _ b: Int?) -> Int? {
        switch (a, b) {
        case (nil, nil): return nil
        case let (a?, nil): return a
        case let (nil, b?): return b
        case let (a?, b?): return min(a * b, 99_999)
        }
    }

    private mutating func parseNormal() -> ParseResult {
        let count = readCount()
        guard let token = next() else { return .incomplete }
        let complete = { (command: Command) in ParseResult.complete(ParsedCommand(command: command, count: count)) }

        if token == .escape { return complete(.escape) }
        if case .ctrl("r") = token { return complete(.redo) }

        if token.char == "g" {
            guard let second = next() else { return .incomplete }
            if second.char == "I" { return complete(.insert(.lineStart)) }
            index -= 1
        }

        switch parseMotion(token) {
        case .incomplete: return .incomplete
        case let .motion(motion): return complete(.move(motion))
        case .notAMotion: break
        }

        guard let character = token.char else { return .invalid }
        switch character {
        case "d", "c", "y":
            let op: Operator = character == "d" ? .delete : character == "c" ? .change : .yank
            let secondCount = readCount()
            let total = Parser.multiply(count, secondCount)
            guard let target = next() else { return .incomplete }
            if target.char == character {
                return .complete(ParsedCommand(command: .operate(op, .line), count: total))
            }
            if target.char == "i" || target.char == "a" {
                guard let kind = next() else { return .incomplete }
                guard let object = Parser.textObject(kind, around: target.char == "a") else { return .invalid }
                return .complete(ParsedCommand(command: .operate(op, .textObject(object)), count: total))
            }
            switch parseMotion(target) {
            case .incomplete: return .incomplete
            case let .motion(motion): return .complete(ParsedCommand(command: .operate(op, .motion(motion)), count: total))
            case .notAMotion: return .invalid
            }
        case ">", "<":
            guard let second = next() else { return .incomplete }
            guard second.char == character else { return .invalid }
            return complete(character == ">" ? .indent : .outdent)
        case "r":
            guard let second = next() else { return .incomplete }
            guard let literal = second.literal else { return .invalid }
            return complete(.replace(literal))
        case "x": return complete(.deleteChar)
        case "X": return complete(.deleteCharBefore)
        case "s": return complete(.substitute)
        case "S": return complete(.substituteLine)
        case "D": return complete(.deleteToEnd)
        case "C": return complete(.changeToEnd)
        case "Y": return complete(.yankLine)
        case "~": return complete(.toggleCase)
        case "J": return complete(.join)
        case "p": return complete(.put(before: false))
        case "P": return complete(.put(before: true))
        case "i": return complete(.insert(.before))
        case "a": return complete(.insert(.after))
        case "I": return complete(.insert(.firstNonBlank))
        case "A": return complete(.insert(.lineEnd))
        case "o": return complete(.insert(.openBelow))
        case "O": return complete(.insert(.openAbove))
        case "u": return complete(.undo)
        case ".": return complete(.repeatLast)
        case "v": return complete(.visual(linewise: false))
        case "V": return complete(.visual(linewise: true))
        case "/", "?": return complete(.search)
        case "n": return complete(.searchNext)
        case "N": return complete(.searchPrevious)
        default: return .invalid
        }
    }

    private mutating func parseVisual() -> ParseResult {
        let count = readCount()
        guard let token = next() else { return .incomplete }
        let complete = { (command: Command) in ParseResult.complete(ParsedCommand(command: command, count: count)) }

        if token == .escape { return complete(.escape) }

        switch parseMotion(token) {
        case .incomplete: return .incomplete
        case let .motion(motion): return complete(.move(motion))
        case .notAMotion: break
        }

        guard let character = token.char else { return .invalid }
        switch character {
        case "i", "a":
            guard let kind = next() else { return .incomplete }
            guard let object = Parser.textObject(kind, around: character == "a") else { return .invalid }
            return complete(.selectTextObject(object))
        case "r":
            guard let second = next() else { return .incomplete }
            guard let literal = second.literal else { return .invalid }
            return complete(.visualOperation(.replace(literal)))
        case "o", "O": return complete(.swapVisualEnds)
        case "d", "x": return complete(.visualOperation(.delete))
        case "X", "D": return complete(.visualOperation(.deleteLines))
        case "c", "s": return complete(.visualOperation(.change))
        case "C", "S", "R": return complete(.visualOperation(.changeLines))
        case "y": return complete(.visualOperation(.yank))
        case "Y": return complete(.visualOperation(.yankLines))
        case "~": return complete(.visualOperation(.toggleCase))
        case "u": return complete(.visualOperation(.lowercase))
        case "U": return complete(.visualOperation(.uppercase))
        case "J": return complete(.visualOperation(.join))
        case "p", "P": return complete(.visualOperation(.put))
        case ">": return complete(.visualOperation(.indent))
        case "<": return complete(.visualOperation(.outdent))
        case "v": return complete(.visual(linewise: false))
        case "V": return complete(.visual(linewise: true))
        default: return .invalid
        }
    }

    private enum MotionParse {
        case motion(Motion)
        case incomplete
        case notAMotion
    }

    private mutating func parseMotion(_ token: Token) -> MotionParse {
        switch token {
        case .enter: return .motion(.nextLineFirstNonBlank)
        case .ctrl("d"): return .motion(.halfPageDown)
        case .ctrl("u"): return .motion(.halfPageUp)
        case .ctrl("f"): return .motion(.pageDown)
        case .ctrl("b"): return .motion(.pageUp)
        case .ctrl("n"): return .motion(.down)
        case .ctrl("p"): return .motion(.up)
        case .ch: break
        default: return .notAMotion
        }
        guard let character = token.char else { return .notAMotion }
        switch character {
        case "h": return .motion(.left)
        case "l", " ": return .motion(.right)
        case "j": return .motion(.down)
        case "k": return .motion(.up)
        case "w": return .motion(.wordForward(big: false))
        case "W": return .motion(.wordForward(big: true))
        case "b": return .motion(.wordBackward(big: false))
        case "B": return .motion(.wordBackward(big: true))
        case "e": return .motion(.wordEnd(big: false))
        case "E": return .motion(.wordEnd(big: true))
        case "0": return .motion(.lineStart)
        case "^": return .motion(.firstNonBlank)
        case "$": return .motion(.lineEnd)
        case "_": return .motion(.firstNonBlankOfLine)
        case "+": return .motion(.nextLineFirstNonBlank)
        case "-": return .motion(.previousLineFirstNonBlank)
        case "G": return .motion(.lastLine)
        case "{": return .motion(.paragraphBackward)
        case "}": return .motion(.paragraphForward)
        case "%": return .motion(.matchPair)
        case ";": return .motion(.repeatFind(reverse: false))
        case ",": return .motion(.repeatFind(reverse: true))
        case "H": return .motion(.screenTop)
        case "M": return .motion(.screenMiddle)
        case "L": return .motion(.screenBottom)
        case "f", "F", "t", "T":
            guard let target = next() else { return .incomplete }
            guard case let .ch(_, literal) = target else { return .notAMotion }
            return .motion(.find(literal, forward: character == "f" || character == "t", till: character == "t" || character == "T"))
        case "g":
            guard let second = next() else { return .incomplete }
            switch second.char {
            case "g": return .motion(.firstLine)
            case "e": return .motion(.wordEndBackward(big: false))
            case "E": return .motion(.wordEndBackward(big: true))
            case "j": return .motion(.screenDown)
            case "k": return .motion(.screenUp)
            case "0": return .motion(.lineStart)
            case "_": return .motion(.firstNonBlankOfLine)
            default: return .notAMotion
            }
        default: return .notAMotion
        }
    }

    private static func textObject(_ token: Token, around: Bool) -> TextObject? {
        guard let character = token.char else { return nil }
        switch character {
        case "w": return .word(big: false, around: around)
        case "W": return .word(big: true, around: around)
        case "\"", "'", "`": return .quote(character, around: around)
        case "(", ")", "b": return .block(open: "(", close: ")", around: around)
        case "[", "]": return .block(open: "[", close: "]", around: around)
        case "{", "}", "B": return .block(open: "{", close: "}", around: around)
        case "<", ">": return .block(open: "<", close: ">", around: around)
        case "p": return .paragraph(around: around)
        default: return nil
        }
    }
}
