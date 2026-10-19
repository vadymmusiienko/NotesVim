import AppKit

/// Where NotesVim.app lives, and moving it into Applications.
///
/// A downloaded app that has not been moved yet runs from a temporary, read-only copy (macOS
/// "translocates" it), and the launcher that starts NotesVim along with Notes needs a stable
/// location. So the welcome window moves NotesVim into Applications first.
@MainActor
enum AppLocation {
    static var isInApplications: Bool {
        let path = Bundle.main.bundlePath
        return applicationFolders.contains { path.hasPrefix($0.path + "/") }
    }

    private static var applicationFolders: [URL] {
        [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
    }

    /// Copies NotesVim into /Applications (or ~/Applications when that is not writable), starts
    /// the copy and quits. Throws when the copy fails; NotesVim keeps running then.
    static func moveToApplications() throws {
        let fileManager = FileManager.default
        let source = Bundle.main.bundleURL
        let folder = applicationFolders.first { fileManager.isWritableFile(atPath: $0.path) } ?? applicationFolders[1]
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.trashItem(at: destination, resultingItemURL: nil)
        }
        try fileManager.copyItem(at: source, to: destination)
        // The user already chose to open this download; the copy must not ask again.
        removeQuarantine(destination)

        // Leave no second copy behind in Downloads. A disk image or a translocated copy is read-only.
        let path = source.path
        if !path.hasPrefix("/Volumes/"), !path.contains("/AppTranslocation/"), fileManager.isWritableFile(atPath: source.deletingLastPathComponent().path) {
            try? fileManager.trashItem(at: source, resultingItemURL: nil)
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private static func removeQuarantine(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", url.path]
        try? process.run()
        process.waitUntilExit()
    }
}
