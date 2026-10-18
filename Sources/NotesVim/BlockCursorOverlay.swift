import AppKit

/// Draws the Normal mode block cursor where there is no character to select: on an empty line
/// or at the end of the note. Everywhere else the block cursor is a one-character selection,
/// which Notes draws itself.
///
/// A small click-through window floats over Notes, filled with the system text selection colour
/// so it looks the same as the selection-based block cursor. Notes does not report scrolling,
/// so while the overlay is visible its position is refreshed on a timer.
@MainActor
final class BlockCursorOverlay {
    private let panel: NSPanel
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
        view.layer?.backgroundColor = NSColor.selectedTextBackgroundColor.cgColor
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
        let frame = NSRect(x: rect.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        panel.contentView?.layer?.backgroundColor = NSColor.selectedTextBackgroundColor.cgColor
        if !panel.isVisible { panel.orderFrontRegardless() }
    }
}
