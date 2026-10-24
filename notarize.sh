#!/bin/bash
# Submits the built app to Apple for notarization, then staples the ticket
# so it launches cleanly on other Macs without a Gatekeeper warning.
#
# One-time setup (run this yourself — it needs your app-specific password,
# created at https://account.apple.com under App-Specific Passwords):
#
#   xcrun notarytool store-credentials "CaptureLens" \
#     --apple-id "<your-apple-id>" \
#     --team-id "32CWL275JJ"
#
# It will prompt for the app-specific password and save everything to the
# keychain, so this script never handles the password itself.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="CaptureLens"
APP_DIR=".build/app/${APP_NAME}.app"
ZIP_PATH=".build/app/CaptureLens-notarize.zip"
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

if [ -z "${PROFILE}" ]; then
  echo "No stored notarization credentials found."
  echo "Run the store-credentials command in the header of this script first."
  exit 1
fi

# Notarization rejects anything signed without a secure timestamp.
# Note: no `grep -q` here — it exits on the first match, which SIGPIPEs
# codesign, and under `set -o pipefail` that reads as a failed check even
# when the timestamp is present.
TIMESTAMP_LINE=$(codesign -dvv "${APP_DIR}" 2>&1 | grep "^Timestamp=" || true)
if [ -z "${TIMESTAMP_LINE}" ]; then
  echo "Signature has no secure timestamp. Re-run ./build_app.sh (it signs with --timestamp)."
  exit 1
fi
echo "Secure ${TIMESTAMP_LINE}"

echo "Zipping bundle for submission..."
rm -f "${ZIP_PATH}"
# ditto preserves the bundle structure and symlinks; plain zip does not.
ditto -c -k --keepParent "${APP_DIR}" "${ZIP_PATH}"

echo "Submitting to Apple (this usually takes a few minutes)..."
xcrun notarytool submit "${ZIP_PATH}" --keychain-profile "${PROFILE}" --wait

echo "Stapling the ticket to the app..."
xcrun stapler staple "${APP_DIR}"

echo "Verifying with Gatekeeper..."
spctl -a -vv "${APP_DIR}"

echo
echo "Done. Reinstall the stapled build:"
echo "  cp -R \"${APP_DIR}\" /Applications/"
echo
echo "To share it, zip the stapled bundle — the ticket travels with it:"
echo "  ditto -c -k --keepParent \"${APP_DIR}\" \"~/Desktop/${APP_NAME}.zip\""
