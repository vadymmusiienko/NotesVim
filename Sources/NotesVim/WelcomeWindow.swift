import AppKit
import ApplicationServices
import SwiftUI

/// The first-run guide: move NotesVim into Applications, allow Accessibility access, try it.
/// Each step checks itself off as soon as it is done, so the window always shows what is left.
@MainActor
final class WelcomeWindow: NSObject, NSWindowDelegate {
    private let model = WelcomeModel()
    private var window: NSWindow?

    private static let completedKey = "welcomeCompleted"

    /// True on first launch, and whenever NotesVim cannot work yet.
    static var isNeeded: Bool {
        !UserDefaults.standard.bool(forKey: completedKey) || !AppLocation.isInApplications || !AXIsProcessTrusted()
    }

    func show() {
        model.refresh()
        if window == nil {
            let hosting = NSHostingController(rootView: WelcomeView(model: model) { [weak self] in self?.finish() })
            hosting.sizingOptions = .preferredContentSize
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = "Welcome to NotesVim"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        model.startWatching()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        model.stopWatching()
    }
}

@MainActor
final class WelcomeModel: ObservableObject {
    @Published private(set) var isInApplications = AppLocation.isInApplications
    @Published private(set) var hasPermission = AXIsProcessTrusted()
    @Published private(set) var moveError: String?
    private var timer: Timer?

    func refresh() {
        isInApplications = AppLocation.isInApplications
        hasPermission = AXIsProcessTrusted()
    }

    /// The permission is granted in System Settings, so it is checked while the window is open.
    func startWatching() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    func moveToApplications() {
        do {
            try AppLocation.moveToApplications()
        } catch {
            moveError = "Could not move NotesVim: \(error.localizedDescription) Drag it into Applications in Finder instead."
        }
    }

    func openAccessibilitySettings() {
        // Asking once adds NotesVim to the list in System Settings, so it only needs switching on.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func openNotes() {
        if let notes = NSWorkspace.shared.urlForApplication(withBundleIdentifier: NotesApplication.bundleIdentifier) {
            NSWorkspace.shared.openApplication(at: notes, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

struct WelcomeView: View {
    @ObservedObject var model: WelcomeModel
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Welcome to NotesVim")
                        .font(.title2.weight(.semibold))
                    Text("Vim keys for Apple Notes, and nothing else.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 24)

            VStack(alignment: .leading, spacing: 20) {
                StepView(number: 1, title: "Move NotesVim to Applications",
                         state: model.isInApplications ? .done : .current) {
                    Text("NotesVim starts and quits together with Notes, which works once it lives in Applications.")
                    Button("Move to Applications") { model.moveToApplications() }
                    if let error = model.moveError {
                        Text(error).foregroundStyle(.red)
                    }
                }
                StepView(number: 2, title: "Allow Accessibility access",
                         state: model.hasPermission ? .done : model.isInApplications ? .current : .later) {
                    Text("NotesVim reads the keys you type in Notes and moves the cursor through Accessibility. It ignores every other app, and nothing leaves your Mac.")
                    Button("Open Accessibility Settings") { model.openAccessibilitySettings() }
                    Text("Switch on NotesVim in the list. If it is not there, click +, then choose NotesVim in Applications.")
                        .foregroundStyle(.secondary)
                }
                StepView(number: 3, title: "Try it in Notes",
                         state: model.isInApplications && model.hasPermission ? .current : .later) {
                    Text("Open a note and press Esc: the cursor becomes a block. Move with h j k l, press i to type again, and Ctrl-h to go to the note list.")
                    Button("Open Notes") { model.openNotes() }
                }
            }

            HStack {
                Spacer()
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
            .padding(.top, 26)
        }
        .padding(.horizontal, 28)
        .padding(.top, 34)
        .padding(.bottom, 22)
        .frame(width: 500)
    }
}

private struct StepView<Content: View>: View {
    enum State { case done, current, later }

    let number: Int
    let title: String
    let state: State
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            ZStack {
                Circle()
                    .fill(state == .done ? Color.green : state == .current ? Color.accentColor : Color.secondary.opacity(0.35))
                if state == .done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                } else {
                    Text("\(number)")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                if state == .current {
                    content
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .opacity(state == .later ? 0.5 : 1)
    }
}
