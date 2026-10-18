import Foundation

/// The Vim state machine.
///
/// The host feeds it key presses together with a `Snapshot` of the focused text element and
/// applies the returned `Response`: a list of text replacements, the selection to show (a
/// one-character selection is the Normal mode "block cursor") and actions such as undo that
/// must be delegated to the app. The engine never talks to the Accessibility API itself,
/// which keeps it fast to test.
public final class VimEngine {
    public private(set) var mode: Mode = .insert
    public var clipboard: Clipboard
    /// When true, plain `j` / `k` move by wrapped (visual) lines like `gj` / `gk`.
    public var verticalMovesUseScreenLines = false

    private var caret = 0
    private var anchor = 0
    /// Desired column for `j` / `k`, in characters. `Int.max` sticks to the end of line after `$`.
    private var desiredColumn: Int?
    /// Desired UTF-16 offset within a wrapped line for `gj` / `gk`.
    private var desiredScreenOffset: Int?
    private var pending: [Token] = []
    private var lastFind: (character: Character, forward: Bool, till: Bool)?
    private var lastChange: (command: ParsedCommand, inserted: String?)?
    private var insertSession: InsertSession?
    /// What the element looked like right after our last update. A mismatch on the next key
    /// means the user clicked, scrolled through search results, or switched notes.
    private var rendered: Snapshot?
    private var layout: ScreenLayout?

    private struct InsertSession {
        var kind: InsertKind?
        var count: Int
        var command: ParsedCommand?
        var startText: String
        var startPosition: Int
    }

    public init(clipboard: Clipboard = InMemoryClipboard()) {
        self.clipboard = clipboard
    }

    // MARK: Public API

    /// Handles one key press. In Insert mode only Escape is consumed, everything else is
    /// passed through without even looking at the snapshot.
    public func handle(_ key: VimKey, in snapshot: Snapshot, layout: ScreenLayout? = nil) -> Response {
        let token = Token(key)
        if mode == .insert {
            guard token == .escape else { return .pass }
            return finishInsert(snapshot)
        }

        self.layout = layout
        defer { self.layout = nil }
        let buffer = TextBuffer(snapshot.text)
        adopt(snapshot, buffer)

        if token == .escape, !pending.isEmpty {
            pending = []
            return .swallow
        }
        pending.append(token)
        switch Parser.parse(pending, visual: mode.isVisual) {
        case .incomplete:
            return .swallow
        case .invalid:
            pending = []
            return .swallow
        case let .complete(parsed):
            pending = []
            guard let transition = transition(for: parsed, in: buffer) else { return .swallow }
            // Changes that enter Insert mode are recorded when Insert mode ends, with the typed text.
            if isRepeatable(parsed.command), transition.mode != .insert {
                lastChange = (parsed, nil)
            }
            return commit(transition, buffer)
        }
    }

    /// Back to Insert mode, forgetting any pending keys. Used when focus moves elsewhere.
    public func reset() {
        mode = .insert
        pending = []
        insertSession = nil
        rendered = nil
    }

    /// The text and selection the element should show right now, outside Insert mode.
    public var expectedSnapshot: Snapshot? { mode == .insert ? nil : rendered }

    /// Call after applying a response with the element's real state. Notes may normalise
    /// inserted text slightly differently than predicted; this keeps the engine in sync.
    public func confirm(_ snapshot: Snapshot) {
        guard mode != .insert else { return }
        rendered = snapshot
    }

    /// Call when the selection or text changed outside the engine (mouse click, undo, find).
    /// Returns the selection that restores the block cursor, if it needs restoring.
    ///
    /// When the text itself changed and `textChangeResetsMode` is true (the user switched to
    /// another note, or pasted with ⌘V) the engine drops back to Insert mode, so that what
    /// is on screen (a thin caret) matches the mode.
    public func synchronize(with snapshot: Snapshot, textChangeResetsMode: Bool) -> NSRange? {
        guard mode != .insert else { return nil }
        if let rendered, rendered == snapshot { return nil }
        if textChangeResetsMode, let rendered, rendered.text != snapshot.text {
            reset()
            return nil
        }
        let buffer = TextBuffer(snapshot.text)
        adopt(snapshot, buffer)
        let selection = selection(in: buffer)
        rendered = Snapshot(text: snapshot.text, selection: selection)
        return selection == snapshot.selection ? nil : selection
    }

    // MARK: State sync

