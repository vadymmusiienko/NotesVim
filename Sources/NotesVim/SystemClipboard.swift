import AppKit
import VimEngine

/// Yank, delete and put use the system clipboard, like Vim with `clipboard=unnamedplus`.
/// Whether a register is linewise is remembered for as long as the clipboard still holds
/// what NotesVim put there; text copied elsewhere is pasted characterwise.
///
/// Clipboard tools (Pure Paste, Raycast and the like) often rewrite what was just copied, for
/// example to strip formatting or the trailing line break. Text that still matches what we
/// wrote, ignoring trailing white space, is therefore still treated as our own register.
final class SystemClipboard: Clipboard {
    private let pasteboard = NSPasteboard.general
    private var lastWrite: (changeCount: Int, register: Register)?

    func read() -> Register? {
        guard let text = pasteboard.string(forType: .string) else { return nil }
        if let lastWrite, lastWrite.changeCount == pasteboard.changeCount || Self.trimmed(text) == Self.trimmed(lastWrite.register.text) {
            return lastWrite.register
        }
        return Register(text: text, linewise: false)
    }

    func write(_ register: Register) {
        pasteboard.clearContents()
        pasteboard.setString(register.text, forType: .string)
        lastWrite = (pasteboard.changeCount, register)
    }

    private static func trimmed(_ text: String) -> Substring {
        guard let last = text.lastIndex(where: { !$0.isWhitespace }) else { return "" }
        return text[...last]
    }
}
