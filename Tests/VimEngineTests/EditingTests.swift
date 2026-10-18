import Foundation
import Testing
@testable import VimEngine

@Suite struct OperatorTests {
    @Test(arguments: [
        ("|one two three", "dw", "|two three"),
        ("one two |three", "dw", "one two| "),
        ("one |two\nthree", "dw", "one| \nthree"),
        ("one tw|o\nthree", "dw", "one t|w\nthree"),
        ("|one\ntwo three", "d2w", "|three"),
        ("|foo\nbar", "dw", "|\nbar"),
        ("abc|d", "dw", "ab|c"),
        ("|one two", "de", "| two"),
        ("one tw|o", "db", "one |o"),
        ("one\n|two\nthree", "dd", "one\n|three"),
        ("one\n|two", "dd", "|one"),
        ("|a\nb\nc", "2dd", "|c"),
        ("|a\nb\nc", "dj", "|c"),
        ("a\nb\n|c", "dk", "|a"),
        ("|  a\nb", "dd", "|b"),
        ("ab|cdef", "d$", "a|b"),
        ("ab|cdef", "D", "a|b"),
        ("ab|cdef", "d0", "|cdef"),
        ("  ab|cd", "d^", "  |cd"),
        ("ab|cd", "x", "ab|d"),
        ("a|bcdef", "3x", "a|ef"),
        ("abc|d", "x", "ab|c"),
        ("a\n|\nb", "x", "a\n|\nb"),
        ("ab|cd", "X", "a|cd"),
        ("|a\nb\n\nc", "d}", "|\nc"),
        ("a|b\ncd\n\ne", "d}", "|a\n\ne"),
        ("|a b c d", "dfc", "| d"),
        ("|a b c d", "dtc", "|c d"),
        ("a b c |d", "dFb", "a |d"),
        ("|a\nb\nc\nd", "dG", "|"),
        ("a\nb\n|c\nd", "dgg", "|d"),
        ("one t|wo three", "diw", "one | three"),
        ("one t|wo three", "daw", "one |three"),
        ("one tw|o", "daw", "on|e"),
        ("one |  two", "diw", "one|two"),
        ("say \"hel|lo\" now", "di\"", "say \"|\" now"),
        ("|say \"hello\" now", "di\"", "say \"|\" now"),
        ("say \"hel|lo\" now", "da\"", "say |now"),
        ("it's 'q|t' ok", "di'", "it's '|' ok"),
        ("say \u{201C}hel|lo\u{201D} now", "di\"", "say \u{201C}|\u{201D} now"),
        ("|say \u{201C}hello\u{201D} now", "da\"", "say |now"),
        ("it\u{2019}s \u{2018}q|t\u{2019} ok", "di'", "it\u{2019}s \u{2018}|\u{2019} ok"),
        ("\u{201C}a \"|b\" c\u{201D}", "di\"", "\u{201C}a \"|\" c\u{201D}"),
        ("\"a \u{201C}|b\u{201D} c\"", "di\"", "\"a \u{201C}|\u{201D} c\""),
        ("\"a\" |b \"c\"", "di\"", "\"a\"|\"c\""),
        ("x = \"a\\\"|b\"", "di\"", "x = \"|\""),
        ("f(a, |b)", "di(", "f(|)"),
        ("f(a, |b)", "dib", "f(|)"),
        ("f(a, |b)", "da(", "|f"),
        ("f(a, (|b))", "di(", "f(a, (|))"),
        ("f(|a, (b))", "di)", "f(|)"),
        ("x [a, |b] y", "di[", "x [|] y"),
        ("if {\n    |foo\n}", "di{", "if {\n|}"),
        ("if {\n    |foo\n}", "diB", "if {\n|}"),
        ("<a |b>", "di<", "<|>"),
        ("a\n|b\n\nc", "dip", "|\nc"),
        ("|a\nb\n\nc", "dap", "|c"),
        ("a\n\n|c\nd", "dap", "|a"),
    ])
    func delete(start: String, keys: String, expected: String) {
        #expect(Harness(start).keys(keys).marked == expected)
    }

