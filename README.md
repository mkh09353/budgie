# Budgie

A tiny macOS menu-bar app for push-to-talk dictation.

**Hold the push-to-talk key** (Right ⌘ by default) to record, **release** to
transcribe. The text is typed into whatever app has focus — or copied to the
clipboard, your choice in Settings. Runs fully offline on parakeet.cpp's C
library by default: Live mode types words as you speak via the cache-aware
Parakeet EOU model bundled in the app. Optional Punctuated mode waits until you
release the key, then transcribes the finished recording with the larger NVIDIA
Parakeet TDT 0.6b model, downloading it on first use.

## Building from source

This repo holds **only the Budgie app**. The build embeds two things too large
for git -- the parakeet.cpp C library and the Live-mode EOU GGUF model -- so a
fresh clone needs them set up once. The larger Punctuated-mode model is not
bundled; Budgie downloads and caches it in Application Support if the user turns
Punctuated mode on.

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
└── models/                   ← step 3  (git-ignored)
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
Sparkle is resolved through Swift Package Manager and embedded as
`Contents/Frameworks/Sparkle.framework`.
Metal is intentionally off for now: the current parakeet.cpp/ggml Metal backend
transcribes correctly, but can assert during process teardown on this machine.

### 3. Download the Live model

```sh
mkdir -p models
curl -L -o models/realtime_eou_120m-v1-q8_0.gguf \
  https://huggingface.co/mudler/parakeet-cpp-gguf/resolve/main/realtime_eou_120m-v1-q8_0.gguf
```

This produces `models/realtime_eou_120m-v1-q8_0.gguf`, the q8_0 cache-aware
streaming RNN-T model used by default in **Settings... -> General -> Live
mode**. The C streaming API expects 16 kHz mono float PCM; Budgie resamples the
microphone tap before feeding chunks to parakeet.cpp.

### 4. Build the app

```sh
APP_OUTPUT_DIR=/Applications ./build.sh
open /Applications/Budgie.app
```

Produces a `Budgie.app` with the parakeet.cpp C library and the Live EOU model
bundled inside, with library paths rewritten to `@rpath`, so Live mode runs on
any Apple-silicon Mac with nothing else installed. Requires macOS 14+ and the
Swift toolchain (Xcode CLT) to build.

`build.sh` signs the bundle with the `MacBird Development` keychain identity by
default. On a machine without that identity, sign ad-hoc instead:

```sh
SIGN_IDENTITY=- ./build.sh
```

Ad-hoc signing works fine for a personal build; it just re-prompts the macOS
privacy permissions on each rebuild. See *Sharing it* below for distribution.

## Distributing it (notarized DMG)

For a download-and-double-click experience with **no Gatekeeper warning**, build
with a **Developer ID Application** certificate, notarize, and ship a stapled
DMG. `build.sh` auto-enables the hardened runtime + secure timestamp for a
Developer ID identity (`Budgie.entitlements` declares the microphone use the
hardened runtime would otherwise block); `release.sh` does the notarize → staple
→ DMG round-trip, then signs the DMG for Sparkle and generates `appcast.xml`.

### One-time setup

1. **Create the Developer ID Application certificate.** This is a distinct cert
   type from the "Apple Development" cert used for local builds — it is *not*
   created automatically by enrolling. Without Xcode installed, use the portal:

   - In **Keychain Access -> Certificate Assistant -> Request a Certificate From
     a Certificate Authority**, enter your email, choose **Saved to disk**, and
     save the `.certSigningRequest`.
   - At <https://developer.apple.com/account/resources/certificates> click **+**,
     pick **Developer ID Application**, upload the CSR, download the `.cer`, and
     double-click it to install. Confirm it landed:

     ```sh
     security find-identity -v -p codesigning   # shows "Developer ID Application: … (TEAMID)"
     ```

2. **Store notarization credentials** (an app-specific password from
   <https://appleid.apple.com> -> Sign-In and Security -> App-Specific Passwords):

   ```sh
   xcrun notarytool store-credentials budgie-notary \
     --apple-id you@example.com --team-id TEAMID --password APP_SPECIFIC_PW
   ```

3. **Keep the Sparkle signing key safe.** Budgie trusts the public key already
   committed in `Info.plist`; the matching private key is stored in this Mac's
   login Keychain under account `com.maxheadley.Budgie`. Export an encrypted
   backup with Sparkle's `generate_keys -x` command and keep it outside the
   repository. On a different release Mac, import that same key with `-f`;
   never generate a replacement key for an existing install base.

### Each release

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh
./release.sh
./publish-release.sh
```

This produces a notarized, stapled `Budgie-<version>.dmg` and a signed
`appcast.xml`. `publish-release.sh` creates the matching GitHub Release and
uploads both files. Installed copies read the feed through the release's stable
`latest/download/appcast.xml` URL and can download and install future releases
automatically.

Bump both `CFBundleShortVersionString` and the monotonically increasing
`CFBundleVersion` in `Info.plist` before every release. Sparkle uses the build
number to decide whether an update is newer. The first release containing
Sparkle must still be installed manually; automatic updating starts with the
release after that.

### Local / ad-hoc builds (no Developer ID)

Building with the default `MacBird Development` identity, or ad-hoc
(`SIGN_IDENTITY=- ./build.sh`), still works for personal use but is **not**
notarized, so other Macs show "can't verify the developer." To open such a build
the first time: right-click the app -> **Open** and confirm, or run
`xattr -dr com.apple.quarantine Budgie.app` before launching.

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

`Sources/Budgie/Config.swift` resolves the parakeet.cpp library from
`Contents/Frameworks/Parakeet/libparakeet.dylib` and the bundled Live model from
`Contents/Resources/realtime_eou_120m-v1-q8_0.gguf`. Punctuated mode uses
`tdt-0.6b-v3-q4_k.gguf`, downloading it from Hugging Face into
`~/Library/Application Support/Budgie/Models/` on first use. When run outside a
bundle -- e.g. via `swift run` during development -- it can also use matching
files in the repo's `models/` directory.

## Notes

- The selected engine loads its model once and keeps it resident, so each
  dictation is just a transcribe call through the parakeet.cpp C library. The
  model is unloaded after 5 minutes idle to reclaim its memory; re-warming
  `mmap`s the GGUF, so it costs only a fraction of a second.
- Punctuated mode's first use needs a network connection to download the larger
  model. Live mode remains active while the download runs, and after that
  Punctuated mode runs offline from the Application Support cache.
- Recordings shorter than 0.3 s are ignored (accidental key taps).
