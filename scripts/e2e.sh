#!/bin/bash
# Runs the end-to-end test against the real Notes app.
#
# Needs: Notes open on a note whose first line is "NotesVim scratch", and the terminal must
# have Accessibility access (NotesVim is started from the terminal so it inherits it).
# Takes over the keyboard focus for about a minute.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --scratch-path .build/app --product NotesVim 2>&1 | grep -E "error|warning: " || true
BIN="$(swift build -c release --scratch-path .build/app --show-bin-path)/NotesVim"
OUT="$(mktemp -d)"
swiftc -O scripts/e2e/NotesE2E.swift -o "$OUT/notes-e2e"

pkill -x NotesVim 2>/dev/null || true
NOTESVIM_DEBUG="${NOTESVIM_DEBUG:-0}" "$BIN" 2>"${NOTESVIM_LOG:-/dev/null}" &
NOTESVIM=$!
disown "$NOTESVIM"
trap 'kill $NOTESVIM 2>/dev/null || true; command rm -rf "$OUT"' EXIT
sleep 1
"$OUT/notes-e2e" "$@"
