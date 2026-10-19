#!/bin/bash
# Builds dist/NotesVim-<version>.dmg: the app next to an Applications shortcut, with an arrow
# telling people to drag one onto the other. This file is what goes on GitHub Releases.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
NAME="NotesVim"
DMG="dist/$NAME-$VERSION.dmg"
WORK="$(mktemp -d)"
trap 'command rm -rf "$WORK"' EXIT

# dmgbuild writes the window layout directly (no Finder scripting). It lives in its own venv.
VENV=".build/dmgbuild-venv"
if [[ ! -x "$VENV/bin/dmgbuild" ]]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet dmgbuild
fi

swift scripts/dmg/make-background.swift "$WORK/background.png" 1
swift scripts/dmg/make-background.swift "$WORK/background@2x.png" 2
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$WORK/background.tiff" 2>/dev/null

mkdir -p dist
command rm -f "$DMG"
"$VENV/bin/dmgbuild" -s scripts/dmg/settings.py -D app="build/$NAME.app" -D background="$WORK/background.tiff" "$NAME" "$DMG" >/dev/null

KEYCHAIN="$HOME/Library/Keychains/notesvim-signing.keychain-db"
if [[ -f "$KEYCHAIN" ]]; then
  security unlock-keychain -p notesvim "$KEYCHAIN"
  HASH=$(security find-identity -p codesigning "$KEYCHAIN" | awk '/"NotesVim Local Signing"/ { print $2; exit }')
  codesign --force --sign "$HASH" --keychain "$KEYCHAIN" "$DMG"
fi
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
