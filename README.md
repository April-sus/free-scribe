# Free Scribe

Dictation that runs entirely on your own machine. Hold a shortcut, speak, release —
the text is typed into whatever app you were in. No cloud, no subscription, and
nothing you say leaves the device.

Built around OpenAI's Whisper models running locally. On first launch the app checks
the hardware and installs a model sized to it.

## Why it exists

Cloud dictation is a subscription and a privacy question. Neither is comfortable for a
school putting dictation on student machines, which is also why Free Scribe includes a
**scribe mode** following the NAPLAN/NESA rules for the Writing test — word for word,
lower case, and no punctuation the student did not dictate.

## Layout

```
core/      Swift package both Apple apps share: scribe rules, cleanup, history.
macos/     Swift + SwiftUI app. Whisper via WhisperKit (CoreML, Neural Engine).
ios/       iPhone app + keyboard extension, on the same core.
windows/   Tauri app. Whisper via whisper.cpp.
docs/      Rules and behaviour both platforms must agree on.
```

The two apps are separate on purpose: each uses its platform's fastest local inference
path rather than a lowest-common-denominator one. What must not diverge is the
transcript processing — the scribe rules especially — so that logic is ported
deliberately, with the same test cases on both sides.

## macOS

You need macOS 14 or newer (Apple Silicon recommended) and **Xcode** installed in
`/Applications`. The Command Line Tools on their own are not enough, because the build
uses Xcode's toolchain.

```bash
git clone https://github.com/April-sus/free-scribe.git
cd free-scribe/macos
./build.sh
open 'Free Scribe.app'
```

`build.sh` compiles with SwiftPM, assembles `Free Scribe.app` and signs it.

- **Signing:** if Xcode is signed in to an Apple ID (Xcode → Settings → Accounts), the
  app is signed with your Apple Development certificate. Microphone and Accessibility
  grants then survive rebuilds. Without one it is ad-hoc signed and macOS asks again
  after every build.
- **Translation (optional):** if [Rust](https://rustup.rs) is installed, the build also
  compiles the offline translation sidecar. Without it, translation falls back to
  Apple's built-in languages.
- **First launch:** a speech model sized to your Mac downloads (75 MB–1.5 GB).

The app sits in the menu bar with no Dock icon. The default shortcut is **⌘⌥D**: hold
to talk and release to insert, or tap once to start and again to stop. Everything is
set up in the app's own window rather than a native settings panel, so the same layout
can be rebuilt on Windows.

It needs the Microphone (you're asked on your first dictation) and Accessibility
(System Settings → Privacy & Security → Accessibility). Without Accessibility the
transcript is copied instead of typed.

After pulling changes, run `./build.sh` again and reopen the app. The new build
replaces the copy that's already running.

See [macos/README.md](macos/README.md) for dictation styles, models and checks.

## iOS

An iPhone app plus a Free Scribe keyboard. You dictate from the keyboard in any app,
or with the Action button. Building it needs Xcode 16+, XcodeGen and an iPhone on
iOS 18+:

```bash
brew install xcodegen
cd free-scribe/ios
./fetch-model.sh        # the ~145 MB model bundled inside the app
xcodegen generate
open FreeScribe.xcodeproj   # FreeScribe scheme, your iPhone, ⌘R
```

Building under your own Apple account means changing the signing team and IDs first.
[ios/README.md](ios/README.md) has the full walkthrough, including that, installing
from the terminal and first-run setup.

## Windows

Tauri (Rust core, web UI) with whisper.cpp, so the interface matches macOS rather than
being rebuilt per platform.

Installers are built by CI — Actions → **Windows installer** → latest run → Artifacts.
See [windows/README.md](windows/README.md) to build from source.

## Licence

MIT — see [LICENSE](LICENSE). Free to use, modify and redistribute, including
commercially.

`THIRD-PARTY-NOTICES.txt` is generated at build time by `scripts/generate-notices.py`
from the real dependency graph and ships inside both apps, which is what MIT and
Apache-2.0 require. CI fails if a dependency arrives under a licence outside
`windows/deny.toml`.

## Checks

```bash
cd core && swift test     # shared logic, both Apple apps
cd macos && swift test
```

CI runs the macOS tests and builds the bundle on every push, and will run the Windows
test suite once that half exists.
