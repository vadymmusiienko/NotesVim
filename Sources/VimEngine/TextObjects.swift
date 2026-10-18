import Foundation

struct TextRange: Equatable {
    var start: Int
    /// Exclusive. For linewise ranges this is the end of the last line's content.
    var end: Int
    var linewise: Bool
}

extension TextBuffer {
    func textObject(_ object: TextObject, at position: Int, forChange: Bool) -> TextRange? {
        switch object {
        case let .word(big, around): return wordObject(at: position, bigWord: big, around: around)
        case let .quote(quote, around): return quoteObject(at: position, quote: quote, around: around)
        case let .block(open, close, around): return blockObject(at: position, open: open, close: close, around: around, forChange: forChange)
        case let .paragraph(around): return paragraphObject(at: position, around: around)
        }
    }

    /// `iw`, `aw`, `iW`, `aW`. Limited to the current line like Vim.
    private func wordObject(at position: Int, bigWord: Bool, around: Bool) -> TextRange? {
        let lineStart = lineStart(position)
        let lineEnd = lineEnd(position)
        guard lineEnd > lineStart else { return nil }
        let cls = wordClass(position, bigWord: bigWord)
        var start = position
        while start > lineStart, wordClass(prevCharStart(start), bigWord: bigWord) == cls { start = prevCharStart(start) }
        var end = position
        while end < lineEnd, wordClass(end, bigWord: bigWord) == cls { end = charEnd(end) }
        guard around else { return TextRange(start: start, end: end, linewise: false) }

        if cls == 0 {
            // On white space: the white space plus the following word.
            if end < lineEnd {
                let next = wordClass(end, bigWord: bigWord)
                while end < lineEnd, wordClass(end, bigWord: bigWord) == next { end = charEnd(end) }
            }
            return TextRange(start: start, end: end, linewise: false)
        }
        // On a word: include trailing white space, or leading white space when there is none.
        var trailing = end
        while trailing < lineEnd, wordClass(trailing, bigWord: bigWord) == 0 { trailing = charEnd(trailing) }
        if trailing > end { return TextRange(start: start, end: trailing, linewise: false) }
        var leading = start
        while leading > lineStart, wordClass(prevCharStart(leading), bigWord: bigWord) == 0 { leading = prevCharStart(leading) }
        if leading == lineStart, firstNonBlank(lineStart) == start { leading = start }
        return TextRange(start: leading, end: end, linewise: false)
    }

    /// `i"`, `a"` and friends, following Vim: on a quote, quotes pair up from the start of the
    /// line; elsewhere the nearest quotes around the cursor are used (so apostrophes earlier
    /// in the line do not get in the way). A backslash escapes a quote.
    ///
    /// Notes turns quotes into “curly” ones as you type, so `i"` also matches “…” and `i'`
    /// matches ‘…’, whichever pair is closest around the cursor.
    private func quoteObject(at position: Int, quote: Character, around: Bool) -> TextRange? {
        let lineStart = lineStart(position)
        let lineEnd = lineEnd(position)
        guard let quoteUnit = quote.utf16.first else { return nil }
        var candidates: [(open: Int, close: Int)] = []
        if let pair = straightQuotes(at: position, unit: quoteUnit, lineStart: lineStart, lineEnd: lineEnd) {
            candidates.append(pair)
        }
        let curly: (UInt16, UInt16)? = quote == "\"" ? (0x201C, 0x201D) : quote == "'" ? (0x2018, 0x2019) : nil
        if let (openUnit, closeUnit) = curly,
           let pair = curlyQuotes(at: position, open: openUnit, close: closeUnit, lineStart: lineStart, lineEnd: lineEnd) {
            candidates.append(pair)
        }
        let enclosing = candidates.filter { $0.open <= position && position <= $0.close }
        guard let (open, close) = enclosing.max(by: { $0.open < $1.open }) ?? candidates.min(by: { $0.open < $1.open }) else {
            return nil
        }
        if !around { return TextRange(start: open + 1, end: close, linewise: false) }
        var end = close + 1
        while end < lineEnd, isBlank(end) { end += 1 }
        var start = open
        if end == close + 1 {
            while start > lineStart, isBlank(start - 1) { start -= 1 }
        }
        return TextRange(start: start, end: end, linewise: false)
    }

