import AppKit
import VimEngine

/// Menu bar badge showing the current mode (N, I, V, VL) plus a small settings menu.
/// It is only in the menu bar while Notes is the active app, and dimmed when Vim keys are off.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let controller: NotesVimController
    private let settings: Settings
    private let lifecycle: Lifecycle
    private let welcome: WelcomeWindow
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var imageCache: [String: NSImage] = [:]

    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let permissionItem = NSMenuItem(title: "Grant Accessibility Access…", action: #selector(grantAccess), keyEquivalent: "")
    private let enabledItem = NSMenuItem(title: "Enable Vim Keys in Notes", action: #selector(toggleEnabled), keyEquivalent: "")
    private let screenLinesItem = NSMenuItem(title: "j and k Move by Visual Lines", action: #selector(toggleScreenLines), keyEquivalent: "")
    private let startWithNotesItem = NSMenuItem(title: "Start with Notes", action: #selector(toggleStartWithNotes), keyEquivalent: "")

    init(controller: NotesVimController, settings: Settings, lifecycle: Lifecycle, welcome: WelcomeWindow) {
        self.controller = controller
        self.settings = settings
        self.lifecycle = lifecycle
        self.welcome = welcome
        super.init()
        // Keeps its place in the menu bar each time it comes back.
        item.autosaveName = "NotesVim"
        item.button?.setAccessibilityTitle("NotesVim")
        item.menu = buildMenu()
        update()
    }

    func update() {
        guard let button = item.button else { return }
        let label: String
        let filled: Bool
        switch controller.mode {
        // Moving through the note list with j and k feels like Normal mode.
        case .insert where controller.isInNoteList: (label, filled) = ("N", true)
        case .insert: (label, filled) = ("I", false)
        case .normal: (label, filled) = ("N", true)
        case .visual: (label, filled) = ("V", true)
        case .visualLine: (label, filled) = ("VL", true)
        }
        // Without the permission it stays visible everywhere, so access can be granted from its menu.
        item.isVisible = controller.isNotesActive || !controller.hasPermission
        button.image = badge(label, filled: filled)
        button.appearsDisabled = !(controller.isNotesActive && settings.isEnabled && controller.hasPermission)
        button.toolTip = "NotesVim: \(statusText)"
    }

    private var statusText: String {
        if !controller.hasPermission { return "Needs Accessibility access" }
        if !settings.isEnabled { return "Off" }
        guard controller.isNotesActive else { return "Waiting for Notes" }
        if controller.isInNoteList { return "Note list" }
        switch controller.mode {
        case .insert: return "Insert mode"
        case .normal: return "Normal mode"
        case .visual: return "Visual mode"
        case .visualLine: return "Visual Line mode"
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        statusLine.isEnabled = false
        for menuItem in [permissionItem, enabledItem, screenLinesItem, startWithNotesItem] { menuItem.target = self }
        menu.addItem(statusLine)
        menu.addItem(permissionItem)
        menu.addItem(.separator())
        menu.addItem(enabledItem)
        menu.addItem(screenLinesItem)
        menu.addItem(.separator())
        menu.addItem(startWithNotesItem)
        menu.addItem(.separator())
        for (title, action) in [("About NotesVim", #selector(showAbout)), ("Welcome Guide…", #selector(grantAccess)),
                                ("Uninstall NotesVim…", #selector(uninstall))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit NotesVim", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        statusLine.title = statusText
        permissionItem.isHidden = controller.hasPermission
        enabledItem.state = settings.isEnabled ? .on : .off
        screenLinesItem.state = settings.verticalMovesUseScreenLines ? .on : .off
        startWithNotesItem.state = lifecycle.startsWithNotes ? .on : .off
        startWithNotesItem.title = lifecycle.startsWithNotes && lifecycle.launcherNeedsApproval
            ? "Start with Notes (Allow in Login Items…)" : "Start with Notes"
    }

    @objc private func grantAccess() { welcome.show() }

    @objc private func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func uninstall() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Uninstall NotesVim?"
        alert.informativeText = "This moves NotesVim to the Trash and removes its launcher, its Accessibility permission and its settings. Your notes are not touched."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        controller.stop()
        lifecycle.uninstall()
    }

    @objc private func toggleEnabled() { settings.isEnabled.toggle() }

    @objc private func toggleScreenLines() { settings.verticalMovesUseScreenLines.toggle() }

    @objc private func toggleStartWithNotes() {
        if lifecycle.startsWithNotes, lifecycle.launcherNeedsApproval {
            lifecycle.openLoginItemsSettings()
        } else {
            lifecycle.startsWithNotes.toggle()
        }
    }

    /// A rounded badge with the mode letters, sized like the system's own menu bar badges (the
    /// input source indicator, for example). Filled with knocked-out letters in Normal and
    /// Visual mode, outlined in Insert mode. Template image, so it follows the menu bar style.
    private func badge(_ label: String, filled: Bool) -> NSImage {
        let key = "\(label)-\(filled)"
        if let cached = imageCache[key] { return cached }
        let image = Self.drawBadge(label, filled: filled)
        imageCache[key] = image
        return image
    }

    static func drawBadge(_ label: String, filled: Bool) -> NSImage {
        let font = NSFont.systemFont(ofSize: 11, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let textSize = (label as NSString).size(withAttributes: attributes)
        let badgeHeight: CGFloat = 15
        let badgeWidth = max(badgeHeight, ceil(textSize.width) + 7)
        let size = NSSize(width: badgeWidth + 2, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let frame = NSRect(x: 1, y: (rect.height - badgeHeight) / 2, width: badgeWidth, height: badgeHeight)
            NSColor.black.set()
            if filled {
                NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4).fill()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
            } else {
                let outline = NSBezierPath(roundedRect: frame.insetBy(dx: 0.6, dy: 0.6), xRadius: 3.4, yRadius: 3.4)
                outline.lineWidth = 1.2
                outline.stroke()
            }
            let origin = NSPoint(x: frame.midX - textSize.width / 2, y: frame.midY - textSize.height / 2 + 0.5)
            (label as NSString).draw(at: origin, withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        return image
    }
}
