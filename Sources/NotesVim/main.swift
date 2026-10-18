import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings()
    private var controller: NotesVimController?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = NotesVimController(settings: settings)
        let statusItem = StatusItemController(controller: controller, settings: settings)
        controller.onStateChange = { [weak statusItem] in statusItem?.update() }
        controller.start()
        self.controller = controller
        self.statusItem = statusItem
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
