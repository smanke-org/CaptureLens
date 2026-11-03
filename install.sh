#!/bin/bash
# Installs the built app to /Applications and launches it.
#
# Screen Recording is granted to the copy in /Applications, so test from there.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/.build/app/SnagAnything.app"
DEST="/Applications/SnagAnything.app"

[ -d "$SRC" ] || { echo "Run ./build_app.sh first." >&2; exit 1; }

pkill -x CaptureLens 2>/dev/null || true
pkill -x SnagAnything 2>/dev/null || true

if [ -d "$DEST" ]; then
  # Update in place, so the Screen Recording grant keeps pointing at the same bundle.
  rsync -a --delete "$SRC/" "$DEST/"
else
  cp -R "$SRC" "$DEST"
fi

# The command line tool: the app's own binary under a short name (see Agent/AgentCLI.swift).
mkdir -p "$HOME/.local/bin"
ln -sf "$DEST/Contents/MacOS/SnagAnything" "$HOME/.local/bin/snag"

open "$DEST"
echo "Installed $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist")"
