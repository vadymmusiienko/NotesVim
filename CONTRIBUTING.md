# Contributing to NotesVim

Thanks for helping! Issues and pull requests are welcome. NotesVim is public domain
([Unlicense](LICENSE)), and so is anything you contribute.

## Building

Only the Xcode Command Line Tools are needed (`xcode-select --install`), not Xcode.

```sh
./scripts/install.sh       # build, install to /Applications and start it
./scripts/test.sh          # engine unit tests
./scripts/build-app.sh     # build/NotesVim.app (Apple Silicon + Intel)
./scripts/make-dmg.sh      # dist/NotesVim-<version>.dmg, the file attached to releases
./scripts/e2e.sh           # end-to-end test against the real Notes app (see below)
./scripts/record-demo.sh   # re-record docs/demo.gif (uses a "NotesVim Demo" folder in Notes)
```

`install.sh` runs `scripts/setup-signing.sh` once, which creates a self-signed code signing
identity in its own keychain. macOS remembers the Accessibility permission per signature, so a
stable signature keeps the permission working across rebuilds (ad hoc signing would lose it every
time). Releases are signed with the same identity, so people keep the permission when they
update.

`scripts/test.sh` passes the Swift Testing macro plugin path explicitly: without Xcode, plain
`swift test` sometimes fails with "plugin for module 'TestingMacros' not found".

## End-to-end tests

`scripts/e2e.sh` drives Notes with real key presses and checks the result through Accessibility.

- It needs a note whose first line is `NotesVim scratch` to be open in Notes, with the cursor in
  it. It refuses to edit any other note.
- The terminal needs Accessibility and Screen Recording access (one test compares on-screen
  colours).
- It takes over the keyboard and mouse for about a minute.
- Besides key sequences it checks switching notes (it creates a second note, `NotesVim scratch
2`, once), a new note (it creates one and deletes it again), the note list, the block cursor
  overlay, the menu bar icon, and a launcher panel taking the keyboard.

`./scripts/e2e.sh scenarios` runs only those checks. `NOTESVIM_DEBUG=1 NOTESVIM_LOG=/tmp/nv.log
./scripts/e2e.sh` traces every key NotesVim handles.

## How it works

- **`VimEngine`** (pure Swift, no AppKit, fully unit tested) is the Vim state machine. Given a key
  and a snapshot of the note body (text plus selection, in UTF-16 offsets), it returns text edits
  and the selection to show. The Normal mode block cursor is a one-character selection. Word,
  paragraph and `cw` / `dw` motions are ports of Vim's own algorithms.
- **`NotesVim`** (the app) taps the key events the window server delivers to the Notes process
  (`CGEvent.tapCreateForPid`), so keys typed into Raycast, Spotlight and other panels never reach
  it. The tap runs on its own thread: in Insert mode it lets keys straight through, other keys go
  to the main thread in order. There the focused `AXTextArea` is read through Accessibility, the
  engine runs, and the result is written back with `AXSelectedTextRange` + `AXSelectedText`.
  Edits replace only the affected range, so the rest of the note keeps its formatting.
- Notes merges consecutive Accessibility edits into one undo step. After each change NotesVim
  sends Notes an arrow key directly (`CGEvent.postToPid`) to end the undo group, waits until Notes
  has processed it, and restores the cursor. One-character inserts and deletes also rewrite a
  neighbouring character as itself, because Notes would otherwise still merge them.
- Notes shows every note in the same text area; its `AXIdentifier` (`Note[id=…]`) tells notes
  apart, so opening a note can start in Normal mode. The note list is the `AXTable` whose
  identifier starts with `ICMNoteListTableView`. These are Notes internals and may change with
  macOS updates.
- On empty lines there is no character to select, so a small click-through window draws the
  block, in the colour AppKit derives from Notes' accent colour.
- **`NotesVimLauncher`** is a login item inside the app bundle that starts NotesVim whenever Notes
  starts. NotesVim quits when Notes quits.

## Releasing

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist` (and in
   `Resources/Launcher/Info.plist`).
2. Run `./scripts/test.sh`, `./scripts/e2e.sh` and `./scripts/make-dmg.sh`.
3. Create a GitHub release tagged `v<version>`, describe the changes in its notes, and attach
   `dist/NotesVim-<version>.dmg`.
