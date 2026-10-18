import Foundation

/// Immutable view over the text of the focused element.
///
/// All positions are UTF-16 offsets, because that is what the macOS Accessibility API
/// uses for `AXSelectedTextRange`. Movement always steps over whole composed character
/// sequences so the cursor never lands inside an emoji or a combining sequence.
public struct TextBuffer: Sendable {
    public let string: String
    private let units: [UInt16]
    /// UTF-16 offset of the first character of every line. Always starts with 0.
    private let lineStarts: [Int]

    public init(_ string: String) {
        self.string = string
        self.units = Array(string.utf16)
        var starts = [0]
        for (index, unit) in units.enumerated() where unit == TextBuffer.newline {
            starts.append(index + 1)
        }
        self.lineStarts = starts
    }

    static let newline: UInt16 = 0x0A

    public var length: Int { units.count }
    public var lineCount: Int { lineStarts.count }

    func unit(_ index: Int) -> UInt16 { units[index] }

    func isNewline(_ index: Int) -> Bool { index < length && units[index] == TextBuffer.newline }

    // MARK: Characters

    /// Start of the composed character sequence containing `index`.
    func charStart(_ index: Int) -> Int {
        guard index > 0 else { return 0 }
        guard index < length else { return length }
        return (string as NSString).rangeOfComposedCharacterSequence(at: index).location
    }

    /// End (exclusive) of the composed character sequence starting at `index`.
    func charEnd(_ index: Int) -> Int {
        guard index < length else { return length }
        let range = (string as NSString).rangeOfComposedCharacterSequence(at: index)
        return range.location + range.length
    }

    /// Start of the character immediately before `index`.
    func prevCharStart(_ index: Int) -> Int {
        guard index > 0 else { return 0 }
        return (string as NSString).rangeOfComposedCharacterSequence(at: index - 1).location
    }

    func character(at index: Int) -> Character? {
        guard index < length else { return nil }
        return Character(substring(index, charEnd(index)))
    }

    func scalar(at index: Int) -> Unicode.Scalar? {
        guard index < length else { return nil }
        let unit = units[index]
        if UTF16.isLeadSurrogate(unit), index + 1 < length {
            return Unicode.Scalar(UTF16.decode(UTF16.EncodedScalar([unit, units[index + 1]])))
        }
        return Unicode.Scalar(unit)
    }

    public func substring(_ start: Int, _ end: Int) -> String {
        guard end > start else { return "" }
        return (string as NSString).substring(with: NSRange(location: start, length: end - start))
    }

    // MARK: Lines

    func lineIndex(_ index: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= index { low = mid } else { high = mid - 1 }
        }
        return low
    }

    func lineStart(ofLine line: Int) -> Int { lineStarts[line] }

    func lineStart(_ index: Int) -> Int { lineStarts[lineIndex(index)] }

    /// Position of the line's terminating newline, or `length` for the last line.
    func lineEnd(_ index: Int) -> Int {
        let line = lineIndex(index)
        return line + 1 < lineStarts.count ? lineStarts[line + 1] - 1 : length
    }

    func isLineEmpty(_ index: Int) -> Bool { lineStart(index) == lineEnd(index) }

    func isLineBlank(_ index: Int) -> Bool { firstNonBlank(index) == lineEnd(index) }

    /// First non-blank character of the line containing `index` (or the line end).
    func firstNonBlank(_ index: Int) -> Int {
        var position = lineStart(index)
        let end = lineEnd(index)
        while position < end, isBlank(position) { position += 1 }
        return position
    }

    /// The right-most position a Normal mode cursor may occupy on this line.
    func lastCharStart(_ index: Int) -> Int {
        let start = lineStart(index)
        let end = lineEnd(index)
        return end > start ? prevCharStart(end) : start
    }

    /// Column in characters (not UTF-16 units) from the line start.
    func column(_ index: Int) -> Int {
        var position = lineStart(index)
        var column = 0
        while position < index {
            position = charEnd(position)
            column += 1
        }
        return column
    }

    /// Position at `column` characters into `line`, never past the line end.
    func position(line: Int, column: Int, allowLineEnd: Bool = false) -> Int {
        let start = lineStarts[line]
        let end = lineEnd(start)
        var position = start
        var remaining = column
        while remaining > 0, position < end {
            position = charEnd(position)
            remaining -= 1
        }
        if !allowLineEnd, position >= end, end > start { return prevCharStart(end) }
        return position
    }

    /// Clamps a position to where the Normal mode block cursor may sit.
    func clampNormal(_ index: Int) -> Int {
        let position = charStart(min(max(index, 0), length))
        let end = lineEnd(position)
        if position >= end, end > lineStart(position) { return prevCharStart(end) }
        return position
    }

    // MARK: Classes

    func isBlank(_ index: Int) -> Bool {
        guard index < length else { return false }
        return TextBuffer.isBlankUnit(units[index])
    }

    static func isBlankUnit(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0xA0 || (0x2000...0x200A).contains(unit) || unit == 0x3000
    }

    /// Vim's character class: 0 = blank or end of line, 1 = punctuation, 2 = word, 3 = emoji.
    /// With `bigWord` every non-blank is class 1.
    func wordClass(_ index: Int, bigWord: Bool) -> Int {
        guard index < length, units[index] != TextBuffer.newline else { return 0 }
        if TextBuffer.isBlankUnit(units[index]) { return 0 }
        if bigWord { return 1 }
        guard let scalar = scalar(at: index) else { return 1 }
        if scalar == "_" || CharacterSet.alphanumerics.contains(scalar) { return 2 }
        if scalar.properties.isEmojiPresentation || scalar.value >= 0x1F000 { return 3 }
        return 1
    }

    // MARK: Editing

    public func applying(_ edits: [Edit]) -> TextBuffer {
        let text = NSMutableString(string: string)
        for edit in edits { text.replaceCharacters(in: edit.range, with: edit.text) }
        return TextBuffer(text as String)
    }
}