    private func adopt(_ snapshot: Snapshot, _ buffer: TextBuffer) {
        if let rendered, rendered == snapshot {
            caret = min(caret, buffer.length)
            return
        }
        let selection = snapshot.selection
        let location = min(max(selection.location, 0), buffer.length)
        if mode.isVisual, selection.length > 0, let rendered, rendered.text == snapshot.text {
            anchor = buffer.clampNormal(location)
            caret = buffer.clampNormal(buffer.prevCharStart(min(location + selection.length, buffer.length)))
        } else {
            if mode.isVisual { mode = .normal }
            caret = buffer.clampNormal(location)
        }
        desiredColumn = nil
        desiredScreenOffset = nil
        pending = []
    }

    // MARK: Transitions

    private struct Transition {
        var edits: [Edit] = []
        var caret: Int
        var mode: Mode
        var anchor: Int?
        var actions: [HostAction] = []
        var insert: InsertSession?
        /// Move one character left after the edits, like leaving Insert mode does.
        var stepBack = false
        /// Put the cursor on the first non-blank of its line after the edits.
        var toFirstNonBlank = false
        var keepDesiredColumn = false
        var keepDesiredScreenOffset = false
    }

    private func commit(_ transition: Transition, _ buffer: TextBuffer) -> Response {
        let edits = coalesce(transition.edits)
        let updated = edits.isEmpty ? buffer : buffer.applying(edits)
        mode = transition.mode
        var position = min(max(transition.caret, 0), updated.length)
        if transition.stepBack, position > updated.lineStart(position) {
            position = updated.prevCharStart(position)
        }
        if transition.toFirstNonBlank { position = updated.firstNonBlank(position) }
        caret = mode == .insert ? updated.charStart(position) : updated.clampNormal(position)
        if let newAnchor = transition.anchor { anchor = updated.clampNormal(newAnchor) }
        if !transition.keepDesiredColumn { desiredColumn = nil }
        if !transition.keepDesiredScreenOffset { desiredScreenOffset = nil }

        if mode == .insert {
            var session = transition.insert ?? InsertSession(kind: nil, count: 1, command: nil, startText: "", startPosition: 0)
            session.startText = updated.string
            session.startPosition = caret
            insertSession = session
            rendered = nil
            return Response(handled: true, edits: edits, selection: NSRange(location: caret, length: 0))
        }

        if !transition.actions.isEmpty {
            // The app performs these asynchronously; the host resynchronises afterwards.
            rendered = nil
            return Response(handled: true, edits: edits, selection: edits.isEmpty ? nil : selection(in: updated), actions: transition.actions)
        }
        let selection = selection(in: updated)
        rendered = Snapshot(text: updated.string, selection: selection)
        return Response(handled: true, edits: edits, selection: selection)
    }

    /// Merges an insertion that continues right where the previous edit ended into that edit,
    /// so that e.g. `cw` + repeated text is a single replacement (and a single undo step).
    private func coalesce(_ edits: [Edit]) -> [Edit] {
        var result: [Edit] = []
        for edit in edits {
            if var last = result.last, edit.range.length == 0,
               edit.range.location == last.range.location + last.text.utf16.count {
                last.text += edit.text
                result[result.count - 1] = last
            } else if edit.range.length > 0 || !edit.text.isEmpty {
                result.append(edit)
            }
        }
        return result
    }

    private func selection(in buffer: TextBuffer) -> NSRange {
        switch mode {
        case .insert:
            return NSRange(location: caret, length: 0)
        case .normal:
            guard caret < buffer.lineEnd(caret) else { return NSRange(location: caret, length: 0) }
            return NSRange(location: caret, length: buffer.charEnd(caret) - caret)
        case .visual:
            let low = min(anchor, caret)
            let high = max(anchor, caret)
            let end = high < buffer.length ? buffer.charEnd(high) : high
            return NSRange(location: low, length: end - low)
        case .visualLine:
            let low = buffer.lineStart(min(anchor, caret))
            let high = buffer.lineEnd(max(anchor, caret))
            let end = high < buffer.length ? high + 1 : high
            return NSRange(location: low, length: end - low)
        }
    }

