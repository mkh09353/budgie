#!/usr/bin/env bash
# Notarize Budgie.app and package it into a distributable, stapled DMG.
#
# Prerequisites (one-time setup — see README "Distributing it"):
#   1. A "Developer ID Application" certificate in your login keychain.
#   2. The app built WITH that identity, e.g.
#        SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh
#      build.sh auto-enables the hardened runtime + timestamp for Developer ID.
#   3. A stored notarytool credential profile (default name: budgie-notary):
#        xcrun notarytool store-credentials budgie-notary \
#          --apple-id you@example.com --team-id TEAMID
#
# Result: Budgie-<version>.dmg plus a signed appcast.xml. Upload both to the
# matching GitHub Release so installed copies can update through Sparkle.
set -euo pipefail
cd "$(dirname "$0")"

REPO_ROOT="$(pwd)"
SRC_APP="${APP_PATH:-Budgie.app}"
NOTARY_PROFILE="${NOTARY_PROFILE:-budgie-notary}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-com.maxheadley.Budgie}"
GENERATE_APPCAST="${GENERATE_APPCAST:-.build/artifacts/sparkle/Sparkle/bin/generate_appcast}"
GENERATE_KEYS="${GENERATE_KEYS:-.build/artifacts/sparkle/Sparkle/bin/generate_keys}"

if [[ ! -d "${SRC_APP}" ]]; then
  echo "No ${SRC_APP} found. Build it first with a Developer ID identity:" >&2
  echo "  SIGN_IDENTITY=\"Developer ID Application: ... (TEAMID)\" ./build.sh" >&2
  exit 1
fi
if [[ ! -x "${GENERATE_APPCAST}" || ! -x "${GENERATE_KEYS}" ]]; then
  echo "Sparkle's release tools are unavailable under .build/artifacts." >&2
  echo "Run 'swift package resolve' first." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Work from a copy OUTSIDE the (iCloud-synced) repo. The fileprovider keeps
# re-stamping com.apple.FinderInfo onto the bundle faster than it can be
# cleared in place, which makes codesign --verify and the notary service reject
# it as "resource fork ... detritus not allowed". In a plain temp dir the
# xattr clear sticks.
# ---------------------------------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/budgie-release.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
APP="${WORK}/Budgie.app"
ditto "${SRC_APP}" "${APP}"
xattr -cr "${APP}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP}/Contents/Info.plist" 2>/dev/null || echo 1.0)"
DMG="Budgie-${VERSION}.dmg"
EXPECTED_PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "${APP}/Contents/Info.plist")"
KEYCHAIN_PUBLIC_KEY="$("${GENERATE_KEYS}" --account "${SPARKLE_ACCOUNT}" -p)"
if [[ "${KEYCHAIN_PUBLIC_KEY}" != "${EXPECTED_PUBLIC_KEY}" ]]; then
  echo "Sparkle key '${SPARKLE_ACCOUNT}' does not match the app's SUPublicEDKey." >&2
  echo "Import the original private key before releasing this build." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 0. Sanity checks — fail loudly before the (slow) notary round-trip
# ---------------------------------------------------------------------------
SIG="$(codesign -dvvv "${APP}" 2>&1)"
if ! grep -q 'flags=.*runtime' <<<"${SIG}"; then
  echo "${SRC_APP} is not signed with the hardened runtime." >&2
  echo "Rebuild with a Developer ID identity (see above)." >&2
  exit 1
fi
if grep -q 'TeamIdentifier=not set' <<<"${SIG}"; then
  echo "${SRC_APP} is signed with a local cert (no Team ID), not a Developer ID." >&2
  echo "Rebuild with a Developer ID identity (see above)." >&2
  exit 1
fi
if ! xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1; then
  echo "No notarytool credential profile '${NOTARY_PROFILE}' found. Create one:" >&2
  echo "  xcrun notarytool store-credentials ${NOTARY_PROFILE} \\" >&2
  echo "    --apple-id you@example.com --team-id D5TLPTV9F4" >&2
  exit 1
fi

# Confirm the cleaned copy verifies before we ship it to Apple.
codesign --verify --deep --strict "${APP}"

# ---------------------------------------------------------------------------
# 1. Submit a zip of the app to Apple's notary service and wait for the verdict
# ---------------------------------------------------------------------------
ZIP="${WORK}/Budgie.zip"
ditto -c -k --keepParent "${APP}" "${ZIP}"
echo "Submitting to Apple notary service (this can take a few minutes)..."
xcrun notarytool submit "${ZIP}" --keychain-profile "${NOTARY_PROFILE}" --wait

# ---------------------------------------------------------------------------
# 2. Staple the ticket into the app so it verifies offline, then re-check
# ---------------------------------------------------------------------------
echo "Stapling..."
xcrun stapler staple "${APP}"
xcrun stapler validate "${APP}"
spctl --assess --type execute --verbose=2 "${APP}"   # what Gatekeeper runs on launch

# ---------------------------------------------------------------------------
# 3. Build a drag-to-install DMG from the stapled app
# ---------------------------------------------------------------------------
echo "Building ${DMG}..."
DMG_SRC="${WORK}/dmg"
mkdir -p "${DMG_SRC}"
ditto "${APP}" "${DMG_SRC}/Budgie.app"
ln -s /Applications "${DMG_SRC}/Applications"   # drag-to-Applications affordance
rm -f "${DMG}"
hdiutil create -volname "Budgie" -srcfolder "${DMG_SRC}" \
  -fs HFS+ -format UDZO -ov "${DMG}" >/dev/null

# ---------------------------------------------------------------------------
# 4. Sign the update archive and generate the Sparkle feed
# ---------------------------------------------------------------------------
APPCAST_SRC="${WORK}/appcast"
mkdir -p "${APPCAST_SRC}"
ditto "${DMG}" "${APPCAST_SRC}/${DMG}"
"${GENERATE_APPCAST}" \
  --account "${SPARKLE_ACCOUNT}" \
  --download-url-prefix "https://github.com/mkh09353/budgie/releases/download/v${VERSION}/" \
  --link "https://github.com/mkh09353/budgie/releases/tag/v${VERSION}" \
  -o "${REPO_ROOT}/appcast.xml" \
  "${APPCAST_SRC}"

echo "Done -> ${DMG}  ($(du -h "${DMG}" | cut -f1), notarized + stapled)"
echo "Done -> appcast.xml  (signed for Sparkle)"
echo "Run ./publish-release.sh to publish both files."
