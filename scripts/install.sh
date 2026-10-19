#!/bin/bash
# Builds NotesVim, installs it to /Applications and (re)starts it.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/setup-signing.sh
./scripts/build-app.sh

DEST="/Applications/NotesVim.app"
if pgrep -xq NotesVim; then
  osascript -e 'quit app id "com.vadymmusiienko.NotesVim"' || true
  for _ in {1..20}; do pgrep -xq NotesVim || break; sleep 0.1; done
  pkill -x NotesVim || true
fi
command rm -rf "$DEST"
cp -R build/NotesVim.app "$DEST"
open "$DEST"
echo "Installed and launched $DEST"