    private func transition(for parsed: ParsedCommand, in buffer: TextBuffer) -> Transition? {
        let count = parsed.count
        let n = count ?? 1

        switch parsed.command {
        case .escape:
            return Transition(caret: caret, mode: .normal)

        case let .move(motion):
            guard let result = evaluate(motion, count: count, from: caret, buffer, forOperator: false) else { return nil }
            var transition = Transition(caret: result.position, mode: mode)
            if motion.isVertical {
                transition.keepDesiredColumn = true
                transition.keepDesiredScreenOffset = true
            }
            if motion == .lineEnd {
                transition.keepDesiredColumn = true
                desiredColumn = Int.max
            }
            return transition

        case let .operate(op, target):
            return operate(op, target, count: count, buffer, parsed: parsed)

        case .deleteChar:
            guard caret < buffer.lineEnd(caret) else { return nil }
            return operate(.delete, .motion(.right), count: count, buffer, parsed: parsed)
        case .deleteCharBefore:
            return operate(.delete, .motion(.left), count: count, buffer, parsed: parsed)
        case .substitute:
            if buffer.isLineEmpty(caret) {
                return Transition(caret: caret, mode: .insert, insert: session(nil, 1, parsed))
            }
            return operate(.change, .motion(.right), count: count, buffer, parsed: parsed)
        case .substituteLine:
            return operate(.change, .line, count: count, buffer, parsed: parsed)
        case .deleteToEnd:
            return operate(.delete, .motion(.lineEnd), count: count, buffer, parsed: parsed)
        case .changeToEnd:
            return operate(.change, .motion(.lineEnd), count: count, buffer, parsed: parsed)
        case .yankLine:
            return operate(.yank, .line, count: count, buffer, parsed: parsed)

        case let .replace(character):
            let end = buffer.lineEnd(caret)
            var position = caret
            var replaced = 0
            while replaced < n, position < end {
                position = buffer.charEnd(position)
                replaced += 1
            }
            guard replaced == n else { return nil }
            if character == "\n" {
                return Transition(edits: [Edit(caret, position, "\n")], caret: caret + 1, mode: .normal)
            }
            let text = String(repeating: String(character), count: n)
            let last = caret + String(repeating: String(character), count: n - 1).utf16.count
            return Transition(edits: [Edit(caret, position, text)], caret: last, mode: .normal)

        case .toggleCase:
            let end = buffer.lineEnd(caret)
            var position = caret
            var toggled = 0
            while toggled < n, position < end {
                position = buffer.charEnd(position)
                toggled += 1
            }
            guard position > caret else { return nil }
            let text = Self.toggledCase(buffer.substring(caret, position))
            return Transition(edits: [Edit(caret, position, text)], caret: caret + text.utf16.count, mode: .normal)

        case .join:
            return join(lines: max(2, n), from: caret, buffer)

        case let .put(before):
            return put(before: before, count: n, buffer)

        case let .insert(kind):
            var transition: Transition
            switch kind {
            case .before:
                transition = Transition(caret: caret, mode: .insert)
            case .after:
                transition = Transition(caret: caret < buffer.lineEnd(caret) ? buffer.charEnd(caret) : caret, mode: .insert)
            case .firstNonBlank:
                transition = Transition(caret: buffer.firstNonBlank(caret), mode: .insert)
            case .lineStart:
                transition = Transition(caret: buffer.lineStart(caret), mode: .insert)
            case .lineEnd:
                transition = Transition(caret: buffer.lineEnd(caret), mode: .insert)
            case .openBelow:
                let end = buffer.lineEnd(caret)
                transition = Transition(edits: [Edit(end, end, "\n")], caret: end + 1, mode: .insert)
            case .openAbove:
                let start = buffer.lineStart(caret)
                transition = Transition(edits: [Edit(start, start, "\n")], caret: start, mode: .insert)
            }
            transition.insert = session(kind, n, parsed)
            return transition

        case .undo:
            return Transition(caret: caret, mode: .normal, actions: Array(repeating: .undo, count: n))
        case .redo:
            return Transition(caret: caret, mode: .normal, actions: Array(repeating: .redo, count: n))
        case .indent:
            return Transition(caret: caret, mode: .normal, actions: Array(repeating: .indent, count: n))
        case .outdent:
            return Transition(caret: caret, mode: .normal, actions: Array(repeating: .outdent, count: n))
        case .search:
            return Transition(caret: caret, mode: .normal, actions: [.find])
        case .searchNext:
            return Transition(caret: caret, mode: .normal, actions: Array(repeating: .findNext, count: n))
        case .searchPrevious:
            return Transition(caret: caret, mode: .normal, actions: Array(repeating: .findPrevious, count: n))

        case .repeatLast:
            return repeatLastChange(count: count, buffer)

        case let .visual(linewise):
            let target: Mode = linewise ? .visualLine : .visual
            if mode == target { return Transition(caret: caret, mode: .normal) }
            return Transition(caret: caret, mode: target, anchor: mode.isVisual ? anchor : caret)

        case .swapVisualEnds:
            return Transition(caret: anchor, mode: mode, anchor: caret)

        case let .selectTextObject(object):
            guard let range = buffer.textObject(object, at: caret, forChange: false), range.end > range.start || range.linewise else { return nil }
            if range.linewise {
                return Transition(caret: buffer.lineStart(range.end), mode: .visualLine, anchor: range.start)
            }
            return Transition(caret: buffer.prevCharStart(range.end), mode: .visual, anchor: range.start)

        case let .visualOperation(operation):
            return visualOperation(operation, buffer)
        }
    }

