#!/usr/bin/env bash
# Publish the notarized DMG and signed Sparkle appcast produced by release.sh.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
TAG="v${VERSION}"
DMG="Budgie-${VERSION}.dmg"
APPCAST="appcast.xml"

if [[ ! -f "${DMG}" || ! -f "${APPCAST}" ]]; then
  echo "Missing ${DMG} or ${APPCAST}. Run ./release.sh first." >&2
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "GitHub CLI is not authenticated. Run 'gh auth login' first." >&2
  exit 1
fi
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Tracked source changes are not committed; refusing to tag a different build." >&2
  echo "Commit the release version and code, then run this script again." >&2
  exit 1
fi
if gh release view "${TAG}" >/dev/null 2>&1; then
  echo "Release ${TAG} already exists; refusing to replace its update files." >&2
  echo "Bump CFBundleShortVersionString and CFBundleVersion, then rebuild." >&2
  exit 1
fi

gh release create "${TAG}" "${DMG}" "${APPCAST}" \
  --title "Budgie ${VERSION}" \
  --generate-notes \
  --target "$(git rev-parse HEAD)"

echo "Published ${TAG} with ${DMG} and ${APPCAST}."
