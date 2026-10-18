// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotesVim",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NotesVim", targets: ["NotesVim"]),
        .executable(name: "NotesVimLauncher", targets: ["NotesVimLauncher"]),
    ],
    targets: [
        // Pure Vim logic: text in, edits + selection out. No AppKit, fully unit tested.
        .target(name: "VimEngine"),
        // Menu bar app: event tap, Accessibility adaptor for Notes, status item.
        .executableTarget(name: "NotesVim", dependencies: ["VimEngine"]),
        // Login item that starts NotesVim whenever Notes starts. Nothing else.
        .executableTarget(name: "NotesVimLauncher"),
        .testTarget(name: "VimEngineTests", dependencies: ["VimEngine"]),
    ]
)
