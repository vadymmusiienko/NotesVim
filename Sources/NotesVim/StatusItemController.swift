import AppKit
import ServiceManagement
import VimEngine

/// Menu bar badge showing the current mode (N, I, V, VL) plus a small settings menu.
/// The badge is dimmed whenever Notes is not the active app.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let controller: NotesVimController
    private let settings: Settings
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var imageCache: [String: NSImage] = [:]

    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let permissionItem = NSMenuItem(title: "Grant Accessibility Access…", action: #selector(grantAccess), keyEquivalent: "")
    private let enabledItem = NSMenuItem(title: "Enable Vim Keys in Notes", action: #selector(toggleEnabled), keyEquivalent: "")
    private let screenLinesItem = NSMenuItem(title: "j and k Move by Visual Lines", action: #selector(toggleScreenLines), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")

    init(controller: NotesVimController, settings: Settings) {
        self.controller = controller
        self.settings = settings
        super.init()
        item.button?.setAccessibilityTitle("NotesVim")
        item.menu = buildMenu()
        update()
    }

    func update() {
        guard let button = item.button else { return }
        let label: String
        let filled: Bool
        switch controller.mode {
        case .insert: (label, filled) = ("I", false)
        case .normal: (label, filled) = ("N", true)
        case .visual: (label, filled) = ("V", true)
        case .visualLine: (label, filled) = ("VL", true)
        }
        button.image = badge(label, filled: filled)
        button.appearsDisabled = !(controller.isNotesActive && settings.isEnabled && controller.hasPermission)
        button.toolTip = "NotesVim: \(statusText)"
    }

    private var statusText: String {
        if !controller.hasPermission { return "Needs Accessibility access" }
        if !settings.isEnabled { return "Off" }
        guard controller.isNotesActive else { return "Waiting for Notes" }
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
        for menuItem in [permissionItem, enabledItem, screenLinesItem, loginItem] { menuItem.target = self }
        menu.addItem(statusLine)
        menu.addItem(permissionItem)
        menu.addItem(.separator())
        menu.addItem(enabledItem)
        menu.addItem(screenLinesItem)
        menu.addItem(.separator())
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit NotesVim", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        statusLine.title = statusText
        permissionItem.isHidden = controller.hasPermission
        enabledItem.state = settings.isEnabled ? .on : .off
        screenLinesItem.state = settings.verticalMovesUseScreenLines ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func grantAccess() { controller.openAccessibilitySettings() }

    @objc private func toggleEnabled() { settings.isEnabled.toggle() }

    @objc private func toggleScreenLines() { settings.verticalMovesUseScreenLines.toggle() }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Could not change the login item"
            alert.runModal()
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
