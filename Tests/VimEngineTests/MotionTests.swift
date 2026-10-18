import Foundation
import Testing
@testable import VimEngine

@Suite struct MotionTests {
    @Test func escapeEntersNormalModeAndStepsBack() {
        let h = Harness("hello|")
        #expect(h.mode == .normal)
        h.keys("i").keys("<Esc>")
        #expect(h.marked == "hel|lo")
    }

    @Test func blockCursorIsAOneCharacterSelection() {
        let h = Harness("a|bc")
        #expect(h.selection == NSRange(location: 1, length: 1))
    }

    @Test func blockCursorCoversWholeEmoji() {
        let h = Harness("a|👍🏽b")
        #expect(h.selection == NSRange(location: 1, length: 4))
        h.keys("l")
        #expect(h.marked == "a👍🏽|b")
        h.keys("h")
        #expect(h.marked == "a|👍🏽b")
    }

    @Test func emptyLineHasNoSelection() {
        let h = Harness("a\n|\nb")
        #expect(h.selection == NSRange(location: 2, length: 0))
    }

    @Test(arguments: [
        ("|hello world", "l", "h|ello world"),
        ("hello worl|d", "l", "hello worl|d"),
        ("hel|lo", "h", "he|llo"),
        ("|hello world", "3l", "hel|lo world"),
        ("hello |world", "0", "|hello world"),
        ("   hel|lo", "^", "   |hello"),
        ("|hello world", "$", "hello worl|d"),
        ("|one two three", "w", "one |two three"),
        ("|one two three", "2w", "one two |three"),
        ("|foo.bar baz", "w", "foo|.bar baz"),
        ("|foo.bar baz", "W", "foo.bar |baz"),
        ("one two thre|e", "w", "one two thre|e"),
        ("one two   |  ", "w", "one two    | "),
        ("one\n|two", "b", "|one\ntwo"),
        ("one two thr|ee", "b", "one two |three"),
        ("foo.bar |baz", "B", "|foo.bar baz"),
        ("|one two", "e", "on|e two"),
        ("on|e two", "e", "one tw|o"),
        ("one tw|o", "ge", "on|e two"),
        ("one\n\n|two", "b", "one\n|\ntwo"),
        ("|one\n\ntwo", "w", "one\n|\ntwo"),
        ("a (b [c] d) |e", "F(", "a |(b [c] d) e"),
        ("|a (b [c] d) e", "f[", "a (b |[c] d) e"),
        ("|a (b [c] d) e", "t]", "a (b [|c] d) e"),
        ("a (b [c] d) |e", "T(", "a (|b [c] d) e"),
        ("|a-b-c-d", "2f-", "a-b|-c-d"),
        ("|a-b-c-d", "f-;", "a-b|-c-d"),
        ("|a-b-c-d", "f-;,", "a|-b-c-d"),
        ("|a-b-c-d", "t-;", "a-|b-c-d"),
        ("|(a [b] c)", "%", "(a [b] c|)"),
        ("(a [b] c|)", "%", "|(a [b] c)"),
        ("x |= (1, 2)", "%", "x = (1, 2|)"),
    ])
    func horizontal(start: String, keys: String, expected: String) {
        #expect(Harness(start).keys(keys).marked == expected)
    }

