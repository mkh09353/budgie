#!/usr/bin/env bash
# Build Budgie.app - a macOS menu-bar bundle with self-contained Live mode.
#
# The bundle embeds everything needed to run on any Apple-silicon Mac:
#   Contents/MacOS/Budgie           the Swift menu-bar app
#   Contents/Frameworks/Sparkle.framework
#   Contents/Frameworks/Parakeet/   the parakeet.cpp C library + its ggml dylibs
#   Contents/Resources/*.gguf       the streaming speech model
#
# parakeet.cpp's dylibs are built with absolute rpaths pointing at the build
# tree; this script rewrites them to @rpath / @loader_path so they resolve
# relative to the bundle on any machine.
#
# The bundle is assembled and signed in a temp dir, not in place: this project
# lives in an iCloud-synced Documents folder, and the fileprovider re-stamps
# com.apple.FinderInfo onto the bundle faster than it can be cleared, which
# makes codesign refuse it ("resource fork ... detritus not allowed").
set -euo pipefail
cd "$(dirname "$0")"

APP="Budgie.app"
# The parakeet.cpp checkout and the streaming model live inside the repo (git-ignored —
# see README "Building from source"), so a fresh clone can package Streaming
# mode after setup.
REPO_ROOT="$(pwd)"
APP_OUTPUT_DIR="${APP_OUTPUT_DIR:-${REPO_ROOT}}"
PARAKEET_BUILD="${PARAKEET_BUILD:-${REPO_ROOT}/ParakeetCpp/build-shared}"
STREAMING_MODEL="${STREAMING_MODEL:-${REPO_ROOT}/models/realtime_eou_120m-v1-q8_0.gguf}"
ICON="${ICON:-${REPO_ROOT}/Budgie.icns}"
SIGN_IDENTITY="${SIGN_IDENTITY:-MacBird Development}"
ENTITLEMENTS="${ENTITLEMENTS:-${REPO_ROOT}/Budgie.entitlements}"
SWIFT_SCRATCH_PATH="${SWIFT_SCRATCH_PATH:-}"

# Notarization requires the hardened runtime, a secure timestamp, and the
# audio-input entitlement. Auto-enable these for a "Developer ID" identity;
# leave local (MacBird Development) and ad-hoc (-) builds untouched so their
# privacy-permission behaviour doesn't change. Override with HARDENED=1 / 0.
HARDENED="${HARDENED:-auto}"
if [[ "${HARDENED}" == "auto" ]]; then
  case "${SIGN_IDENTITY}" in
    "Developer ID"*) HARDENED=1 ;;
    *) HARDENED=0 ;;
  esac
fi

if [[ ! -f "${PARAKEET_BUILD}/libparakeet.dylib" ]]; then
  echo "Missing parakeet.cpp library: ${PARAKEET_BUILD}/libparakeet.dylib" >&2
  echo "Run the README's parakeet.cpp build step first." >&2
  exit 1
fi

if [[ ! -f "${STREAMING_MODEL}" ]]; then
  echo "Missing streaming model: ${STREAMING_MODEL}" >&2
  echo "Run the README's Live model download step first." >&2
  exit 1
fi

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/budgie-build.XXXXXX")"
trap 'rm -rf "${STAGE}"' EXIT
BUNDLE="${STAGE}/${APP}"

# ---------------------------------------------------------------------------
# 1. Compile the Swift app
# ---------------------------------------------------------------------------
echo "Compiling (release)..."
SWIFT_BUILD_ARGS=(-c release)
if [[ -n "${SWIFT_SCRATCH_PATH}" ]]; then
  SWIFT_BUILD_ARGS+=(--scratch-path "${SWIFT_SCRATCH_PATH}")
fi
SWIFT_PRODUCTS="$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)"
swift build "${SWIFT_BUILD_ARGS[@]}"
SPARKLE_FRAMEWORK="${SPARKLE_FRAMEWORK:-${SWIFT_PRODUCTS}/Sparkle.framework}"
if [[ ! -d "${SPARKLE_FRAMEWORK}" ]]; then
  echo "Missing Sparkle framework: ${SPARKLE_FRAMEWORK}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. Assemble the bundle skeleton (in the temp stage)
