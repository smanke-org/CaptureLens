#!/bin/bash
# Captures a Finder window layout for a DMG as a .DS_Store fixture.
# Usage: capture_layout.sh <app path> <volume name> <output .DS_Store>
set -euo pipefail
APP="$1"; VOL="$2"; OUT="$3"
NAME="$(basename "$APP")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

diskutil image create blank --size 200m --format UDRW --volumeName "$VOL" --fs APFS "$WORK/rw.dmg" >/dev/null
diskutil image attach "$WORK/rw.dmg" --mountOptions nobrowse >/dev/null
sleep 2
ditto "$APP" "/Volumes/$VOL/$NAME"
ln -s /Applications "/Volumes/$VOL/Applications"

osascript >/dev/null <<EOF
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set position of item "$NAME" of container window to {150, 185}
    set position of item "Applications" of container window to {450, 185}
    set the bounds of container window to {120, 120, 720, 548}
    update without registering applications
    delay 2
    close
  end tell
end tell
EOF
sleep 2
cp "/Volumes/$VOL/.DS_Store" "$OUT"
diskutil image detach "/Volumes/$VOL" >/dev/null 2>&1 || hdiutil detach "/Volumes/$VOL" -force >/dev/null 2>&1
echo "captured $(basename "$OUT") ($(stat -f %z "$OUT") bytes) for $VOL"
