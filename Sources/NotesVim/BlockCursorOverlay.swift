import AppKit

/// Draws the Normal mode block cursor where there is no character to select: on an empty line
/// or at the end of the note. Everywhere else the block cursor is a one-character selection,
/// which Notes draws itself.
///
/// A small click-through window floats over Notes, filled with the colour Notes uses for
/// selected text, so it looks the same as the selection-based block cursor. Notes does not
/// report scrolling, so while the overlay is visible its position is refreshed on a timer.
@MainActor
final class BlockCursorOverlay {
    private let panel: NSPanel
    private let block = CALayer()
    /// Notes keeps drawing its blinking caret on the line, 1 pt left of the block and reaching
    /// half a point below it. A margin in the note's background colour covers it (whole points,
    /// as window frames are rounded to them).
    private static let caretMargin = NSEdgeInsets(top: 0, left: 1, bottom: 1, right: 0)
    private var timer: Timer?
    /// Returns the cursor rectangle in Accessibility coordinates, or nil to hide the overlay.
    private var locate: (() -> CGRect?)?

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(NSWindow.Level.normal.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        let view = NSView()
        view.wantsLayer = true
        view.layer?.addSublayer(block)
        panel.contentView = view
    }

    func show(locate: @escaping () -> CGRect?) {
        self.locate = locate
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func hide() {
        locate = nil
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
    }

    private func refresh() {
        guard let rect = locate?(), let screen = NSScreen.screens.first else {
            panel.orderOut(nil)
            return
        }
        // Accessibility uses a top-left origin on the primary screen, AppKit a bottom-left one.
        let margin = Self.caretMargin
        let frame = NSRect(x: rect.minX - margin.left, y: screen.frame.maxY - rect.maxY - margin.bottom,
                           width: rect.width + margin.left, height: rect.height + margin.bottom)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        block.frame = CGRect(x: margin.left, y: margin.bottom, width: rect.width, height: rect.height)
        let color = Self.notesSelectionColor(in: panel.effectiveAppearance)
        if block.backgroundColor != color { block.backgroundColor = color }
        var background = NSColor.textBackgroundColor.cgColor
        panel.effectiveAppearance.performAsCurrentDrawingAppearance { background = NSColor.textBackgroundColor.cgColor }
        if panel.contentView?.layer?.backgroundColor != background { panel.contentView?.layer?.backgroundColor = background }
        CATransaction.commit()
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private static let notesAccentColor: NSColor? = NSWorkspace.shared
        .urlForApplication(withBundleIdentifier: NotesApplication.bundleIdentifier)
        .flatMap { Bundle(url: $0) }
        .flatMap { NSColor(named: "Accent", bundle: $0) }

    /// AppKit derives the selection colour from the accent colour. With the system accent
    /// colour set to Multicolor (and the highlight colour following it), each app uses its own
    /// accent: yellow for Notes, but the default blue for NotesVim. AppKit's derivation is a
    /// blend, `selection = accent * k + c` for every colour channel, so it is recovered from
    /// NotesVim's own accent and selection colours and applied to Notes' accent.
    static func notesSelectionColor(in appearance: NSAppearance) -> CGColor {
        var color = NSColor.selectedTextBackgroundColor.cgColor
        appearance.performAsCurrentDrawingAppearance {
            color = NSColor.selectedTextBackgroundColor.cgColor
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: "AppleAccentColor") == nil, defaults.object(forKey: "AppleHighlightColor") == nil,
                  let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB),
                  let selection = NSColor.selectedTextBackgroundColor.usingColorSpace(.sRGB),
                  let notesAccent = notesAccentColor?.usingColorSpace(.sRGB) else { return }
            let a = [accent.redComponent, accent.greenComponent, accent.blueComponent]
            let s = [selection.redComponent, selection.greenComponent, selection.blueComponent]
            // Solve on the two channels where the accent differs most.
            let pairs = [(0, 1), (0, 2), (1, 2)]
            guard let (i, j) = pairs.max(by: { abs(a[$0.0] - a[$0.1]) < abs(a[$1.0] - a[$1.1]) }),
                  abs(a[i] - a[j]) > 0.2 else { return }
            let k = (s[i] - s[j]) / (a[i] - a[j])
            let c = s[i] - k * a[i]
            guard k > 0, k < 1 else { return }
            func blend(_ value: CGFloat) -> CGFloat { min(max(value * k + c, 0), 1) }
            color = NSColor(srgbRed: blend(notesAccent.redComponent), green: blend(notesAccent.greenComponent),
                            blue: blend(notesAccent.blueComponent), alpha: 1).cgColor
        }
        return color
    }
}
