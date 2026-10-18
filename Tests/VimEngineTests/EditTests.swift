import Foundation
import Testing
@testable import VimEngine

@Suite struct OwnUndoStepTests {
    private func widened(_ text: String, _ start: Int, _ end: Int, _ replacement: String) -> (Edit, String) {
        let ns = text as NSString
        let edit = Edit(start, end, replacement).ownUndoStep(in: ns)
        let original = NSMutableString(string: text)
        original.replaceCharacters(in: NSRange(location: start, length: end - start), with: replacement)
        let widenedResult = NSMutableString(string: text)
        widenedResult.replaceCharacters(in: edit.range, with: edit.text)
        #expect(original == widenedResult, "widening must not change the result")
        return (edit, widenedResult as String)
    }

    @Test func singleDeletionRewritesLeftNeighbour() {
        let (edit, _) = widened("abcd", 2, 3, "")
        #expect(edit == Edit(1, 3, "b"))
    }

    @Test func singleInsertionRewritesLeftNeighbour() {
        let (edit, _) = widened("abcd", 2, 2, "X")
        #expect(edit == Edit(1, 2, "bX"))
    }

    @Test func usesRightNeighbourAtLineStart() {
        let (edit, _) = widened("a\nbc", 2, 3, "")
        #expect(edit == Edit(2, 4, "c"))
    }

    @Test func keepsWholeEmojiAsNeighbour() {
        let (edit, _) = widened("👍🏽x", 4, 5, "")
        #expect(edit == Edit(0, 5, "👍🏽"))
    }

    @Test func neverRewritesAttachmentsOrLineBreaks() {
        let (edit, _) = widened("\u{FFFC}x\n", 1, 2, "")
        #expect(edit == Edit(1, 2, ""))
    }

    @Test func leavesLargerEditsAlone() {
        #expect(widened("abcd", 1, 3, "").0 == Edit(1, 3, ""))
        #expect(widened("abcd", 1, 2, "X").0 == Edit(1, 2, "X"))
    }
}
