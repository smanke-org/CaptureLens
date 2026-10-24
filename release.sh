#!/bin/bash
# Cuts a release: build, notarize, disk image, GitHub release.
#
# This exists so the release is one command rather than four remembered ones. v1.0.3 was
# published by hand without the fixed-name disk image, which silently broke the download
# link in the README for everyone — the kind of step that only gets forgotten once it is
# a step at all.
#
# Usage: ./release.sh [version]
#   With no argument, releases whatever version Resources/Info.plist already carries.
set -euo pipefail

cd "$(dirname "$0")"

# Check the tree before touching anything: setting the version first tripped this guard
# with the script's own edit, which refused every release that passed a version argument.
if [ -n "$(git status --porcelain)" ]; then
  echo "Working tree is dirty. Commit before releasing so the tag matches what shipped." >&2
  exit 1
fi

if [ $# -ge 1 ]; then
  VERSION="$1"
  CURRENT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
  if [ "${VERSION}" != "${CURRENT}" ]; then
    echo "==> Setting version to ${VERSION}"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" \
                            -c "Set :CFBundleVersion ${VERSION}" Resources/Info.plist
    # Commit it, so the tag points at a commit carrying the version that shipped.
    git add Resources/Info.plist
    git commit -q -m "Bump to ${VERSION}"
    git push -q origin HEAD
  fi
else
  VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
fi
TAG="v${VERSION}"

if gh release view "${TAG}" >/dev/null 2>&1; then
  echo "Release ${TAG} already exists. Bump the version first." >&2
  exit 1
fi

./build_app.sh
./notarize.sh
./make_dmg.sh

VERSIONED=".build/app/CaptureLens-${VERSION}.dmg"
STABLE=".build/app/CaptureLens.dmg"
for f in "${VERSIONED}" "${STABLE}"; do
  [ -f "$f" ] || { echo "Missing ${f}." >&2; exit 1; }
done

echo "==> Tagging ${TAG}"
git tag -a "${TAG}" -m "CaptureLens ${VERSION}"
git push origin "${TAG}"

echo "==> Publishing ${TAG}"
# Both assets go up: the version-stamped one to pin to, and the fixed-name one the
# README's permanent download link resolves against.
gh release create "${TAG}" "${VERSIONED}" "${STABLE}" \
  --title "CaptureLens ${VERSION}" \
  --notes "${RELEASE_NOTES:-See the commit history for what changed in ${VERSION}.}"

echo "==> Verifying the permanent download link"
# GitHub takes a moment to point the latest-release redirect at a new asset, so this
# retries rather than reporting a failure that would have resolved on its own.
URL="https://github.com/smanke-org/CaptureLens/releases/latest/download/CaptureLens.dmg"
for attempt in 1 2 3 4 5 6; do
  CODE=$(curl -sL -o /dev/null -w "%{http_code}" "${URL}")
  if [ "${CODE}" = "200" ]; then
    echo "    ${URL} -> 200"
    echo
    echo "Released ${TAG}."
    exit 0
  fi
  echo "    attempt ${attempt}: ${CODE}, waiting..."
  sleep 10
done

echo "The permanent download link is still not resolving (${CODE}). Check the release assets." >&2
exit 1
