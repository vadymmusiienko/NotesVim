import AppKit
import Carbon.HIToolbox
import VimEngine

/// Turns key events into `VimKey`s and finds key codes for shortcuts, independent of the
/// active keyboard layout.
///
/// With a non-Latin layout (Ukrainian, Russian, Greek, ...) commands are read from the
/// ASCII-capable layout macOS uses for ⌘ shortcuts, so `j` still moves down while `fж`
/// still finds "ж".
@MainActor
final class KeyboardLayout {
    private var sourceIdentifier: String?
    private var currentIsASCIICapable = true
    private var asciiCharacters: [Bool: [CGKeyCode: Character]] = [:]
    private var asciiKeyCodes: [Character: CGKeyCode] = [:]

    func key(for event: CGEvent) -> VimKey? {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        switch keyCode {
        case kVK_Escape: return .escape
        case kVK_Return, kVK_ANSI_KeypadEnter: return .enter
        case kVK_Delete: return .backspace
        case kVK_Tab: return .tab
        case kVK_LeftArrow: return .left
        case kVK_RightArrow: return .right
        case kVK_UpArrow: return .up
        case kVK_DownArrow: return .down
        default: break
        }
        refreshIfNeeded()
        let flags = event.flags
        let nsEvent = NSEvent(cgEvent: event)
        if flags.contains(.maskControl) {
            guard let character = asciiCharacters[false]?[CGKeyCode(keyCode)] ?? nsEvent?.charactersIgnoringModifiers?.first else { return nil }
            return .ctrl(character)
        }
        guard let literal = nsEvent?.characters?.first else { return nil }
        if flags.contains(.maskAlternate) || currentIsASCIICapable { return .char(literal) }
        let command = asciiCharacters[flags.contains(.maskShift)]?[CGKeyCode(keyCode)] ?? literal
        return VimKey(command: command, literal: literal)
    }

    /// Key code that types `character` on the layout used for ⌘ shortcuts.
    func keyCode(for character: Character) -> CGKeyCode? {
        refreshIfNeeded()
        return asciiKeyCodes[character]
    }

    private func refreshIfNeeded() {
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let identifier = Self.property(current, kTISPropertyInputSourceID).map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }
        guard identifier != sourceIdentifier || asciiKeyCodes.isEmpty else { return }
        sourceIdentifier = identifier
        currentIsASCIICapable = Self.property(current, kTISPropertyInputSourceIsASCIICapable)
            .map { CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque($0).takeUnretainedValue()) } ?? true

        let ascii = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
        guard let layoutData = Self.property(ascii, kTISPropertyUnicodeKeyLayoutData) else { return }
        let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)

        var unshifted: [CGKeyCode: Character] = [:]
        var shifted: [CGKeyCode: Character] = [:]
        var codes: [Character: CGKeyCode] = [:]
        for keyCode in CGKeyCode(0)..<CGKeyCode(128) {
            if let character = Self.translate(layout, keyCode, shift: false) {
                unshifted[keyCode] = character
                if codes[character] == nil { codes[character] = keyCode }
            }
            if let character = Self.translate(layout, keyCode, shift: true) { shifted[keyCode] = character }
        }
        asciiCharacters = [false: unshifted, true: shifted]
        asciiKeyCodes = codes
    }

    private static func property(_ source: TISInputSource, _ key: CFString) -> UnsafeMutableRawPointer? {
        TISGetInputSourceProperty(source, key)
    }

    private static func translate(_ layout: UnsafePointer<UCKeyboardLayout>, _ keyCode: CGKeyCode, shift: Bool) -> Character? {
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let modifiers: UInt32 = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
        let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
                                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count, &length, &characters)
        guard status == noErr, length > 0 else { return nil }
        let string = String(utf16CodeUnits: characters, count: length)
        guard string.count == 1, let character = string.first, !character.isNewline,
              character.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return character
    }
}