    @Test(arguments: [
        ("|one two", "cwxyz<Esc>", "xy|z two"),
        ("on|e two", "cwX<Esc>", "on|X two"),
        ("one| two", "cwX<Esc>", "one|Xtwo"),
        ("|one two three", "c2wX<Esc>", "|X three"),
        ("ab|cdef", "CX<Esc>", "ab|X"),
        ("ab|cdef", "c$X<Esc>", "ab|X"),
        ("one\n|two\nthree", "ccX<Esc>", "one\n|X\nthree"),
        ("one\n|two\nthree", "SX<Esc>", "one\n|X\nthree"),
        ("a|bc", "sX<Esc>", "a|Xc"),
        ("a\n|\nb", "sX<Esc>", "a\n|X\nb"),
        ("say \"hel|lo\" now", "ci\"X<Esc>", "say \"|X\" now"),
        ("if {\n    |foo\n}", "ci{bar<Esc>", "if {\nba|r\n}"),
        ("one t|wo three", "ciwX<Esc>", "one |X three"),
    ])
    func change(start: String, keys: String, expected: String) {
        let h = Harness(start).keys(keys)
        #expect(h.marked == expected)
        #expect(h.mode == .normal)
    }

    @Test func changeLeavesInsertModeUntilEscape() {
        let h = Harness("|one two").keys("cw")
        #expect(h.mode == .insert)
        #expect(h.marked == "| two")
        h.keys("hi")
        #expect(h.marked == "hi| two")
    }

    @Test(arguments: [
        ("|one\ntwo", "yyp", "one\n|one\ntwo"),
        ("|one\ntwo", "yyP", "|one\none\ntwo"),
        ("|one two", "ywP", "one| one two"),
        ("|one two", "yw$p", "one twoone| "),
        ("one\n|two", "yyp", "one\ntwo\n|two"),
        ("|ab", "xp", "b|a"),
        ("|one\ntwo", "ddp", "two\n|one"),
        ("|one\ntwo\nthree", "yjGp", "one\ntwo\nthree\n|one\ntwo"),
        ("  |one\ntwo", "yyjp", "  one\ntwo\n  |one"),
        ("|a b", "yiwwviwp", "a |a"),
    ])
    func yankAndPut(start: String, keys: String, expected: String) {
        #expect(Harness(start).keys(keys).marked == expected)
    }

    @Test func putRepeatsWithCount() {
        let h = Harness("x|y", clipboard: Register(text: "ab", linewise: false))
        #expect(h.keys("3p").marked == "xyababa|b")
    }

    @Test func putLinewiseAtLastLine() {
        let h = Harness("one\n|two", clipboard: Register(text: "x\n", linewise: true))
        #expect(h.keys("p").marked == "one\ntwo\n|x")
        let above = Harness("one\n|two", clipboard: Register(text: "x\n", linewise: true))
        #expect(above.keys("P").marked == "one\n|x\ntwo")
    }

    @Test func multilineCharacterwisePutLeavesCursorAtStart() {
        let h = Harness("|ab", clipboard: Register(text: "x\ny", linewise: false))
        #expect(h.keys("p").marked == "a|x\nyb")
    }

    @Test func yankWritesTheClipboard() {
        let h = Harness("|one two").keys("yiw")
        #expect(h.clipboard.register == Register(text: "one", linewise: false))
        h.keys("yy")
        #expect(h.clipboard.register == Register(text: "one two\n", linewise: true))
        #expect(h.text == "one two")
    }

    @Test func yankUpwardMovesToTheTarget() {
        let h = Harness("one\ntw|o").keys("yk")
        #expect(h.marked == "on|e\ntwo")
    }
}

@Suite struct SimpleCommandTests {
    @Test(arguments: [
        ("|abc", "rx", "|xbc"),
        ("|abc", "3rx", "xx|x"),
        ("|abc", "4rx", "|abc"),
        ("ab|cd", "r<CR>", "ab\n|d"),
        ("|abc", "~~", "AB|c"),
        ("|abc", "5~", "AB|C"),
        ("|ab-c", "4~", "AB-|C"),
        ("|one\n   two", "J", "one| two"),
        ("|one \ntwo", "J", "one |two"),
        ("|a\nb\nc", "3J", "a b| c"),
        ("|a\n\nb", "J", "|a\nb"),
        ("|f(\n)", "J", "f(|)"),
        ("|a", "J", "|a"),
        ("|one\ntwo", "oX<Esc>", "one\n|X\ntwo"),
        ("|one\ntwo", "OX<Esc>", "|X\none\ntwo"),
        ("o|ne", "AX<Esc>", "one|X"),
        ("  o|ne", "IX<Esc>", "  |Xone"),
        ("  o|ne", "gIX<Esc>", "|X  one"),
        ("o|ne", "aX<Esc>", "on|Xe"),
        ("one|", "aX<Esc>", "one|X"),
        ("|abc", "3ix<Esc>", "xx|xabc"),
        ("|z", "2oab<Esc>", "z\nab\na|b"),
        ("|x", "3Aab<Esc>", "xababa|b"),
    ])
    func command(start: String, keys: String, expected: String) {
        #expect(Harness(start).keys(keys).marked == expected)
    }