    private func session(_ kind: InsertKind?, _ count: Int, _ parsed: ParsedCommand) -> InsertSession {
        InsertSession(kind: kind, count: count, command: parsed, startText: "", startPosition: 0)
    }

    private func isRepeatable(_ command: Command) -> Bool {
        switch command {
        case .operate(.yank, _), .move, .undo, .redo, .repeatLast, .visual, .search, .searchNext, .searchPrevious,
             .escape, .swapVisualEnds, .selectTextObject, .visualOperation, .yankLine:
            return false
        default:
            return true
        }
    }

    // MARK: Motions

    private struct MotionResult {
        enum Kind { case exclusive, inclusive, linewise }
        var position: Int
        var kind: Kind
    }

    private func evaluate(_ motion: Motion, count: Int?, from position: Int, _ buffer: TextBuffer, forOperator: Bool) -> MotionResult? {
        let n = count ?? 1
        let line = buffer.lineIndex(position)

        func linewise(toLine target: Int) -> MotionResult {
            MotionResult(position: buffer.firstNonBlank(buffer.lineStart(ofLine: target)), kind: .linewise)
        }

        switch motion {
        case .left:
            let start = buffer.lineStart(position)
            guard position > start else { return nil }
            var target = position
            for _ in 0..<n where target > start { target = buffer.prevCharStart(target) }
            return MotionResult(position: target, kind: .exclusive)

        case .right:
            let limit = forOperator ? buffer.lineEnd(position) : buffer.lastCharStart(position)
            guard position < limit else { return nil }
            var target = position
            for _ in 0..<n where target < limit { target = buffer.charEnd(target) }
            return MotionResult(position: min(target, limit), kind: .exclusive)

        case .down, .up:
            if !forOperator, verticalMovesUseScreenLines, mode != .visualLine, layout != nil {
                return evaluate(motion == .down ? .screenDown : .screenUp, count: count, from: position, buffer, forOperator: false)
            }
            let target = motion == .down ? min(line + n, buffer.lineCount - 1) : max(line - n, 0)
            guard target != line else { return nil }
            let column = desiredColumn ?? buffer.column(position)
            desiredColumn = column
            return MotionResult(position: buffer.position(line: target, column: column), kind: .linewise)

        case .screenDown, .screenUp:
            let delta = motion == .screenDown ? n : -n
            if let target = screenVertical(from: position, delta: delta, buffer) {
                return MotionResult(position: target, kind: .exclusive)
            }
            guard layout == nil else { return nil }
            return evaluate(motion == .screenDown ? .down : .up, count: count, from: position, buffer, forOperator: forOperator)

        case let .wordForward(big):
            let result = buffer.wordForward(from: position, count: n, bigWord: big, stopAtLineEnd: forOperator)
            guard result.ok || (forOperator && result.position > position) else { return nil }
            return MotionResult(position: result.position, kind: .exclusive)

        case let .wordBackward(big):
            let result = buffer.wordBackward(from: position, count: n, bigWord: big)
            guard result.ok || forOperator else { return nil }
            return MotionResult(position: result.position, kind: .exclusive)

        case let .wordEnd(big):
            let result = buffer.wordEnd(from: position, count: n, bigWord: big)
            guard result.ok || (forOperator && result.position > position) else { return nil }
            return MotionResult(position: buffer.clampNormal(result.position), kind: .inclusive)

        case let .wordEndBackward(big):
            let result = buffer.wordEndBackward(from: position, count: n, bigWord: big)
            guard result.ok else { return nil }
            return MotionResult(position: result.position, kind: .inclusive)

        case .lineStart:
            return MotionResult(position: buffer.lineStart(position), kind: .exclusive)

        case .firstNonBlank:
            return MotionResult(position: buffer.firstNonBlank(position), kind: .exclusive)

        case .lineEnd:
            let target = min(line + n - 1, buffer.lineCount - 1)
            return MotionResult(position: buffer.lastCharStart(buffer.lineStart(ofLine: target)), kind: .inclusive)

        case .firstNonBlankOfLine:
            return linewise(toLine: min(line + n - 1, buffer.lineCount - 1))

        case .nextLineFirstNonBlank:
            guard line < buffer.lineCount - 1 else { return nil }
            return linewise(toLine: min(line + n, buffer.lineCount - 1))

        case .previousLineFirstNonBlank:
            guard line > 0 else { return nil }
            return linewise(toLine: max(line - n, 0))

        case .firstLine:
            return linewise(toLine: min(max((count ?? 1) - 1, 0), buffer.lineCount - 1))

        case .lastLine:
            return linewise(toLine: min(max((count ?? buffer.lineCount) - 1, 0), buffer.lineCount - 1))

        case .paragraphForward, .paragraphBackward:
            guard let result = buffer.paragraph(from: position, count: n, forward: motion == .paragraphForward) else { return nil }
            return MotionResult(position: result.position, kind: result.inclusive ? .inclusive : .exclusive)

        case let .find(character, forward, till):
            lastFind = (character, forward, till)
            return find(character, forward: forward, till: till, count: n, from: position, buffer, isRepeat: false)

        case let .repeatFind(reverse):
            guard let lastFind else { return nil }
            let forward = reverse ? !lastFind.forward : lastFind.forward
            return find(lastFind.character, forward: forward, till: lastFind.till, count: n, from: position, buffer, isRepeat: true)

        case .matchPair:
            return matchPair(from: position, buffer)

        case .halfPageDown, .halfPageUp, .pageDown, .pageUp:
            guard let layout, let visible = layout.visibleRange(),
                  let first = layout.lineNumber(at: visible.location),
                  let last = layout.lineNumber(at: max(visible.location, visible.location + visible.length - 1)) else {
                return nil
            }
            let height = max(1, last - first + 1)
            let amount = (motion == .halfPageDown || motion == .halfPageUp) ? max(1, height / 2) : max(1, height - 2)
            let down = motion == .halfPageDown || motion == .pageDown
            guard let target = screenVertical(from: position, delta: down ? amount : -amount, buffer) else { return nil }
            return MotionResult(position: target, kind: .linewise)

        case .screenTop, .screenMiddle, .screenBottom:
            guard let layout, let visible = layout.visibleRange(),
                  let first = layout.lineNumber(at: visible.location),
                  let last = layout.lineNumber(at: max(visible.location, visible.location + visible.length - 1)) else {
                return nil
            }
            let target: Int
            switch motion {
            case .screenTop: target = min(first + n - 1, last)
            case .screenBottom: target = max(last - n + 1, first)
            default: target = (first + last) / 2
            }
            guard let range = layout.range(ofLine: target) else { return nil }
            let start = min(range.location, buffer.length)
            let lineStart = buffer.lineStart(start)
            let position = start == lineStart ? buffer.firstNonBlank(start) : start
            return MotionResult(position: position, kind: .linewise)
        }
    }

