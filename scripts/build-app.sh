#!/bin/bash
# Builds build/NotesVim.app (release) and signs it.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="NotesVim Local Signing"
KEYCHAIN="$HOME/Library/Keychains/notesvim-signing.keychain-db"
APP="build/NotesVim.app"

LAUNCHER="$APP/Contents/Library/LoginItems/NotesVimLauncher.app"

# One binary for both Apple Silicon and Intel Macs.
BUILD=(swift build -c release --scratch-path .build/app --arch arm64 --arch x86_64)
"${BUILD[@]}" --product NotesVim
"${BUILD[@]}" --product NotesVimLauncher
BIN_DIR="$("${BUILD[@]}" --show-bin-path)"

command rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$LAUNCHER/Contents/MacOS"
cp "$BIN_DIR/NotesVim" "$APP/Contents/MacOS/NotesVim"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi
cp "$BIN_DIR/NotesVimLauncher" "$LAUNCHER/Contents/MacOS/NotesVimLauncher"
cp Resources/Launcher/Info.plist "$LAUNCHER/Contents/Info.plist"

if [[ -f "$KEYCHAIN" ]]; then
  security unlock-keychain -p notesvim "$KEYCHAIN"
  HASH=$(security find-identity -p codesigning "$KEYCHAIN" | awk -v id="\"$IDENTITY\"" '$0 ~ id { print $2; exit }')
  # The helper is signed first: it is part of the app's signature.
  codesign --force --sign "$HASH" --keychain "$KEYCHAIN" "$LAUNCHER"
  codesign --force --sign "$HASH" --keychain "$KEYCHAIN" "$APP"
else
  echo "warning: no local signing identity, signing ad hoc." >&2
  echo "warning: macOS will forget the Accessibility permission on every rebuild." >&2
  echo "warning: run scripts/setup-signing.sh once to fix that." >&2
  codesign --force --sign - "$LAUNCHER"
  codesign --force --sign - "$APP"
fi
codesign --verify --strict --deep "$APP"
echo "Built $APP"
