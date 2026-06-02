# Budgie

A tiny macOS menu-bar app for push-to-talk dictation.

**Hold the push-to-talk key** (Right ⌘ by default) to record, **release** to
transcribe. The text is typed into whatever app has focus — or copied to the
clipboard, your choice in Settings. Runs fully offline on parakeet.cpp's C
library: standard mode transcribes each finished recording with the NVIDIA
Parakeet TDT 0.6b model (punctuation and capitalization included), and an
optional Streaming mode types words live as you speak via the cache-aware
Parakeet EOU model -- no Python, no network at runtime.

## Building from source

This repo holds **only the Budgie app**. The build embeds three things too large
for git -- the parakeet.cpp C library, the standard Parakeet TDT GGUF model and
the Streaming EOU GGUF model -- so a fresh clone needs them set up once. They
live *inside* the repo folder and are git-ignored, so once set up everything is
self-contained.

### 1. Clone

```sh
git clone https://github.com/mkh09353/budgie.git
cd budgie
```

The setup steps below are run from inside this `budgie/` folder, producing:

```
budgie/
├── Sources/, build.sh, ...   ← the repo (tracked)
├── ParakeetCpp/              ← step 2  (git-ignored)
└── models/                   ← steps 3-4  (git-ignored)
```

### 2. Build the parakeet.cpp C library

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

This produces `ParakeetCpp/build-shared/libparakeet.dylib`, which both modes
load through the flat C API in `include/parakeet_capi.h`. `build.sh` copies all
parakeet.cpp dylibs into `Contents/Frameworks/Parakeet/`.
Metal is intentionally off for now: the current parakeet.cpp/ggml Metal backend
transcribes correctly, but can assert during process teardown on this machine.

### 3. Download the standard model

```sh
mkdir -p models
curl -L -o models/tdt-0.6b-v3-q4_k.gguf \
  https://huggingface.co/mudler/parakeet-cpp-gguf/resolve/main/tdt-0.6b-v3-q4_k.gguf
```

That's parakeet.cpp's q4_k build of [NVIDIA Parakeet TDT 0.6b
v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), used for standard
(non-streaming) dictation — it keeps the model's punctuation and capitalization.
Note this is parakeet.cpp's own GGUF, not a CrispASR/whisper.cpp one, which
won't load. To use a different model or quant, change the filename here, in
`build.sh`, and the resource name in `Config.swift`.

### 4. Download the Streaming model

```sh
curl -L -o models/realtime_eou_120m-v1-q8_0.gguf \
  https://huggingface.co/mudler/parakeet-cpp-gguf/resolve/main/realtime_eou_120m-v1-q8_0.gguf
```

This produces `models/realtime_eou_120m-v1-q8_0.gguf`, the q8_0 cache-aware
streaming RNN-T model used when **Settings... -> General -> Streaming mode** is
enabled. The C streaming API expects 16 kHz mono float PCM; Budgie resamples the
microphone tap before feeding chunks to parakeet.cpp.

### 5. Build the app

```sh
APP_OUTPUT_DIR=/Applications ./build.sh
open /Applications/Budgie.app
```

Produces a **self-contained** `Budgie.app` -- the parakeet.cpp C library, the
standard speech model and the Streaming EOU model are all bundled inside, with
library paths rewritten to `@rpath`, so the app runs on any Apple-silicon Mac
with nothing else installed. Requires macOS 14+ and the Swift toolchain (Xcode
CLT) to build.

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

`Sources/Budgie/Config.swift` resolves the library and models from inside the
app bundle at runtime (`Contents/Frameworks/Parakeet/libparakeet.dylib`, the
bundled `tdt-0.6b-v3-q4_k.gguf` for standard mode and
`realtime_eou_120m-v1-q8_0.gguf` for Streaming mode). When run outside a
bundle -- e.g. via `swift run` during development -- it falls back to the
build-tree copies in this repo. To change models or quant, edit the model list
in `build.sh` (and the resource names in `Config.swift`) and rebuild.

## Notes

- The selected engine loads its model once at launch and keeps it resident, so
  each dictation is just a transcribe call through the parakeet.cpp C library.
  The model is unloaded after 5 minutes idle to reclaim its memory; re-warming
  `mmap`s the GGUF, so it costs only a fraction of a second.
- Recordings shorter than 0.3 s are ignored (accidental key taps).