    /// Moves `delta` wrapped lines keeping the horizontal offset, using the app's layout.
    private func screenVertical(from position: Int, delta: Int, _ buffer: TextBuffer) -> Int? {
        guard let layout, let current = layout.lineNumber(at: position), let currentRange = layout.range(ofLine: current) else {
            return nil
        }
        var target = max(current + delta, 0)
        var targetRange = layout.range(ofLine: target)
        while targetRange == nil, target != current {
            target += delta > 0 ? -1 : 1
            targetRange = layout.range(ofLine: target)
        }
        guard let targetRange, target != current else { return nil }
        let offset = desiredScreenOffset ?? max(0, position - currentRange.location)
        desiredScreenOffset = offset
        let start = min(targetRange.location, buffer.length)
        var end = min(targetRange.location + targetRange.length, buffer.length)
        if end > start, buffer.isNewline(end - 1) { end -= 1 }
        var result = start + offset
        if result >= end { result = end > start ? buffer.prevCharStart(end) : start }
        return buffer.charStart(result)
    }

    private func find(_ character: Character, forward: Bool, till: Bool, count: Int, from position: Int, _ buffer: TextBuffer, isRepeat: Bool) -> MotionResult? {
        let start = buffer.lineStart(position)
        let end = buffer.lineEnd(position)
        var index = position
        var found = 0
        // `;` after `t` must not get stuck right in front of the same character.
        if isRepeat, till {
            if forward {
                let next = buffer.charEnd(index)
                if next < end, buffer.character(at: next) == character { index = next }
            } else if index > start {
                let previous = buffer.prevCharStart(index)
                if previous > start, buffer.character(at: buffer.prevCharStart(previous)) == character { index = previous }
            }
        }
        while found < count {
            if forward {
                index = buffer.charEnd(index)
                guard index < end else { return nil }
            } else {
                guard index > start else { return nil }
                index = buffer.prevCharStart(index)
            }
            if buffer.character(at: index) == character { found += 1 }
        }
        if till { index = forward ? buffer.prevCharStart(index) : buffer.charEnd(index) }
        return MotionResult(position: index, kind: forward ? .inclusive : .exclusive)
    }

