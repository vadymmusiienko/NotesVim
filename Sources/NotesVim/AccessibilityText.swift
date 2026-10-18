import AppKit
import ApplicationServices
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

    /// Identifies the note on display. Notes shows every note in the same text area, so this
    /// is how a switch to another note is noticed.
    var noteIdentifier: String? { attribute(kAXIdentifierAttribute) }

    /// Screen rectangle (top-left origin, like all Accessibility geometry) where a block cursor
    /// at `location` should be drawn when there is no character to select: on an empty line or
    /// in an empty note. It sits where Notes draws the caret on that line, as tall as a selected
    /// character in the line's font and half as wide as it is tall.
    ///
    /// Notes reports a collapsed range at the start of a line on the line before it, so the
    /// empty line is located from the characters around it instead.
    @MainActor func emptyCursorBounds(at location: Int, in text: NSString) -> CGRect? {
        let line: CGRect
        let fontLocation: Int?
        if location < text.length {
            // The empty line's own line break covers the whole line.
            guard let lineBreak = bounds(NSRange(location: location, length: 1)) else { return nil }
            line = lineBreak
            fontLocation = location
        } else if location > 0 {
            // Empty last line: right below the final line break, at the left text margin.
            guard let lineBreak = bounds(NSRange(location: location - 1, length: 1)),
                  let start = bounds(NSRange(location: 0, length: 0)) else { return nil }
            line = CGRect(x: start.minX, y: lineBreak.maxY, width: 0, height: lineBreak.height)
            fontLocation = location - 1
        } else {
            // Empty note: reported as a line above the first one.
            guard let above = bounds(NSRange(location: 0, length: 0)) else { return nil }
            line = above.offsetBy(dx: 0, dy: above.height)
            fontLocation = nil
        }
        let height = min(fontLocation.flatMap(lineHeight(at:)) ?? line.height, line.height)
        guard height > 0 else { return nil }
        return CGRect(x: line.minX, y: line.minY, width: height / 2, height: height)
    }

    /// Line height of the font at `location`, the height Notes gives a selected character.
    @MainActor private func lineHeight(at location: Int) -> CGFloat? {
        var cfRange = CFRange(location: location, length: 1)
        guard let parameter = AXValueCreate(.cfRange, &cfRange),
              let string = parameterized("AXAttributedStringForRange", parameter) as? NSAttributedString,
              string.length > 0,
              let font = string.attribute(NSAttributedString.Key("AXFont"), at: 0, effectiveRange: nil) as? [String: Any],
              let name = font["AXFontName"] as? String,
              let size = (font["AXFontSize"] as? NSNumber).map({ CGFloat($0.doubleValue) }) else { return nil }
        return Self.layoutManager.defaultLineHeight(for: NSFont(name: name, size: size) ?? .systemFont(ofSize: size))
    }

    @MainActor private static let layoutManager = NSLayoutManager()

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
