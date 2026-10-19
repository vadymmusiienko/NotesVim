# NotesVim

Vim keys for Apple Notes, and only for Apple Notes.

NotesVim is a tiny menu bar app for macOS. While you are in Notes, `Esc` turns the cursor into a
Vim block and `h j k l`, `w b e`, `dd`, `ciw`, `.` and friends work as you would expect. Every
other app is left completely alone. It starts when Notes starts and quits when Notes quits.

## Install

1. Download `NotesVim-<version>.dmg` from the
   [latest release](https://github.com/vadymmusiienko/NotesVim/releases/latest).
2. Open it and drag **NotesVim** onto **Applications**.
3. Open NotesVim from Applications. macOS will say it _cannot verify that NotesVim is free of
   malware_. That is because NotesVim is not notarized by Apple (which needs a paid developer
   account), not because anything is wrong with it. To open it anyway:
   - **macOS 15 or later:** click **Done**, open **System Settings → Privacy & Security**, scroll
     down to _"NotesVim" was blocked to protect your Mac_, click **Open Anyway** and confirm.
   - **macOS 14:** Control-click NotesVim in Applications, choose **Open**, then **Open** again.

   You only need to do this once.

4. The welcome window walks you through the rest. The one thing NotesVim needs is the
   **Accessibility** permission: click **Open Accessibility Settings** and switch on
   **NotesVim** in the list (if it is not there, click **+** and choose NotesVim in
   Applications). The window ticks the step off as soon as it works.

That's it. Open a note and press `Esc`.

## Using it

Opening a note starts in Normal mode, with a block cursor. A new, empty note starts in Insert mode
so you can type right away. `Esc` (or `Ctrl-[`) goes to Normal mode, `i`, `a`, `o` and friends to
Insert mode.

|                    |                                                                                                                                                 |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| Motions            | `h j k l` `w b e ge W B E gE` `0 ^ $ _ + - Enter` `gg G` `{ }` `f F t T ; ,` `%` `gj gk` `H M L` `Ctrl-d/u/f/b`, all with counts                |
| Operators          | `d c y` with any motion, `dd cc yy`, and text objects `iw aw iW aW i" a" i' a' i( a( ib i[ i{ iB i< ip ap`                                      |
| Edits              | `x X s S D C Y r ~ J p P o O i a I A gI .`                                                                                                      |
| Visual             | `v V`, motions, text objects, `o d x X D c s C S y Y ~ u U r J p > <`                                                                           |
| Undo, indent, find | `u` / `Ctrl-r`, `>>` / `<<`, `/` `?` `n` `N` (done by Notes itself)                                                                             |
| Note list          | `Ctrl-h` goes to the list; there `j` / `k` move between notes, `gg` / `G` jump to the first / last one, `l` or `Ctrl-l` goes back into the note |

The menu bar badge shows the mode: **N** (Normal), **I** (Insert), **V** / **VL** (Visual). It is
only there while Notes is the active app. Its menu can switch Vim keys off, choose whether `j` /
`k` move by visual (wrapped) lines (the default, since Notes paragraphs usually wrap), and turn off
**Start with Notes**.

Good to know:

- Yank, delete and put use the system clipboard.
- `i"` / `a"` also match Notes' smart quotes “…”, and `i'` matches ‘…’.
- Commands work on non-Latin keyboard layouts (Russian, Ukrainian, ...): `j` is still the `j`
  key, while `f` and `r` use the letter you actually type.
- `u` undoes one Vim change, as in Vim.
- ⌘ shortcuts always go straight to Notes.
- Only Notes' list view is supported in the note list, not the gallery view.

## Privacy

NotesVim has no network access and collects nothing. It reads keys only while they are going to
Notes, and reads and edits the note you are working on through the macOS Accessibility API.
That is why it needs the Accessibility permission, and it is all it uses it for.

## Uninstall

Choose **Uninstall NotesVim…** in its menu (switch to Notes to see the menu bar badge). It moves
NotesVim to the Trash and removes its launcher, its Accessibility permission and its settings.

If you already deleted the app: remove **NotesVim** from **System Settings → General → Login Items
& Extensions** and from **System Settings → Privacy & Security → Accessibility**.

## Troubleshooting

- **Keys do nothing in Notes.** Check that NotesVim is switched on in **System Settings → Privacy
  & Security → Accessibility**. After installing a new version, switch it off and on again.
- **NotesVim does not start with Notes.** Make sure it is in Applications, that **Start with
  Notes** is checked in its menu, and that **NotesVim** is allowed in **System Settings → General →
  Login Items & Extensions**.
- **The welcome window again:** choose **Welcome Guide…** in the menu.

## How it starts with Notes

macOS cannot start one app along with another, so NotesVim registers a tiny login item, **NotesVim
Launcher** (inside NotesVim.app). It does one thing: when Notes starts, it starts NotesVim. It has
no permissions and uses about 3 MB of memory and no CPU. NotesVim itself quits as soon as Notes
quits.

## Contributing

Bug reports, ideas and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for how
to build, test and how it all works.

## License

Public domain ([The Unlicense](LICENSE)). Copy it, fork it, ship it, no strings attached.