# ---------------------------------------------------------------------------
echo "Assembling ${APP}..."
MACOS="${BUNDLE}/Contents/MacOS"
FW="${BUNDLE}/Contents/Frameworks"
PKFW="${FW}/Parakeet"
RES="${BUNDLE}/Contents/Resources"
mkdir -p "${MACOS}" "${PKFW}" "${RES}"
ditto "${SWIFT_PRODUCTS}/Budgie" "${MACOS}/Budgie"
ditto "${SPARKLE_FRAMEWORK}" "${FW}/Sparkle.framework"
ditto Info.plist             "${BUNDLE}/Contents/Info.plist"
# App icon (CFBundleIconFile -> Budgie.icns). Optional so a fresh clone without
# the generated icns still builds; regenerate it with tools/make-icon.swift.
if [[ -f "${ICON}" ]]; then
  ditto "${ICON}" "${RES}/Budgie.icns"
else
  echo "Note: ${ICON} not found — app will use the generic icon." >&2
fi

# ---------------------------------------------------------------------------
# 3. Copy the parakeet.cpp library, its dylibs and the models into the bundle
# ---------------------------------------------------------------------------
PARAKEET_DYLIBS=()
while IFS= read -r d; do
  PARAKEET_DYLIBS+=("$d")
done < <(find "${PARAKEET_BUILD}" -name '*.dylib' \( -type f -o -type l \) | sort)