    @Test func undoAndRedoAreDelegated() {
        let h = Harness("|abc").keys("u2<C-r>")
        #expect(h.actions == [.undo, .redo, .redo])
        #expect(h.text == "abc")
    }

    @Test func indentIsDelegated() {
        let h = Harness("|abc").keys(">><<3>>")
        #expect(h.actions == [.indent, .outdent, .indent, .indent, .indent])
    }

    @Test func searchIsDelegated() {
        let h = Harness("|abc").keys("/n2N")
        #expect(h.actions == [.find, .findNext, .findPrevious, .findPrevious])
    }

    @Test func unknownKeysAreSwallowedInNormalMode() {
        let h = Harness("|abc")
        let response = h.engine.handle(.char("Q"), in: h.snapshot)
        #expect(response.handled)
        #expect(response.edits.isEmpty)
        #expect(h.engine.handle(.char("z"), in: h.snapshot).handled)
        #expect(h.engine.handle(.char("q"), in: h.snapshot).handled)
    }

    @Test func insertModePassesKeysThrough() {
        let h = Harness("|abc").keys("i")
        let response = h.engine.handle(.char("j"), in: h.snapshot)
        #expect(response == .pass)
    }

    @Test func escapeCancelsAPendingOperator() {
        let h = Harness("|one two").keys("d<Esc>w")
        #expect(h.marked == "one |two")
    }

    @Test func controlBracketIsEscape() {
        let h = Harness("|abc").keys("i")
        _ = h.engine.handle(.ctrl("["), in: h.snapshot)
        #expect(h.mode == .normal)
    }
}

@Suite struct RepeatTests {
    @Test(arguments: [
        ("|one two three", "dw.", "|three"),
        ("|abcdef", "x3.", "|ef"),
        ("|foo foo foo", "cwbar<Esc>w.", "bar ba|r foo"),
        ("|a", "ox<Esc>.", "a\nx\n|x"),
        ("|a\nb\nc\nd", "dd.", "|c\nd"),
        ("|abc", "rxl.", "x|xc"),
        ("|ab", "Ax<Esc>.", "abx|x"),
        ("|one two", "ciwX<Esc>w.", "X |X"),
        ("|ab cd", "~.", "AB| cd"),
    ])
    func dot(start: String, keys: String, expected: String) {
        #expect(Harness(start).keys(keys).marked == expected)
    }

    @Test func dotWithoutHistoryDoesNothing() {
        #expect(Harness("|abc").keys(".").marked == "|abc")
    }

    @Test func yankIsNotRepeatable() {
        #expect(Harness("|abc def").keys("xyw.").marked == "|c def")
    }

    @Test func insertedTextDetection() {
        #expect(VimEngine.insertedText(from: "abc", to: "abXYc", at: 2) == "XY")
        #expect(VimEngine.insertedText(from: "aa", to: "aaa", at: 1) == "a")
        #expect(VimEngine.insertedText(from: "abc", to: "ac", at: 1) == nil)
        #expect(VimEngine.insertedText(from: "abc", to: "Xabc", at: 1) == nil)
    }
}

@Suite struct SynchronizationTests {
    @Test func enteringANoteStartsInNormalMode() {
        let engine = VimEngine()
        let selection = engine.enterNormalMode(in: Snapshot(text: "one\ntwo", selection: NSRange(location: 5, length: 0)))
        #expect(selection == NSRange(location: 5, length: 1))
        #expect(engine.mode == .normal)
    }

    @Test func enteringANoteClampsTheCaretOntoTheLastCharacter() {
        let engine = VimEngine()
        let selection = engine.enterNormalMode(in: Snapshot(text: "one\ntwo", selection: NSRange(location: 3, length: 0)))
        #expect(selection == NSRange(location: 2, length: 1))
    }

    @Test func enteringANoteForgetsPendingKeys() {
        let h = Harness("|abc").keys("d")
        _ = h.engine.enterNormalMode(in: h.snapshot)
        #expect(h.keys("x").marked == "|bc")
    }

    @Test func externalTextChangeKeepsNormalMode() {
        let h = Harness("|abc")
        let selection = h.engine.synchronize(with: Snapshot(text: "abcd", selection: NSRange(location: 1, length: 2)))
        #expect(selection == NSRange(location: 1, length: 1))
        #expect(h.mode == .normal)
    }

    @Test func unchangedStateNeedsNoUpdate() {
        let h = Harness("|abc")
        #expect(h.engine.synchronize(with: h.snapshot) == nil)
        #expect(h.mode == .normal)
    }
}
