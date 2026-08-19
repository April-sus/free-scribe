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
macos/     Swift + SwiftUI app. Whisper via WhisperKit (CoreML, Neural Engine).
windows/   Tauri app. Whisper via whisper.cpp.
docs/      Rules and behaviour both platforms must agree on.
```

The two apps are separate on purpose: each uses its platform's fastest local inference
path rather than a lowest-common-denominator one. What must not diverge is the
transcript processing — the scribe rules especially — so that logic is ported
deliberately, with the same test cases on both sides.

## macOS

```bash
cd macos && ./build.sh && open 'Free Scribe.app'
```

Menu bar only, no Dock icon. Default shortcut **⌘⌥D**. Everything is configured in the
app's own window rather than a native settings panel, so the same layout can be rebuilt
on Windows.

Needs Microphone (prompted) and Accessibility (granted in System Settings — without it
the transcript is copied instead of typed).

See [macos/README.md](macos/README.md) for dictation styles, models and checks.

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
cd macos && swift test
```

CI runs the macOS tests and builds the bundle on every push, and will run the Windows
test suite once that half exists.
