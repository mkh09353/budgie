# Budgie

A tiny macOS menu-bar app for push-to-talk dictation.

**Hold the push-to-talk key** (Right ⌘ by default) to record, **release** to
transcribe. The text is typed into whatever app has focus — or copied to the
clipboard, your choice in Settings. Runs fully offline on the CrispASR
(Parakeet) engine by default, with an optional Streaming mode powered by
parakeet.cpp's C library and the cache-aware Parakeet EOU GGUF model -- no
Python, no network at runtime.

## Building from source

This repo holds **only the Budgie app**. The build embeds four things too large
for git -- the CrispASR speech engine, the parakeet.cpp C library, the standard
Parakeet GGUF model and the Streaming EOU GGUF model -- so a fresh clone needs
them set up once. They live *inside* the repo folder and are git-ignored, so
once set up everything is self-contained.

### 1. Clone

```sh
git clone https://github.com/mkh09353/budgie.git
cd budgie
```

The setup steps below are run from inside this `budgie/` folder, producing:

```
budgie/
├── Sources/, build.sh, ...   ← the repo (tracked)
├── CrispASR/                 ← step 2  (git-ignored)
├── ParakeetCpp/              ← step 3  (git-ignored)
└── models/                   ← steps 4-5  (git-ignored)
```

### 2. Build the CrispASR engine

```sh
git clone https://github.com/CrispStrobe/CrispASR.git
cd CrispASR
cmake -B build -DCMAKE_BUILD_TYPE=Release -DGGML_METAL=ON
cmake --build build -j$(sysctl -n hw.ncpu)
cd ..
```

This produces `CrispASR/build/bin/crispasr` and the `libggml*` / `libcrispasr`
dylibs that `build.sh` copies into the bundle. Needs CMake 3.14+ and a C++17
compiler (Xcode Command Line Tools). CrispASR is its own git repo nested here
— git ignores the whole `CrispASR/` folder, so there's no submodule to manage.

### 3. Build the parakeet.cpp C library

```sh
git clone --recursive https://github.com/mudler/parakeet.cpp.git ParakeetCpp
cd ParakeetCpp
cmake -B build-shared \
  -DCMAKE_BUILD_TYPE=Release \
  -DPARAKEET_SHARED=ON \
  -DPARAKEET_BUILD_CLI=ON \
  -DPARAKEET_GGML_METAL=OFF
cmake --build build-shared -j$(sysctl -n hw.ncpu)
cd ..
```

This produces `ParakeetCpp/build-shared/libparakeet.dylib`, which Streaming
mode loads through the flat C API in `include/parakeet_capi.h`. `build.sh`
copies all parakeet.cpp dylibs into `Contents/Frameworks/Parakeet/`.
Metal is intentionally off for now: the current parakeet.cpp/ggml Metal backend
transcribes correctly, but can assert during process teardown on this machine.

### 4. Download the standard model

```sh
mkdir -p models
curl -L -o models/parakeet-tdt-0.6b-v3-q4_k.gguf \
  https://huggingface.co/cstr/parakeet-tdt-0.6b-v3-GGUF/resolve/main/parakeet-tdt-0.6b-v3-q4_k.gguf
```

That's a ~466 MB quantised [NVIDIA Parakeet
TDT](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) GGUF. To use a
different model or quant, change the filename here, in `build.sh`, and the
resource name in `Config.swift`.

### 5. Download the Streaming model

```sh
curl -L -o models/realtime_eou_120m-v1-q8_0.gguf \
  https://huggingface.co/mudler/parakeet-cpp-gguf/resolve/main/realtime_eou_120m-v1-q8_0.gguf
```

This produces `models/realtime_eou_120m-v1-q8_0.gguf`, the q8_0 cache-aware
streaming RNN-T model used when **Settings... -> General -> Streaming mode** is
enabled. The C streaming API expects 16 kHz mono float PCM; Budgie resamples the
microphone tap before feeding chunks to parakeet.cpp.

### 6. Build the app

```sh
APP_OUTPUT_DIR=/Applications ./build.sh
open /Applications/Budgie.app
```

Produces a **self-contained** `Budgie.app` -- the `crispasr` engine, its
dylibs, the parakeet.cpp C library, the standard speech model and the Streaming
EOU model are all bundled inside, with library paths rewritten to
`@executable_path`, so the app runs on any Apple-silicon Mac with nothing else
installed. Requires macOS 14+ and the Swift toolchain (Xcode CLT) to build.

`build.sh` signs the bundle with the `MacBird Development` keychain identity by
default. On a machine without that identity, sign ad-hoc instead:

```sh
SIGN_IDENTITY=- ./build.sh
```

Ad-hoc signing works fine for a personal build; it just re-prompts the macOS
privacy permissions on each rebuild. See *Sharing it* below for distribution.

## Sharing it

The app is signed with a local development identity, so on another Mac macOS
shows a "can't verify the developer" warning. To open it the first time:

- **Right-click the app -> Open**, then confirm; or
- run `xattr -dr com.apple.quarantine Budgie.app` before launching.

For double-click-clean distribution with no warning you'd need a paid Apple
Developer account ($99/yr) to sign with a "Developer ID" certificate and
notarize the bundle.

## First launch — grant three permissions

Budgie appears as a bird icon in the menu bar. Click it and open
**Settings… -> Permissions** — the tab shows each permission's live status
with a button to the matching System Settings pane:

1. **Microphone** — prompted automatically on first recording.
2. **Input Monitoring** — to see the push-to-talk key.
3. **Accessibility** — to type the transcript at the cursor.

The Input Monitoring event tap is created at startup; Budgie retries it when
it next becomes active, so a relaunch usually isn't needed after granting.

## Menu bar UI

The icon is a small live instrument:

| Icon | Meaning |
|------|---------|
| bird                  | idle, ready |
| live level bars (red) | recording — bar heights track your voice |
| animated dots         | transcribing |
| warning triangle      | permission missing |

Clicking the icon opens a popover showing the push-to-talk key, engine
warmth, words dictated today, and your recent transcriptions (click any to
copy it). **Settings…** opens a sectioned preferences window: General,
Hotkey, Permissions and About.

## Configuration

`Sources/Budgie/Config.swift` resolves the engine, libraries and models from
inside the app bundle at runtime (`Contents/MacOS/crispasr`,
`Contents/Frameworks/Parakeet/libparakeet.dylib`, the bundled
`parakeet-tdt-0.6b-v3-q4_k.gguf` and
`realtime_eou_120m-v1-q8_0.gguf` for Streaming mode). When run outside a
bundle -- e.g. via `swift run` during development -- it falls back to the
build-tree copies in this repo. To change models or quant, edit the dylib/model
list in `build.sh` (and the resource names in `Config.swift`) and rebuild.

## Notes

- A warm `crispasr --server` process keeps the model resident, so each
  dictation is just an HTTP round-trip. The server starts at launch and is
  torn down after 5 minutes idle to reclaim ~700 MB; re-warming costs only
  ~0.3 s (the engine `mmap`s the model), so the teardown is effectively free.
- Recordings shorter than 0.3 s are ignored (accidental key taps).
