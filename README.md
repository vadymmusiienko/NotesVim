# NotesVim

Vim keybindings for Apple Notes, and only for Apple Notes. A tiny menu bar app: while Notes is
frontmost it reads keys before Notes does; in every other app it is switched off completely.

## Install

```sh
./scripts/install.sh
```

This builds `NotesVim.app`, copies it to `~/Applications` and starts it. On first launch, allow
it in **System Settings → Privacy & Security → Accessibility**. The menu bar badge shows the
mode: **N** (Normal), **I** (Insert, outlined), **V** / **VL** (Visual); it is dimmed when Notes
is not active.

`install.sh` runs `scripts/setup-signing.sh` once, which creates a local self-signed code signing
identity in its own keychain. macOS remembers the Accessibility permission per signature, so this
keeps the permission working across rebuilds (ad hoc signing would silently lose it every time).

## Using it

Opening a note (clicking into it, or switching to another note) starts in Normal mode. A new,
empty note starts in Insert mode, so you can type right away. Press `Esc` (or `Ctrl-[`) for Normal
mode and `i`, `a`, `o` and friends for Insert mode.

`Ctrl-h` (in Normal mode) moves to the note list, where `j` and `k` go to the next and previous
note, `gg` and `G` to the first and last one, and `l` goes into the selected note. Other letters
do nothing there. In Insert mode `Ctrl-h` stays backspace.

| | |
|---|---|
| Motions | `h j k l` `w b e ge W B E gE` `0 ^ $ _ + - Enter` `gg G` `{ }` `f F t T ; ,` `%` `gj gk` `H M L` `Ctrl-d/u/f/b`, all with counts |
| Operators | `d c y` with any motion, `dd cc yy`, and text objects `iw aw iW aW i" a" i' a' i( a( ib i[ i{ iB i< ip ap` |
| Edits | `x X s S D C Y r ~ J p P o O i a I A gI .` |
| Visual | `v V`, motions, text objects, `o d x X D c s C S y Y ~ u U r J p > <` |
| Delegated to Notes | `u` / `Ctrl-r` (undo/redo), `>>` / `<<` (indent), `/` `?` (Find), `n` `N` |

Menu options: turn Vim keys off, and choose whether `j`/`k` move by visual (wrapped) lines,
which is the default because Notes paragraphs usually wrap.

Notes-specific details:

- Yank, delete and put use the system clipboard (like `clipboard=unnamedplus`). Linewise yanks
  survive clipboard tools that rewrite the clipboard (Pure Paste, Raycast, ...).
- `i"` / `a"` also match Notes' smart quotes “…”, and `i'` matches ‘…’.
- Commands work on non-Latin keyboard layouts (Russian, Ukrainian, ...): `j` is still the `j`
  key, while `f` and `r` use the letter you actually type.
- `u` is one Vim change, and `cw` plus the text you type is one undo step, as in Vim. Text typed with `i` right next to a change you just
  made (for example `dw` followed by `i…`) shares one undo step with that change.
- ⌘ shortcuts always go straight to Notes.
- The block cursor is Notes' own one-character selection. On empty lines and in empty notes,
  where there is no character to select, a small overlay draws the block instead (the same idea
  VimMode.spoon uses for its cursor).

## How it works

- **`VimEngine`** (pure Swift, no AppKit) is the Vim state machine. Given a key and a snapshot
  of the note body (text plus selection, in UTF-16 offsets), it returns text edits and the
  selection to show. The Normal mode "block cursor" is a one-character selection. Word, paragraph
  and `cw` / `dw` motions are ports of Vim's own algorithms.
- **`NotesVim`** (the app) installs a keyboard event tap that is only enabled while Notes is
  frontmost, and ignores keys the window server sends to another process (Raycast, Spotlight
  and other launchers take the keyboard without becoming the active app). In Insert mode only
  `Esc` is intercepted. In Normal/Visual mode it reads the
  focused `AXTextArea` through the Accessibility API, runs the engine, and writes back with
  `AXSelectedTextRange` + `AXSelectedText`. Edits replace only the affected range, so the rest of
  the note keeps its formatting.
- Notes merges consecutive Accessibility edits into one undo step. After each change NotesVim
  sends Notes an arrow key directly (`CGEvent.postToPid`) to end the undo group, waits until
  Notes has processed it, and restores the cursor. One-character inserts and deletes also rewrite
  a neighbouring character as itself, because Notes would otherwise still merge them.

## Development

```sh
./scripts/test.sh           # engine unit tests
./scripts/build-app.sh     # build/NotesVim.app
./scripts/e2e.sh           # end-to-end test against the real Notes app (see below)
```

`scripts/e2e.sh` drives Notes with real key presses and checks the result through Accessibility.
It needs a note whose first line is `NotesVim scratch` to be open (it refuses to edit any other
note), the terminal needs Accessibility and Screen Recording access (one test compares on-screen
colours), and it takes over the keyboard and mouse for about a minute. Besides the key sequences
it checks switching notes (it creates a second note, `NotesVim scratch 2`, once), a new note (it
creates one and deletes it again), the block cursor overlay, and a launcher panel taking the
keyboard. `./scripts/e2e.sh scenarios` runs only those.
`NOTESVIM_DEBUG=1 NOTESVIM_LOG=/tmp/nv.log ./scripts/e2e.sh` traces every key.