    private func matchPair(from position: Int, _ buffer: TextBuffer) -> MotionResult? {
        let pairs: [UInt16: (UInt16, Bool)] = [
            0x28: (0x29, true), 0x5B: (0x5D, true), 0x7B: (0x7D, true),
            0x29: (0x28, false), 0x5D: (0x5B, false), 0x7D: (0x7B, false),
        ]
        let end = buffer.lineEnd(position)
        var index = position
        while index < end, pairs[buffer.unit(index)] == nil { index += 1 }
        guard index < end, let (match, forward) = pairs[buffer.unit(index)] else { return nil }
        let own = buffer.unit(index)
        var depth = 0
        var cursor = index
        while true {
            cursor += forward ? 1 : -1
            guard cursor >= 0, cursor < buffer.length else { return nil }
            let unit = buffer.unit(cursor)
            if unit == own {
                depth += 1
            } else if unit == match {
                if depth == 0 { return MotionResult(position: cursor, kind: .inclusive) }
                depth -= 1
            }
        }
    }

    // MARK: Operators

    private func operate(_ op: Operator, _ target: OperatorTarget, count: Int?, _ buffer: TextBuffer, parsed: ParsedCommand) -> Transition? {
        var range: TextRange
        var motionTarget: Int?

        switch target {
        case .line:
            let first = buffer.lineIndex(caret)
            let last = min(first + (count ?? 1) - 1, buffer.lineCount - 1)
            range = TextRange(start: buffer.lineStart(ofLine: first), end: buffer.lineEnd(buffer.lineStart(ofLine: last)), linewise: true)

        case let .motion(motion):
            var result: MotionResult?
            // `cw` on a word behaves like `ce` (but stays put when already on the last character).
            if op == .change, case let .wordForward(big) = motion, caret < buffer.lineEnd(caret), !buffer.isBlank(caret) {
                let end = buffer.wordEnd(from: caret, count: count ?? 1, bigWord: big, stop: true)
                result = MotionResult(position: buffer.clampNormal(end.position), kind: .inclusive)
            } else {
                result = evaluate(motion, count: count, from: caret, buffer, forOperator: true)
            }
            guard let result else { return nil }
            motionTarget = result.position
            let low = min(caret, result.position)
            let high = max(caret, result.position)
            switch result.kind {
            case .linewise:
                range = TextRange(start: buffer.lineStart(low), end: buffer.lineEnd(high), linewise: true)
            case .inclusive:
                range = TextRange(start: low, end: high < buffer.lineEnd(high) ? buffer.charEnd(high) : high, linewise: false)
            case .exclusive:
                range = TextRange(start: low, end: high, linewise: false)
                // `:help o_v` rules: an exclusive motion ending at the start of a line ends at the
                // end of the previous line instead, and becomes linewise when it started in the indent.
                if high > low, high == buffer.lineStart(high), buffer.lineIndex(high) > buffer.lineIndex(low) {
                    if buffer.firstNonBlank(low) >= low {
                        range = TextRange(start: buffer.lineStart(low), end: high - 1, linewise: true)
                    } else {
                        range.end = high - 1
                    }
                }
            }

        case let .textObject(object):
            guard let objectRange = buffer.textObject(object, at: caret, forChange: op == .change) else { return nil }
            range = objectRange
        }

        let text = buffer.substring(range.start, range.end)
        if range.linewise {
            clipboard.write(Register(text: text + "\n", linewise: true))
        } else if !text.isEmpty {
            clipboard.write(Register(text: text, linewise: false))
        }

        switch op {
        case .yank:
            var position = range.start
            if range.linewise {
                let targetLine = motionTarget.map { buffer.lineIndex($0) }
                if let motionTarget, let targetLine, targetLine < buffer.lineIndex(caret) {
                    position = motionTarget
                } else if case .textObject = target {
                    position = range.start
                } else {
                    position = caret
                }
            }
            return Transition(caret: position, mode: .normal)

        case .delete:
            if range.linewise {
                let (start, end) = linewiseDeletion(range, buffer)
                return Transition(edits: [Edit(start, end, "")], caret: start, mode: .normal, toFirstNonBlank: true)
            }
            return Transition(edits: [Edit(range.start, range.end, "")], caret: range.start, mode: .normal)

        case .change:
            // Linewise ranges end before the last line break, so `cc` keeps an empty line to type on.
            return Transition(edits: [Edit(range.start, range.end, "")], caret: range.start, mode: .insert, insert: session(nil, 1, parsed))
        }
    }

