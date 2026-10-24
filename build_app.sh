#!/bin/bash
# Builds the GitHub release of CaptureLens into .build/app/CaptureLens.app, ready for
# ./notarize.sh and ./make_dmg.sh: Developer ID, hardened runtime, not sandboxed (it
# replaces itself when updating).
#
# CaptureLens syncs through CloudKit, which needs a provisioning profile in the app. So this
# archives the app, then exports it for Developer ID with automatic signing: Xcode (signed
# in to the developer account) fetches or renews the Developer ID profile as needed.
#
# The sandboxed App Store build is archived from Xcode instead (configuration AppStore).
set -euo pipefail
cd "$(dirname "$0")"

xcodegen generate >/dev/null
rm -rf .build/xcode-release .build/app .build/CaptureLens.xcarchive .build/export
xcodebuild -project CaptureLens.xcodeproj -scheme CaptureLens -configuration Release \
  -destination 'generic/platform=macOS' -archivePath .build/CaptureLens.xcarchive \
  -derivedDataPath .build/xcode-release -allowProvisioningUpdates archive | grep -E "error:|ARCHIVE" || true
[ -d .build/CaptureLens.xcarchive ] || { echo "Archive failed." >&2; exit 1; }

cat > .build/export-options.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>32CWL275JJ</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath .build/CaptureLens.xcarchive -exportPath .build/export \
  -exportOptionsPlist .build/export-options.plist -allowProvisioningUpdates | grep -E "error:|EXPORT" || true

APP=".build/export/CaptureLens.app"
[ -d "$APP" ] || { echo "Export failed." >&2; exit 1; }
lipo -archs "$APP/Contents/MacOS/CaptureLens" | grep -q "x86_64 arm64\|arm64 x86_64" || { echo "CaptureLens isn't universal." >&2; exit 1; }
ENTITLEMENTS=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)
case "$ENTITLEMENTS" in
  *get-task-allow*) echo "The app carries get-task-allow; notarization would reject it." >&2; exit 1 ;;
esac
# CloudKit only works with the Developer ID profile inside, pointed at Production.
[ -f "$APP/Contents/embedded.provisionprofile" ] || { echo "No provisioning profile in the app; CloudKit won't work." >&2; exit 1; }
# (plutil can't be used here: it reads the dots in the key as a path.)
case "$ENTITLEMENTS" in
  *"<key>com.apple.developer.icloud-container-environment</key><string>Production</string>"*) ;;
  *) echo "The app isn't set to CloudKit's Production environment." >&2; exit 1 ;;
esac
# The GitHub build must stay unsandboxed: the updater replaces the app in place.
case "$ENTITLEMENTS" in
  *"<key>com.apple.security.app-sandbox</key><true/>"*) echo "The GitHub build is sandboxed; its updater wouldn't work." >&2; exit 1 ;;
esac

mkdir -p .build/app
ditto "$APP" .build/app/CaptureLens.app
codesign --verify --deep --strict .build/app/CaptureLens.app
codesign -dvv .build/app/CaptureLens.app 2>&1 | grep -E "^Authority=Developer ID|^Timestamp="
echo "Built .build/app/CaptureLens.app ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' .build/app/CaptureLens.app/Contents/Info.plist))"
