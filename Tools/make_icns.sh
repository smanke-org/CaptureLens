#!/bin/bash
# Builds Resources/AppIcon.icns from the two variants Tools/generate_icon.swift draws:
# the full tile (with the name) for 128pt and up, and the nameless one for 16-64pt,
# where the name would be an unreadable smudge.
set -euo pipefail
cd "$(dirname "$0")/.."

swift Tools/generate_icon.swift

SET="Resources/AppIcon.iconset"
rm -rf "$SET"; mkdir -p "$SET"
# zsh would not word-split these; bash with explicit parameter expansion is safe.
for spec in "16 icon_16x16 small" "32 icon_16x16@2x small" "32 icon_32x32 small" "64 icon_32x32@2x small" \
            "128 icon_128x128 full" "256 icon_128x128@2x full" "256 icon_256x256 full" "512 icon_256x256@2x full" \
            "512 icon_512x512 full" "1024 icon_512x512@2x full"; do
  read -r px name variant <<< "$spec"
  src="Resources/AppIcon.png"; [ "$variant" = "small" ] && src="Resources/AppIcon-small.png"
  sips -z "$px" "$px" "$src" --out "$SET/$name.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
rm -rf "$SET"
echo "Wrote Resources/AppIcon.icns"
