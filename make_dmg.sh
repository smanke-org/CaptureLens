#!/bin/bash
# Builds a distributable .dmg containing the app, with the usual
# drag-to-Applications layout.
#
# Run ./build_app.sh and ./notarize.sh first: the app inside should already
# carry a stapled notarization ticket, otherwise anyone who downloads the
# image gets a Gatekeeper block on first launch. This script then signs,
# notarizes and staples the .dmg itself, so the download is clean too.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="CaptureLens"
APP_DIR=".build/app/${APP_NAME}.app"
VERSION=$(defaults read "$(pwd)/${APP_DIR}/Contents/Info.plist" CFBundleShortVersionString)
DMG_PATH=".build/app/CaptureLens-${VERSION}.dmg"
# Notarization credentials are account-level, not per-app, so an existing
# profile from another project works fine. Use the first one that answers.
resolve_profile() {
  for candidate in "${NOTARY_PROFILE:-}" "CaptureLens" "StayMounted" "NetworkToggle" "DesktopBinsWidget" "DesktopBins"; do
    [ -z "${candidate}" ] && continue
    if xcrun notarytool history --keychain-profile "${candidate}" >/dev/null 2>&1; then
      echo "${candidate}"
      return 0
    fi
  done
  return 1
}

PROFILE=$(resolve_profile || echo "")

if [ ! -d "${APP_DIR}" ]; then
  echo "No app bundle at ${APP_DIR} — run ./build_app.sh first."
  exit 1
fi

# Warn rather than fail: a DMG of an unstapled app is still useful locally.
if ! xcrun stapler validate "${APP_DIR}" >/dev/null 2>&1; then
  echo "WARNING: the app has no stapled notarization ticket."
  echo "         Run ./notarize.sh first, or downloads will be blocked by Gatekeeper."
fi

SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "${SIGN_IDENTITY}" ]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -n 1 | sed -E 's/.*"(.*)".*/\1/' || true)
fi

echo "Staging disk image contents..."
STAGING=$(mktemp -d)
trap 'rm -rf "${STAGING}"' EXIT
cp -R "${APP_DIR}" "${STAGING}/"
# The familiar drag-the-app-onto-Applications install gesture.
ln -s /Applications "${STAGING}/Applications"

# The window layout — 600x400, 128px icons, app on the left and Applications on the
# right — ships as a captured .DS_Store rather than by driving Finder at release time.
# Finder scripting is too unreliable to sit in a release path (on macOS 27 it silently
# ignores a background picture set that way), and a fixture makes every build identical.
# Recapture with Tools/capture_dmg_layout.sh if the window should change.
[ -f "Resources/dmg/DS_Store" ] && cp "Resources/dmg/DS_Store" "${STAGING}/.DS_Store"

echo "Creating ${DMG_PATH}..."
rm -f "${DMG_PATH}"
# LZFSE (ULFO), not zlib (UDZO): on macOS 27.0.1 hdiutil writes a corrupt zlib image of
# this HFS+ volume, which notarytool then refuses as "not a disk image". LZFSE images open
# on every macOS CaptureLens runs on.
hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${STAGING}" \
  -fs HFS+ \
  -format ULFO \
  -ov \
  "${DMG_PATH}" >/dev/null
if ! hdiutil imageinfo "${DMG_PATH}" 2>/dev/null | grep -q "Format Description"; then
  echo "The disk image came out unreadable; not signing or publishing it." >&2
  exit 1
fi

if [ -n "${SIGN_IDENTITY}" ]; then
  echo "Signing the disk image with: ${SIGN_IDENTITY}"
  codesign --force --sign "${SIGN_IDENTITY}" "${DMG_PATH}"

  if xcrun notarytool history --keychain-profile "${PROFILE}" >/dev/null 2>&1; then
    echo "Notarizing the disk image (a few minutes)..."
    xcrun notarytool submit "${DMG_PATH}" --keychain-profile "${PROFILE}" --wait
    xcrun stapler staple "${DMG_PATH}"
  else
    echo "No notarization profile '${PROFILE}' — skipping notarization of the image."
  fi
else
  echo "WARNING: no Developer ID identity found; the image is unsigned."
fi

# A second copy under a name that never changes. The README's download link uses
# GitHub's releases/latest/download/<name> redirect, which can only resolve against an
# asset whose name is identical in every release — ship only the version-stamped one and
# that link 404s for everybody. Copied after notarization so it carries the same stapled
# ticket; it is byte-identical, so it does not matter which the updater picks up.
STABLE_PATH=".build/app/CaptureLens.dmg"
cp "${DMG_PATH}" "${STABLE_PATH}"

echo
echo "Verifying..."
spctl -a -t open --context context:primary-signature -vv "${DMG_PATH}" 2>&1 || true
ls -lh "${DMG_PATH}" | awk '{print "Size: "$5}'
echo "Done: ${DMG_PATH}"
echo "      ${STABLE_PATH} (same image, fixed name for the permanent download link)"