    /// `i(`, `a{`, `ib`, `aB`, ... Works across lines.
    private func blockObject(at position: Int, open: Character, close: Character, around: Bool, forChange: Bool) -> TextRange? {
        guard let openUnit = open.utf16.first, let closeUnit = close.utf16.first else { return nil }
        let openPosition: Int
        if position < length, unit(position) == openUnit {
            openPosition = position
        } else {
            var depth = 0
            var index = position < length && unit(position) == closeUnit ? position - 1 : position
            var found: Int?
            while index >= 0 {
                if index < length {
                    let current = unit(index)
                    if current == closeUnit {
                        depth += 1
                    } else if current == openUnit {
                        if depth == 0 {
                            found = index
                            break
                        }
                        depth -= 1
                    }
                }
                index -= 1
            }
            guard let found else { return nil }
            openPosition = found
        }
        var depth = 0
        var index = openPosition + 1
        var closePosition: Int?
        while index < length {
            let current = unit(index)
            if current == openUnit {
                depth += 1
            } else if current == closeUnit {
                if depth == 0 {
                    closePosition = index
                    break
                }
                depth -= 1
            }
            index += 1
        }
        guard let closePosition else { return nil }
        if around { return TextRange(start: openPosition, end: closePosition + 1, linewise: false) }

        var start = openPosition + 1
        var end = closePosition
        // Like Vim, `i{` on a block whose braces sit on their own lines leaves those lines alone.
        if isNewline(start), start < end {
            start += 1
            let closeLineStart = lineStart(closePosition)
            if closeLineStart > start, (closeLineStart..<closePosition).allSatisfy({ isBlank($0) }) {
                end = forChange ? closeLineStart - 1 : closeLineStart
            }
        }
        return TextRange(start: start, end: max(start, end), linewise: false)
    }

    private func straightQuotes(at position: Int, unit quoteUnit: UInt16, lineStart: Int, lineEnd: Int) -> (open: Int, close: Int)? {
        var quotes: [Int] = []
        var index = lineStart
        while index < lineEnd {
            if unit(index) == 0x5C { // backslash
                index += 2
                continue
            }
            if unit(index) == quoteUnit { quotes.append(index) }
            index += 1
        }
        if let onQuote = quotes.firstIndex(of: position) {
            if onQuote % 2 == 0 {
                return onQuote + 1 < quotes.count ? (quotes[onQuote], quotes[onQuote + 1]) : nil
            }
            return (quotes[onQuote - 1], quotes[onQuote])
        }
        guard let after = quotes.firstIndex(where: { $0 > position }) else { return nil }
        if let before = quotes.last(where: { $0 < position }) { return (before, quotes[after]) }
        return after + 1 < quotes.count ? (quotes[after], quotes[after + 1]) : nil
    }

    private func curlyQuotes(at position: Int, open: UInt16, close: UInt16, lineStart: Int, lineEnd: Int) -> (open: Int, close: Int)? {
        let onClose = position < lineEnd && unit(position) == close
        let searchBack = onClose ? position - 1 : position
        var openPosition = (lineStart...max(lineStart, searchBack)).reversed().first { $0 < lineEnd && unit($0) == open }
        if openPosition == nil {
            openPosition = (position..<lineEnd).first { unit($0) == open }
        }
        guard let openPosition else { return nil }
        let from = max(openPosition + 1, onClose ? position : openPosition + 1)
        guard from <= lineEnd, let closePosition = (from..<lineEnd).first(where: { unit($0) == close }) else { return nil }
        return (openPosition, closePosition)
    }

    /// `ip`, `ap`. Linewise. Blank lines separate paragraphs.
    private func paragraphObject(at position: Int, around: Bool) -> TextRange? {
        let last = lineCount - 1
        func blank(_ line: Int) -> Bool { isLineBlank(lineStart(ofLine: line)) }
        let line = lineIndex(position)
        let white = blank(line)
        var first = line
        while first > 0, blank(first - 1) == white { first -= 1 }
        var final = line
        while final < last, blank(final + 1) == white { final += 1 }
        if around {
            if white {
                if final < last {
                    final += 1
                    while final < last, !blank(final + 1) { final += 1 }
                }
            } else {
                let trailing = final
                while final < last, blank(final + 1) { final += 1 }
                if final == trailing {
                    while first > 0, blank(first - 1) { first -= 1 }
                }
            }
        }
        return TextRange(start: lineStart(ofLine: first), end: lineEnd(lineStart(ofLine: final)), linewise: true)
    }
}
