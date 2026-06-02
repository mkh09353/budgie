#!/usr/bin/env bash
# Build Budgie.app - a fully self-contained macOS menu-bar bundle.
#
# The bundle embeds everything needed to run on any Apple-silicon Mac:
#   Contents/MacOS/Budgie           the Swift menu-bar app
#   Contents/Frameworks/Parakeet/   the parakeet.cpp C library + its ggml dylibs
#   Contents/Resources/*.gguf       the standard speech model
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
# The parakeet.cpp checkout and the models live inside the repo (git-ignored —
# see README "Building from source"), so a fresh clone is self-contained.
REPO_ROOT="$(pwd)"
APP_OUTPUT_DIR="${APP_OUTPUT_DIR:-${REPO_ROOT}}"
PARAKEET_BUILD="${PARAKEET_BUILD:-${REPO_ROOT}/ParakeetCpp/build-shared}"
# Both modes run through parakeet.cpp's C library: the standard (non-streaming)
# model is its build of NVIDIA Parakeet TDT 0.6b v3, the streaming model the
# cache-aware EOU RNN-T.
MODEL="${MODEL:-${REPO_ROOT}/models/tdt-0.6b-v3-q4_k.gguf}"
STREAMING_MODEL="${STREAMING_MODEL:-${REPO_ROOT}/models/realtime_eou_120m-v1-q8_0.gguf}"
SIGN_IDENTITY="${SIGN_IDENTITY:-MacBird Development}"

if [[ ! -f "${MODEL}" ]]; then
  echo "Missing standard model: ${MODEL}" >&2
  echo "Run the README's standard model download step first." >&2
  exit 1
fi

if [[ ! -f "${PARAKEET_BUILD}/libparakeet.dylib" ]]; then
  echo "Missing parakeet.cpp library: ${PARAKEET_BUILD}/libparakeet.dylib" >&2
  echo "Run the README's parakeet.cpp build step first." >&2
  exit 1
fi

if [[ ! -f "${STREAMING_MODEL}" ]]; then
  echo "Missing streaming model: ${STREAMING_MODEL}" >&2
  echo "Run the README's Streaming model download step first." >&2
  exit 1
fi

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/budgie-build.XXXXXX")"
trap 'rm -rf "${STAGE}"' EXIT
BUNDLE="${STAGE}/${APP}"

# ---------------------------------------------------------------------------
# 1. Compile the Swift app
# ---------------------------------------------------------------------------
echo "Compiling (release)..."
swift build -c release

# ---------------------------------------------------------------------------
# 2. Assemble the bundle skeleton (in the temp stage)
# ---------------------------------------------------------------------------
echo "Assembling ${APP}..."
MACOS="${BUNDLE}/Contents/MacOS"
FW="${BUNDLE}/Contents/Frameworks"
PKFW="${FW}/Parakeet"
RES="${BUNDLE}/Contents/Resources"
mkdir -p "${MACOS}" "${PKFW}" "${RES}"
ditto .build/release/Budgie "${MACOS}/Budgie"
ditto Info.plist             "${BUNDLE}/Contents/Info.plist"

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

echo "Copying model ($(du -h "${MODEL}" | cut -f1))..."
ditto "${MODEL}" "${RES}/$(basename "${MODEL}")"

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
echo "Signing with '${SIGN_IDENTITY}'..."
xattr -cr "${BUNDLE}"
for f in "${PARAKEET_BUNDLED_DYLIBS[@]}"; do
  codesign --force --sign "${SIGN_IDENTITY}" "$f"
done
codesign --force --sign "${SIGN_IDENTITY}" "${BUNDLE}"

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

echo "Done -> ${DEST_APP}  ($(du -sh "${DEST_APP}" | cut -f1), self-contained)"
echo "Launch it with:  open ${DEST_APP}"