    @Test(arguments: [
        ("ab|cdef\nxy\nabcdef", "j", "abcdef\nx|y\nabcdef"),
        ("ab|cdef\nxy\nabcdef", "jj", "abcdef\nxy\nab|cdef"),
        ("abcdef\nxy\nab|cdef", "2k", "ab|cdef\nxy\nabcdef"),
        ("abc|def\nxy\nabcdef", "$jj", "abcdef\nxy\nabcde|f"),
        ("|one\ntwo", "k", "|one\ntwo"),
        ("one\n|two\nthree", "G", "one\ntwo\n|three"),
        ("one\ntwo\n|three", "gg", "|one\ntwo\nthree"),
        ("one\ntwo\n|three", "2G", "one\n|two\nthree"),
        ("|one\n  two", "+", "one\n  |two"),
        ("|one\n  two", "<CR>", "one\n  |two"),
        ("  one\n|two", "-", "  |one\ntwo"),
        ("|a\nb\n\nc\nd\n\ne", "}", "a\nb\n|\nc\nd\n\ne"),
        ("|a\nb\n\nc\nd\n\ne", "2}", "a\nb\n\nc\nd\n|\ne"),
        ("|a\nb\n\nc\nd", "2}", "a\nb\n\nc\n|d"),
        ("|a\nb\n\nc\nd", "3}", "|a\nb\n\nc\nd"),
        ("a\nb\n\nc\n|d", "{", "a\nb\n|\nc\nd"),
    ])
    func vertical(start: String, keys: String, expected: String) {
        #expect(Harness(start).keys(keys).marked == expected)
    }

    @Test func screenLineMotionsUseTheLayout() {
        // "aaaa bbbb cccc" wraps at 5 characters: "aaaa " "bbbb " "cccc"
        let h = Harness("a|aaa bbbb cccc")
        h.layout = WrappedLayout(h.text, width: 5)
        h.keys("gj")
        #expect(h.marked == "aaaa b|bbb cccc")
        h.keys("gj")
        #expect(h.marked == "aaaa bbbb c|ccc")
        h.keys("gk")
        #expect(h.marked == "aaaa b|bbb cccc")
    }

    @Test func plainJMovesByScreenLinesWhenEnabled() {
        let h = Harness("a|aaa bbbb cccc\nxy")
        h.engine.verticalMovesUseScreenLines = true
        h.layout = WrappedLayout(h.text, width: 5)
        h.keys("j")
        #expect(h.marked == "aaaa b|bbb cccc\nxy")
        // Operators stay logical: dj deletes both real lines.
        h.keys("dj")
        #expect(h.text == "")
    }

    @Test func screenLineMotionKeepsOffsetAcrossShortLines() {
        let h = Harness("abc|defgh\nab\nabcdefgh")
        h.layout = WrappedLayout(h.text, width: 20)
        h.keys("gjgj")
        #expect(h.marked == "abcdefgh\nab\nabc|defgh")
    }

    @Test func halfPageDownMovesHalfTheVisibleLines() {
        let text = (0..<20).map { "line \($0)" }.joined(separator: "\n")
        let h = Harness("|" + text)
        h.layout = WrappedLayout(text, width: 80, visible: NSRange(location: 0, length: (text as NSString).range(of: "line 9").location))
        h.keys("<C-d>")
        #expect(h.marked.hasPrefix(text.components(separatedBy: "line 4")[0] + "|"))
    }

    @Test func screenTopAndBottom() {
        let text = (0..<10).map { "line \($0)" }.joined(separator: "\n")
        let h = Harness("line 0\nline 1\n|line 2\n" + text.components(separatedBy: "line 2\n")[1])
        let visibleStart = (h.text as NSString).range(of: "line 1").location
        let visibleEnd = (h.text as NSString).range(of: "line 5").location + 6
        h.layout = WrappedLayout(h.text, width: 80, visible: NSRange(location: visibleStart, length: visibleEnd - visibleStart))
        h.keys("L")
        #expect(h.selection.location == (h.text as NSString).range(of: "line 5").location)
        h.keys("H")
        #expect(h.selection.location == visibleStart)
    }

    @Test func countZeroIsNotACount() {
        #expect(Harness("|abcdefghijklmnop").keys("10l").marked == "abcdefghij|klmnop")
        #expect(Harness("abc|def").keys("0").marked == "|abcdef")
    }

    @Test func clickingMovesTheBlockCursor() {
        let h = Harness("|hello world")
        h.click(6)
        #expect(h.marked == "hello |world")
        h.click(11)
        #expect(h.marked == "hello worl|d")
    }
}
