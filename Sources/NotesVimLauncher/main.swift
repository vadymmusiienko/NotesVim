// NotesVim Launcher: a tiny login item that starts NotesVim whenever Notes starts.
//
// macOS has no way to start an app along with another one, so something has to watch. This
// helper does nothing else: no event tap, no Accessibility, no menu bar icon, about 2 MB of
// memory and no CPU while it waits. NotesVim itself quits when Notes quits.
import AppKit

let notesIdentifier = "com.apple.Notes"

/// The helper lives in NotesVim.app/Contents/Library/LoginItems.
let notesVimURL = Bundle.main.bundleURL
    .deletingLastPathComponent() // LoginItems
    .deletingLastPathComponent() // Library
    .deletingLastPathComponent() // Contents
    .deletingLastPathComponent() // NotesVim.app

func startNotesVim() {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.addsToRecentItems = false
    NSWorkspace.shared.openApplication(at: notesVimURL, configuration: configuration) { _, error in
        if let error { NSLog("NotesVim Launcher: could not start NotesVim: \(error.localizedDescription)") }
    }
}

NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { notification in
    let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    if application?.bundleIdentifier == notesIdentifier { startNotesVim() }
}
if !NSRunningApplication.runningApplications(withBundleIdentifier: notesIdentifier).isEmpty {
    startNotesVim()
}
RunLoop.main.run()
