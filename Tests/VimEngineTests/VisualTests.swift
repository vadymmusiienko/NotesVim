import Foundation
import Testing
@testable import VimEngine

@Suite struct VisualModeTests {
    @Test(arguments: [
        ("one |two three", "viw", "one [two] three"),
        ("|abcde", "vll", "[abc]de"),
        ("a|bcde", "vllohh", "[abcd]e"),
        ("|ab\ncd", "vj", "[ab\nc]d"),
        ("ab\n|cd\nef", "V", "ab\n[cd\n]ef"),
        ("ab\n|cd\nef", "Vk", "[ab\ncd\n]ef"),
        ("a\n|b\n\nc", "vip", "[a\nb\n]\nc"),
        ("|ab", "v$", "[ab]"),
    ])
    func selection(start: String, keys: String, expected: String) {
        let h = Harness(start).keys(keys)
        #expect(h.marked == expected)
    }

    @Test(arguments: [
        ("|one two", "vwd", "|wo"),
        ("|ab\ncd\nef", "vjd", "|d\nef"),
        ("ab\n|cd\nef", "Vd", "ab\n|ef"),
        ("|a\nb\nc", "Vjd", "|c"),
        ("ab|cd", "v$d", "a|b"),
        ("|abc def", "veU", "|ABC def"),
        ("|ABC def", "veu", "|abc def"),
        ("|aBc def", "ve~", "|AbC def"),
        ("|abc", "vlrx", "|xxc"),
        ("|a\nb\nc", "VjjJ", "a b| c"),
        ("|one two", "vecX<Esc>", "|X two"),
        ("|one\ntwo", "VcX<Esc>", "|X\ntwo"),
        ("one |two", "vd", "one |wo"),
        ("|abc", "vll<Esc>", "ab|c"),
        ("|abc", "vlv", "a|bc"),
        ("|ab\ncd", "VD", "|cd"),
        ("|ab cd", "vlX", "|"),
    ])
    func operation(start: String, keys: String, expected: String) {
        let h = Harness(start).keys(keys)
        #expect(h.marked == expected)
        #expect(h.mode == .normal)
    }

    @Test func yankMovesToStartAndLeavesTextAlone() {
        let h = Harness("one |two three").keys("vey")
        #expect(h.marked == "one |two three")
        #expect(h.clipboard.register == Register(text: "two", linewise: false))
        h.keys("Vy")
        #expect(h.clipboard.register == Register(text: "one two three\n", linewise: true))
    }

    @Test func putReplacesSelection() {
        let h = Harness("|one two", clipboard: Register(text: "XY", linewise: false)).keys("vep")
        #expect(h.marked == "X|Y two")
    }

    @Test func linewisePutOverLines() {
        let h = Harness("a\n|b\nc", clipboard: Register(text: "x\ny\n", linewise: true)).keys("Vp")
        #expect(h.marked == "a\n|x\ny\nc")
    }

    @Test func switchBetweenVisualKinds() {
        let h = Harness("a|b\ncd").keys("vj")
        #expect(h.mode == .visual)
        h.keys("V")
        #expect(h.mode == .visualLine)
        #expect(h.marked == "[ab\ncd]")
        h.keys("v")
        #expect(h.mode == .visual)
        #expect(h.marked == "a[b\ncd]")
    }

    @Test func indentInVisualModeIsDelegatedAndExits() {
        let h = Harness("|ab\ncd").keys("Vj>")
        #expect(h.actions == [.indent])
        #expect(h.mode == .normal)
    }

    @Test func dragSelectionKeepsVisualMode() {
        let h = Harness("|abcdef").keys("vl")
        h.click(3)
        #expect(h.mode == .normal)
        #expect(h.marked == "abc|def")
    }
}
