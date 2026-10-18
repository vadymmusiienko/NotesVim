import ApplicationServices
import Foundation
import VimEngine

/// Reads and writes the text of one Accessibility element (the Notes note body).
///
/// Edits go through `AXSelectedText` (select a range, then replace the selection) rather than
/// `AXValue`, so the note's formatting outside the edited range is preserved and Notes
/// registers each edit as one normal undo step.
struct AccessibilityText {
    let element: AXUIElement

    func snapshot() -> Snapshot? {
        guard let selection = selection() else { return nil }
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) {
        case .success:
            guard let text = value as? String else { return nil }
            return Snapshot(text: text, selection: selection)
        case .noValue:
            // An empty note has no value at all rather than an empty string.
            return Snapshot(text: "", selection: selection)
        default:
            return nil
        }
    }

    /// Screen rectangle (top-left origin, like all Accessibility geometry) where a block cursor
    /// at `location` should be drawn when there is no character to select: on an empty line or
    /// at the end of the note.
    func emptyCursorBounds(at location: Int, in text: NSString) -> CGRect? {
        let rect: CGRect?
        if location < text.length {
            // The line break's own box sits on the right line; a collapsed range reports the line above.
            rect = bounds(NSRange(location: location, length: 1))
        } else if location > 0, text.character(at: location - 1) == 0x0A,
                  let lineBreak = bounds(NSRange(location: location - 1, length: 1)),
                  let textStart = bounds(NSRange(location: 0, length: 0)) {
            // Empty last line: one line below the final line break, at the left text margin.
            rect = CGRect(x: textStart.minX, y: lineBreak.maxY, width: 0, height: lineBreak.height)
        } else {
            rect = bounds(NSRange(location: location, length: 0))
        }
        guard let rect, rect.height > 0 else { return nil }
        return CGRect(x: rect.minX, y: rect.minY, width: (rect.height * 0.52).rounded(), height: rect.height)
    }

    private func bounds(_ range: NSRange) -> CGRect? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &cfRange),
              let value = parameterized("AXBoundsForRange", parameter), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    func selection() -> NSRange? {
        Self.range(from: rawAttribute(kAXSelectedTextRangeAttribute))
    }

    @discardableResult
    func select(_ range: NSRange) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    @discardableResult
    func replace(_ range: NSRange, with text: String) -> Bool {
        guard select(range) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    private func attribute<T>(_ name: String) -> T? {
        rawAttribute(name) as? T
    }

    private func rawAttribute(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func parameterized(_ name: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &value) == .success else { return nil }
        return value
    }

    /// Decodes a `CFRange` wrapped in an `AXValue`, checking the type first: Core Foundation
    /// casts are unchecked, so a misbehaving app must not be able to crash us.
    fileprivate static func range(from value: CFTypeRef?) -> NSRange? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var range = CFRange()
        guard AXValueGetType(axValue) == .cfRange, AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
}

/// Notes reports wrapped lines through the standard text layout attributes.
extension AccessibilityText: ScreenLayout {
    func lineNumber(at index: Int) -> Int? {
        (parameterized("AXLineForIndex", index as CFNumber) as? NSNumber)?.intValue
    }

    func range(ofLine line: Int) -> NSRange? {
        guard line >= 0 else { return nil }
        return Self.range(from: parameterized("AXRangeForLine", line as CFNumber))
    }

    func visibleRange() -> NSRange? {
        Self.range(from: rawAttribute("AXVisibleCharacterRange"))
    }
}