    /// The range to remove for a linewise delete: the lines plus one line break.
    private func linewiseDeletion(_ range: TextRange, _ buffer: TextBuffer) -> (Int, Int) {
        if range.end < buffer.length { return (range.start, range.end + 1) }
        if range.start > 0 { return (range.start - 1, range.end) }
        return (0, buffer.length)
    }

    private func join(lines: Int, from position: Int, _ buffer: TextBuffer) -> Transition? {
        let first = buffer.lineIndex(position)
        let joins = min(lines - 1, buffer.lineCount - 1 - first)
        guard joins > 0 else { return nil }
        var edits: [Edit] = []
        var shift = 0
        var cursor = position
        for offset in 0..<joins {
            let start = buffer.lineStart(ofLine: first + offset)
            let end = buffer.lineEnd(start)
            let nextStart = end + 1
            let nextContent = buffer.firstNonBlank(nextStart)
            let nextIsBlank = nextContent == buffer.lineEnd(nextStart)
            let lastUnit: UInt16? = end > start ? buffer.unit(end - 1) : nil
            let addSpace = !nextIsBlank && buffer.unit(nextContent) != 0x29 && (end > start || offset > 0)
                && lastUnit != 0x20 && lastUnit != 0x09
            let replacement = addSpace ? " " : ""
            edits.append(Edit(end, nextContent, replacement))
            cursor = end + shift
            shift += replacement.utf16.count - (nextContent - end)
        }
        // Apply bottom-up so that every edit's offsets are still valid when it runs.
        return Transition(edits: edits.reversed(), caret: cursor, mode: .normal)
    }

    private func put(before: Bool, count: Int, _ buffer: TextBuffer) -> Transition? {
        guard let register = clipboard.read(), !register.text.isEmpty else { return nil }
        if register.linewise {
            var lines = register.text
            if !lines.hasSuffix("\n") { lines += "\n" }
            let block = String(repeating: lines, count: count)
            if before {
                let at = buffer.lineStart(caret)
                return Transition(edits: [Edit(at, at, block)], caret: at, mode: .normal, toFirstNonBlank: true)
            }
            let end = buffer.lineEnd(caret)
            if end < buffer.length {
                return Transition(edits: [Edit(end + 1, end + 1, block)], caret: end + 1, mode: .normal, toFirstNonBlank: true)
            }
            return Transition(edits: [Edit(end, end, "\n" + block.dropLast())], caret: end + 1, mode: .normal, toFirstNonBlank: true)
        }
        let block = String(repeating: register.text, count: count)
        let at = before || caret >= buffer.lineEnd(caret) ? caret : buffer.charEnd(caret)
        if block.contains("\n") {
            return Transition(edits: [Edit(at, at, block)], caret: at, mode: .normal)
        }
        return Transition(edits: [Edit(at, at, block)], caret: at + block.utf16.count, mode: .normal, stepBack: true)
    }

    // MARK: Visual mode

