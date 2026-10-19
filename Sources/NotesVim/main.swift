import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings()
    private let lifecycle = Lifecycle()
    private let welcome = WelcomeWindow()
    private var controller: NotesVimController?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = NotesVimController(settings: settings)
        let statusItem = StatusItemController(controller: controller, settings: settings, lifecycle: lifecycle, welcome: welcome)
        controller.onStateChange = { [weak statusItem] in statusItem?.update() }
        lifecycle.start()
        controller.start()
        self.controller = controller
        self.statusItem = statusItem
        if WelcomeWindow.isNeeded { welcome.show() }
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