if [[ ${#PARAKEET_DYLIBS[@]} -eq 0 ]]; then
  echo "No parakeet.cpp dylibs found in ${PARAKEET_BUILD}" >&2
  exit 1
fi

PARAKEET_BUNDLED_DYLIBS=()
PARAKEET_BUNDLED_DYLIB_REFS=()
for d in "${PARAKEET_DYLIBS[@]}"; do
  target="${PKFW}/$(basename "$d")"
  if [[ -L "$d" ]]; then
    link_target="$(readlink "$d")"
    if [[ "$link_target" == /* ]]; then
      link_target="$(basename "$link_target")"
    fi
    ln -sf "$link_target" "$target"
  else
    ditto "$d" "$target"
    PARAKEET_BUNDLED_DYLIBS+=("$target")
  fi
  PARAKEET_BUNDLED_DYLIB_REFS+=("$target")
done

echo "Copying streaming model ($(du -h "${STREAMING_MODEL}" | cut -f1))..."
ditto "${STREAMING_MODEL}" "${RES}/$(basename "${STREAMING_MODEL}")"

# ---------------------------------------------------------------------------
# 4. Rewrite rpaths so the library finds its dylibs inside the bundle
# ---------------------------------------------------------------------------
# Strip every existing (absolute, build-tree) LC_RPATH from a Mach-O file.
strip_rpaths() {
  local file="$1" rp
  while otool -l "$file" | grep -q LC_RPATH; do
    rp=$(otool -l "$file" | awk '/LC_RPATH/{getline;getline;print $2;exit}')
    install_name_tool -delete_rpath "$rp" "$file" 2>/dev/null || break
  done
}

rewrite_local_dylib_refs() {
  local file="$1" dep base linked
  shift
  for dep in "$@"; do
    base="$(basename "$dep")"
    while IFS= read -r linked; do
      if [[ "$(basename "$linked")" == "$base" &&
            "$linked" != @* &&
            "$linked" != /usr/lib/* &&
            "$linked" != /System/* ]]; then
        install_name_tool -change "$linked" "@rpath/$base" "$file" 2>/dev/null || true
      fi
    done < <(otool -L "$file" | awk 'NR > 1 { print $1 }')
  done
}

echo "Rewriting rpaths..."
# SwiftPM places Sparkle.framework next to the command-line build product.
# The app bundle stores it in Contents/Frameworks, so teach the executable
# where to resolve its @rpath/Sparkle.framework load command after packaging.
chmod u+w "${MACOS}/Budgie"
if ! otool -l "${MACOS}/Budgie" |
    awk '/LC_RPATH/{getline; getline; print $2}' |
    grep -qx '@executable_path/../Frameworks'; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "${MACOS}/Budgie"
fi

# Each parakeet.cpp dylib is loaded from Frameworks/Parakeet/ and references its
# siblings via @rpath/...; @loader_path points at the dir holding the dylib.
for f in "${PARAKEET_BUNDLED_DYLIBS[@]}"; do
  chmod u+w "$f"
  strip_rpaths "$f"
  install_name_tool -id "@rpath/$(basename "$f")" "$f" 2>/dev/null || true
  install_name_tool -add_rpath "@loader_path" "$f"
done
for f in "${PARAKEET_BUNDLED_DYLIBS[@]}"; do
  rewrite_local_dylib_refs "$f" "${PARAKEET_BUNDLED_DYLIB_REFS[@]}"
done

# ---------------------------------------------------------------------------
# 5. Sign — nested Mach-O files first, then the bundle.
# ---------------------------------------------------------------------------
# A stable keychain identity keeps macOS privacy permissions (Input Monitoring
# / Accessibility) across rebuilds; ad-hoc signing re-pins them every build.
# The main bundle gets the entitlements; nested dylibs are signed bare. When
# hardened, both also get --options runtime and a --timestamp (notarization
# rejects un-timestamped or non-hardened code).
BUNDLE_SIGN_OPTS=(--force --sign "${SIGN_IDENTITY}")
DYLIB_SIGN_OPTS=(--force --sign "${SIGN_IDENTITY}")
SPARKLE_SIGN_OPTS=(
  --force
  --sign "${SIGN_IDENTITY}"
  --preserve-metadata=identifier,entitlements,flags
)
if [[ "${HARDENED}" == "1" ]]; then
  if [[ ! -f "${ENTITLEMENTS}" ]]; then
    echo "Missing entitlements file: ${ENTITLEMENTS}" >&2
    exit 1
  fi
  BUNDLE_SIGN_OPTS+=(--options runtime --timestamp --entitlements "${ENTITLEMENTS}")
  DYLIB_SIGN_OPTS+=(--options runtime --timestamp)
  SPARKLE_SIGN_OPTS+=(--timestamp)
  echo "Signing with '${SIGN_IDENTITY}' (hardened runtime, timestamped)..."
else
  echo "Signing with '${SIGN_IDENTITY}'..."
fi
xattr -cr "${BUNDLE}"
for f in "${PARAKEET_BUNDLED_DYLIBS[@]}"; do
  codesign "${DYLIB_SIGN_OPTS[@]}" "$f"
done
SPARKLE="${FW}/Sparkle.framework/Versions/B"
SPARKLE_NESTED_CODE=(
  "${SPARKLE}/Autoupdate"
  "${SPARKLE}/XPCServices/Downloader.xpc"
  "${SPARKLE}/XPCServices/Installer.xpc"
  "${SPARKLE}/Updater.app"
)
for target in "${SPARKLE_NESTED_CODE[@]}"; do
  codesign "${SPARKLE_SIGN_OPTS[@]}" "${target}"
done
codesign "${SPARKLE_SIGN_OPTS[@]}" "${FW}/Sparkle.framework"
codesign "${BUNDLE_SIGN_OPTS[@]}" "${BUNDLE}"

echo "Verifying..."
codesign --verify --deep --strict "${BUNDLE}"

# ---------------------------------------------------------------------------
# 6. Move the finished, signed bundle into place
# ---------------------------------------------------------------------------
mkdir -p "${APP_OUTPUT_DIR}"
DEST_APP="${APP_OUTPUT_DIR}/${APP}"
rm -rf "${DEST_APP}"
ditto "${BUNDLE}" "${DEST_APP}"

# If the destination is iCloud-synced, FinderInfo/provenance xattrs can appear
# after the temp-stage signature check. Clear what can be cleared and verify the
# final app that will actually be launched.
xattr -cr "${DEST_APP}" 2>/dev/null || true
echo "Verifying final bundle..."
codesign --verify --deep --strict "${DEST_APP}"

echo "Done -> ${DEST_APP}  ($(du -sh "${DEST_APP}" | cut -f1), Live-ready)"
echo "Launch it with:  open ${DEST_APP}"
