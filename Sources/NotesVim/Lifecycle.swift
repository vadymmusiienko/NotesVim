import AppKit
import ServiceManagement

/// NotesVim runs exactly while Notes runs.
///
/// macOS cannot start an app along with another one, so a tiny login item, NotesVim Launcher
/// (inside NotesVim.app), watches for Notes and starts NotesVim. NotesVim quits as soon as the
/// last Notes process is gone. Started by hand without Notes, it waits for Notes and then
/// quits with it.
@MainActor
final class Lifecycle {
    private let launcher = SMAppService.loginItem(identifier: "com.vadymmusiienko.NotesVim.Launcher")
    private let defaults = UserDefaults.standard

    /// Whether the launcher starts NotesVim whenever Notes starts. On unless turned off.
    var startsWithNotes: Bool {
        get { defaults.object(forKey: "startWithNotes") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "startWithNotes")
            applyLauncherSetting()
        }
    }

    /// The launcher is registered but macOS wants the user to allow it in Login Items.
    var launcherNeedsApproval: Bool { launcher.status == .requiresApproval }

    var isLauncherRunning: Bool { launcher.status == .enabled }

    func start() {
        // Earlier versions of NotesVim could open themselves at login; the launcher replaces that.
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
        // Registered from a download it would point at a temporary copy; the welcome window
        // moves NotesVim into Applications first, and that copy registers it.
        if AppLocation.isInApplications { applyLauncherSetting() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                          object: nil, queue: .main) { notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard application?.bundleIdentifier == NotesApplication.bundleIdentifier else { return }
            MainActor.assumeIsolated { Self.quitIfNotesIsGone() }
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Removes everything NotesVim added to the Mac: the launcher, the Accessibility permission,
    /// its settings and the app itself (to the Trash). Notes are not touched.
    func uninstall() {
        try? launcher.unregister()
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "com.vadymmusiienko.NotesVim"]
        try? reset.run()
        reset.waitUntilExit()
        if let domain = Bundle.main.bundleIdentifier { defaults.removePersistentDomain(forName: domain) }
        NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private static func quitIfNotesIsGone() {
        // Notes may already be starting again.
        guard NSRunningApplication.runningApplications(withBundleIdentifier: NotesApplication.bundleIdentifier).isEmpty else { return }
        NSApp.terminate(nil)
    }

    private func applyLauncherSetting() {
        do {
            // A launcher registered by a copy of NotesVim somewhere else would start that copy.
            let registeredFrom = defaults.string(forKey: "launcherRegisteredFrom")
            if startsWithNotes, launcher.status == .enabled, registeredFrom != Bundle.main.bundlePath {
                try launcher.unregister()
            }
            switch (startsWithNotes, launcher.status) {
            case (true, .notRegistered), (true, .notFound):
                try launcher.register()
                defaults.set(Bundle.main.bundlePath, forKey: "launcherRegisteredFrom")
            case (false, .enabled), (false, .requiresApproval):
                try launcher.unregister()
            default:
                break
            }
        } catch {
            NSLog("NotesVim: could not \(startsWithNotes ? "register" : "unregister") the launcher: \(error.localizedDescription)")
        }
    }
}
