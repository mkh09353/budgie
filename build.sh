#!/usr/bin/env bash
# Build Budgie.app - a fully self-contained macOS menu-bar bundle.
#
# The bundle embeds everything needed to run on any Apple-silicon Mac:
#   Contents/MacOS/Budgie           the Swift menu-bar app
#   Contents/MacOS/crispasr         the ASR engine binary
#   Contents/Frameworks/*.dylib     the engine's shared libraries
#   Contents/Resources/*.gguf       the standard speech model (~488 MB)
#   Contents/Resources/nemotron_coreml_560ms/
#                                      the streaming Core ML model
#
# The engine binary and its dylibs are built with absolute rpaths pointing at
# the build tree; this script rewrites them to @executable_path / @loader_path
# so they resolve relative to the bundle on any machine.
#
# The bundle is assembled and signed in a temp dir, not in place: this project
# lives in an iCloud-synced Documents folder, and the fileprovider re-stamps
# com.apple.FinderInfo onto the bundle faster than it can be cleared, which
# makes codesign refuse it ("resource fork ... detritus not allowed").
set -euo pipefail
cd "$(dirname "$0")"

APP="Budgie.app"
# The engine checkout and the model live inside the repo (git-ignored — see
# README "Building from source"), so a fresh clone is self-contained.
REPO_ROOT="$(pwd)"
CRISP_BUILD="${CRISP_BUILD:-${REPO_ROOT}/CrispASR/build}"
MODEL="${MODEL:-${REPO_ROOT}/models/parakeet-tdt-0.6b-v3-q4_k.gguf}"
STREAMING_MODEL="${STREAMING_MODEL:-${REPO_ROOT}/models/nemotron_coreml_560ms}"
SIGN_IDENTITY="${SIGN_IDENTITY:-MacBird Development}"

if [[ ! -f "${MODEL}" ]]; then
  echo "Missing standard model: ${MODEL}" >&2
  echo "Run the README's standard model download step first." >&2
  exit 1
fi

if [[ ! -d "${STREAMING_MODEL}" ]]; then
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
RES="${BUNDLE}/Contents/Resources"
mkdir -p "${MACOS}" "${FW}" "${RES}"
ditto .build/release/Budgie "${MACOS}/Budgie"
ditto Info.plist             "${BUNDLE}/Contents/Info.plist"

# ---------------------------------------------------------------------------
# 3. Copy the engine binary, its dylibs and the model into the bundle
# ---------------------------------------------------------------------------
ditto "${CRISP_BUILD}/bin/crispasr" "${MACOS}/crispasr"

# Real dylib files (the versioned ones the symlinks point at).
DYLIBS=(
  "${CRISP_BUILD}/src/libcrispasr.0.6.6.dylib"
  "${CRISP_BUILD}/ggml/src/libggml.0.10.2.dylib"
  "${CRISP_BUILD}/ggml/src/libggml-cpu.0.10.2.dylib"
  "${CRISP_BUILD}/ggml/src/libggml-base.0.10.2.dylib"
  "${CRISP_BUILD}/ggml/src/ggml-blas/libggml-blas.0.10.2.dylib"
  "${CRISP_BUILD}/ggml/src/ggml-metal/libggml-metal.0.10.2.dylib"
)
for d in "${DYLIBS[@]}"; do
  ditto "$d" "${FW}/$(basename "$d")"
done

# Recreate the version symlinks flat inside Frameworks/ so the @rpath install
# names (libcrispasr.1.dylib, libggml.0.dylib, ...) resolve.
( cd "${FW}"
  ln -sf libcrispasr.0.6.6.dylib    libcrispasr.1.dylib
  ln -sf libcrispasr.1.dylib        libcrispasr.dylib
  ln -sf libcrispasr.0.6.6.dylib    libwhisper.dylib
  ln -sf libggml.0.10.2.dylib       libggml.0.dylib
  ln -sf libggml.0.dylib            libggml.dylib
  ln -sf libggml-cpu.0.10.2.dylib   libggml-cpu.0.dylib
  ln -sf libggml-cpu.0.dylib        libggml-cpu.dylib
  ln -sf libggml-base.0.10.2.dylib  libggml-base.0.dylib
  ln -sf libggml-base.0.dylib       libggml-base.dylib
  ln -sf libggml-blas.0.10.2.dylib  libggml-blas.0.dylib
  ln -sf libggml-blas.0.dylib       libggml-blas.dylib
  ln -sf libggml-metal.0.10.2.dylib libggml-metal.0.dylib
  ln -sf libggml-metal.0.dylib      libggml-metal.dylib
)

echo "Copying model ($(du -h "${MODEL}" | cut -f1))..."
ditto "${MODEL}" "${RES}/$(basename "${MODEL}")"

echo "Copying streaming model ($(du -sh "${STREAMING_MODEL}" | cut -f1))..."
ditto "${STREAMING_MODEL}" "${RES}/nemotron_coreml_560ms"

# ---------------------------------------------------------------------------
# 4. Rewrite rpaths so the engine finds its dylibs inside the bundle
# ---------------------------------------------------------------------------
# Strip every existing (absolute, build-tree) LC_RPATH from a Mach-O file.
strip_rpaths() {
  local file="$1" rp
  while otool -l "$file" | grep -q LC_RPATH; do
    rp=$(otool -l "$file" | awk '/LC_RPATH/{getline;getline;print $2;exit}')
    install_name_tool -delete_rpath "$rp" "$file" 2>/dev/null || break
  done
}

echo "Rewriting rpaths..."
# crispasr lives in MacOS/, its dylibs one level over in Frameworks/.
chmod u+w "${MACOS}/crispasr"
strip_rpaths "${MACOS}/crispasr"
install_name_tool -add_rpath "@executable_path/../Frameworks" "${MACOS}/crispasr"

# Each dylib is loaded from Frameworks/ and references its siblings via
# @rpath/...; @loader_path points at the dir holding the loading dylib.
for d in "${DYLIBS[@]}"; do
  f="${FW}/$(basename "$d")"
  chmod u+w "$f"
  strip_rpaths "$f"
  install_name_tool -add_rpath "@loader_path" "$f"
done

# ---------------------------------------------------------------------------
# 5. Sign — nested Mach-O files first, then the bundle.
# ---------------------------------------------------------------------------
# A stable keychain identity keeps macOS privacy permissions (Input Monitoring
# / Accessibility) across rebuilds; ad-hoc signing re-pins them every build.
echo "Signing with '${SIGN_IDENTITY}'..."
xattr -cr "${BUNDLE}"
for d in "${DYLIBS[@]}"; do
  codesign --force --sign "${SIGN_IDENTITY}" "${FW}/$(basename "$d")"
done
codesign --force --sign "${SIGN_IDENTITY}" "${MACOS}/crispasr"
codesign --force --sign "${SIGN_IDENTITY}" "${BUNDLE}"

echo "Verifying..."
codesign --verify --deep --strict "${BUNDLE}"

# ---------------------------------------------------------------------------
# 6. Move the finished, signed bundle into place
# ---------------------------------------------------------------------------
rm -rf "${APP}"
ditto "${BUNDLE}" "${APP}"

echo "Done -> $(pwd)/${APP}  ($(du -sh "${APP}" | cut -f1), self-contained)"
echo "Launch it with:  open ${APP}"
