import Foundation

/// A cursor that walks the buffer the way Vim's `inc()` / `dec()` do, including stopping
/// on the "end of line" position (the newline) between lines. Word motions below are
/// direct ports of Vim's `fwd_word`, `bck_word`, `end_word` and `bckend_word` so that
/// the many edge cases (empty lines, punctuation runs, operators at end of line) match.
struct WordCursor {
    let buffer: TextBuffer
    let bigWord: Bool
    var position: Int

    /// 0: moved within the line, 1: moved to the next line, 2: moved onto the end of line,
    /// -1: already at the end of the buffer.
    mutating func inc() -> Int {
        let end = buffer.lineEnd(position)
        if position < end {
            position = buffer.charEnd(position)
            return position < end ? 0 : 2
        }
        if position < buffer.length {
            position += 1
            return 1
        }
        return -1
    }

    /// 0: moved within the line, 1: moved to the end of the previous line, -1: at start of buffer.
    mutating func dec() -> Int {
        if position > buffer.lineStart(position) {
            position = buffer.prevCharStart(position)
            return 0
        }
        if position > 0 {
            position -= 1
            return 1
        }
        return -1
    }

    var cls: Int { buffer.wordClass(position, bigWord: bigWord) }

    var onEmptyLine: Bool { buffer.isLineEmpty(position) }

    /// Returns true when the start or end of the buffer was hit.
    mutating func skip(_ cls: Int, forward: Bool) -> Bool {
        while self.cls == cls {
            if (forward ? inc() : dec()) == -1 { return true }
        }
        return false
    }
}

extension TextBuffer {
    /// `w` / `W`. `stopAtLineEnd` is set for operators so that `dw` on the last word of a
    /// line does not eat the line break. `ok` is false when Vim would beep; `position` is
    /// still where the cursor got to, which operators use (`dw` on the last character).
    func wordForward(from start: Int, count: Int, bigWord: Bool, stopAtLineEnd: Bool) -> (position: Int, ok: Bool) {
        var cursor = WordCursor(buffer: self, bigWord: bigWord, position: start)
        var remaining = count
        while remaining > 0 {
            remaining -= 1
            let startClass = cursor.cls
            let lastLine = lineIndex(cursor.position) == lineCount - 1
            var step = cursor.inc()
            if step == -1 || (step >= 1 && lastLine) { return (cursor.position, false) }
            if step >= 1, stopAtLineEnd, remaining == 0 { return (cursor.position, true) }
            if startClass != 0 {
                while cursor.cls == startClass {
                    step = cursor.inc()
                    if step == -1 || (step >= 1 && stopAtLineEnd && remaining == 0) { return (cursor.position, true) }
                }
            }
            while cursor.cls == 0 {
                if cursor.position == lineStart(cursor.position), cursor.onEmptyLine { break }
                step = cursor.inc()
                if step == -1 || (step >= 1 && stopAtLineEnd && remaining == 0) { return (cursor.position, true) }
            }
        }
        return (cursor.position, true)
    }

    /// `b` / `B`.
    func wordBackward(from start: Int, count: Int, bigWord: Bool) -> (position: Int, ok: Bool) {
        var cursor = WordCursor(buffer: self, bigWord: bigWord, position: start)
        for _ in 0..<count {
            if cursor.dec() == -1 { return (cursor.position, false) }
            var finished = false
            while cursor.cls == 0 {
                if cursor.position == lineStart(cursor.position), cursor.onEmptyLine {
                    finished = true
                    break
                }
                if cursor.dec() == -1 { return (cursor.position, true) }
            }
            if finished { continue }
            if cursor.skip(cursor.cls, forward: false) { return (cursor.position, true) }
            _ = cursor.inc()
        }
        return (cursor.position, true)
    }

    /// `e` / `E`. With `stop` (used for `cw`) a cursor already at the end of a word stays there.
    func wordEnd(from start: Int, count: Int, bigWord: Bool, stop: Bool = false) -> (position: Int, ok: Bool) {
        var cursor = WordCursor(buffer: self, bigWord: bigWord, position: start)
        var stop = stop
        for _ in 0..<count {
            let startClass = cursor.cls
            if cursor.inc() == -1 { return (cursor.position, false) }
            if cursor.cls == startClass, startClass != 0 {
                if cursor.skip(startClass, forward: true) { return (cursor.position, false) }
            } else if !stop || startClass == 0 {
                while cursor.cls == 0 {
                    if cursor.inc() == -1 { return (cursor.position, false) }
                }
                if cursor.skip(cursor.cls, forward: true) { return (cursor.position, false) }
            }
            _ = cursor.dec()
            stop = false
        }
        return (cursor.position, true)
    }

    /// `ge` / `gE`.
    func wordEndBackward(from start: Int, count: Int, bigWord: Bool) -> (position: Int, ok: Bool) {
        var cursor = WordCursor(buffer: self, bigWord: bigWord, position: start)
        for _ in 0..<count {
            let startClass = cursor.cls
            if cursor.dec() == -1 { return (cursor.position, false) }
            if startClass != 0 {
                while cursor.cls == startClass {
                    if cursor.dec() == -1 { return (cursor.position, true) }
                }
            }
            while cursor.cls == 0 {
                if cursor.position == lineStart(cursor.position), cursor.onEmptyLine { break }
                if cursor.dec() == -1 { return (cursor.position, true) }
            }
        }
        return (cursor.position, true)
    }

    /// `{` / `}`: Vim's `findpar`. Returns the target and whether the motion became inclusive
    /// (it does when it stops at the end of the last line).
    func paragraph(from start: Int, count: Int, forward: Bool) -> (position: Int, inclusive: Bool)? {
        var line = lineIndex(start)
        let last = lineCount - 1
        var remaining = count
        while remaining > 0 {
            remaining -= 1
            var didSkip = false
            var first = true
            while true {
                let lineStart = lineStart(ofLine: line)
                if !isLineEmpty(lineStart) { didSkip = true }
                if !first, didSkip, isLineEmpty(lineStart) { break }
                let next = line + (forward ? 1 : -1)
                if next < 0 || next > last {
                    if remaining > 0 { return nil }
                    break
                }
                line = next
                first = false
            }
        }
        let target = lineStart(ofLine: line)
        if line == last, !isLineEmpty(target) {
            return (lastCharStart(target), true)
        }
        if target == start { return nil }
        return (target, false)
    }
}