    private func visualOperation(_ operation: VisualOperation, _ buffer: TextBuffer) -> Transition? {
        let low = min(anchor, caret)
        let high = max(anchor, caret)
        let lines = TextRange(start: buffer.lineStart(low), end: buffer.lineEnd(high), linewise: true)
        let characters = TextRange(start: low, end: high < buffer.length ? buffer.charEnd(high) : high, linewise: false)
        let selected = mode == .visualLine ? lines : characters

        func remove(_ range: TextRange, change: Bool) -> Transition {
            let text = buffer.substring(range.start, range.end)
            clipboard.write(Register(text: range.linewise ? text + "\n" : text, linewise: range.linewise))
            if change {
                return Transition(edits: [Edit(range.start, range.end, "")], caret: range.start, mode: .insert)
            }
            if range.linewise {
                let (start, end) = linewiseDeletion(range, buffer)
                return Transition(edits: [Edit(start, end, "")], caret: start, mode: .normal, toFirstNonBlank: true)
            }
            return Transition(edits: [Edit(range.start, range.end, "")], caret: range.start, mode: .normal)
        }

        func transform(_ change: (String) -> String) -> Transition {
            let text = buffer.substring(selected.start, selected.end)
            return Transition(edits: [Edit(selected.start, selected.end, change(text))], caret: selected.start, mode: .normal)
        }

        switch operation {
        case .delete: return remove(selected, change: false)
        case .deleteLines: return remove(lines, change: false)
        case .change: return remove(selected, change: true)
        case .changeLines: return remove(lines, change: true)
        case .yank, .yankLines:
            let range = operation == .yankLines ? lines : selected
            let text = buffer.substring(range.start, range.end)
            clipboard.write(Register(text: range.linewise ? text + "\n" : text, linewise: range.linewise))
            return Transition(caret: range.linewise ? low : range.start, mode: .normal)
        case .toggleCase: return transform(Self.toggledCase)
        case .lowercase: return transform { $0.lowercased() }
        case .uppercase: return transform { $0.uppercased() }
        case let .replace(character):
            return transform { text in
                String(text.map { $0 == "\n" ? $0 : character })
            }
        case .join:
            let lineCount = buffer.lineIndex(high) - buffer.lineIndex(low) + 1
            return join(lines: max(2, lineCount), from: low, buffer)
        case .put:
            guard let register = clipboard.read() else { return nil }
            var text = register.text
            if register.linewise, mode == .visualLine {
                if text.hasSuffix("\n") { text.removeLast() }
            } else if register.linewise {
                text = "\n" + text
            }
            let caretPosition = register.linewise || text.contains("\n") ? selected.start : selected.start + text.utf16.count
            return Transition(edits: [Edit(selected.start, selected.end, text)], caret: caretPosition, mode: .normal,
                              stepBack: !(register.linewise || text.contains("\n")))
        case .indent:
            return Transition(caret: low, mode: .normal, actions: [.indent])
        case .outdent:
            return Transition(caret: low, mode: .normal, actions: [.outdent])
        }
    }

    // MARK: Insert mode and repeat

    private func finishInsert(_ snapshot: Snapshot) -> Response {
        let buffer = TextBuffer(snapshot.text)
        var position = min(max(snapshot.selection.location, 0), buffer.length)
        var edits: [Edit] = []
        if let session = insertSession {
            let inserted = Self.insertedText(from: session.startText, to: snapshot.text, at: session.startPosition)
            if let inserted, !inserted.isEmpty, session.count > 1,
               position == session.startPosition + inserted.utf16.count {
                let unit = session.kind?.opensLine == true ? "\n" + inserted : inserted
                let extra = String(repeating: unit, count: session.count - 1)
                edits.append(Edit(position, position, extra))
                position += extra.utf16.count
            }
            if let command = session.command { lastChange = (command, inserted) }
        }
        insertSession = nil
        return commit(Transition(edits: edits, caret: position, mode: .normal, stepBack: true), buffer)
    }

    private func repeatLastChange(count: Int?, _ buffer: TextBuffer) -> Transition? {
        guard var last = lastChange else { return nil }
        if let count { last.command.count = count }
        lastChange = last
        guard var transition = transition(for: last.command, in: buffer) else { return nil }
        if transition.mode == .insert {
            let text = last.inserted ?? ""
            let repeats = transition.insert?.kind != nil ? (transition.insert?.count ?? 1) : 1
            let unit = transition.insert?.kind?.opensLine == true ? "\n" + text : text
            let insertion = text + String(repeating: unit, count: max(0, repeats - 1))
            transition.edits.append(Edit(transition.caret, transition.caret, insertion))
            transition.caret += insertion.utf16.count
            transition.mode = .normal
            transition.insert = nil
            transition.stepBack = true
            transition.toFirstNonBlank = false
        }
        return transition
    }

    /// The text typed during an Insert session, if it was a plain insertion at the start point.
    static func insertedText(from old: String, to new: String, at start: Int) -> String? {
        let oldUnits = Array(old.utf16)
        let newUnits = Array(new.utf16)
        let delta = newUnits.count - oldUnits.count
        guard delta >= 0, start <= oldUnits.count else { return nil }
        guard oldUnits[..<start] == newUnits[..<start],
              oldUnits[start...] == newUnits[(start + delta)...] else { return nil }
        return String(utf16CodeUnits: Array(newUnits[start..<(start + delta)]), count: delta)
    }

    static func toggledCase(_ text: String) -> String {
        String(text.flatMap { character -> String in
            if character.isUppercase { return character.lowercased() }
            if character.isLowercase { return character.uppercased() }
            return String(character)
        })
    }
}
