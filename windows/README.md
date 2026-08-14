# Free Scribe for Windows

```
core/   Portable logic shared with macOS: scribe rules, filler cleanup, stats,
        model tiering. No UI, no audio, no inference — and the whole test suite.
app/    Tauri app: window, global hotkey, WASAPI capture, whisper.cpp, paste.
```

## Getting a build without a toolchain

Easiest route, and the one to use for anyone who is not developing:

Actions → **Windows installer** → latest run → Artifacts → `free-scribe-windows`.
That is an x64 MSI and NSIS installer built on a clean runner. Trigger a fresh one with
`gh workflow run "Windows installer"`, or push a `v*` tag.

The installers are unsigned, so SmartScreen will warn: *More info* → *Run anyway*.
Signing needs a certificate and should happen before any school deployment.

## Building from source

Four prerequisites, each of which fails with an error that does not name itself:

1. **Rust** — <https://rustup.rs>
2. **Visual Studio Build Tools** with the **Desktop development with C++** workload.
   whisper.cpp is C++; without this you get ``linker `link.exe` not found``.
3. **LLVM** — `winget install LLVM.LLVM`, then set `LIBCLANG_PATH` to its `bin`
   folder. `whisper-rs-sys` generates bindings with bindgen, which needs libclang.
   Without it: ``Unable to find libclang``.
4. **CMake** — `winget install Kitware.CMake`. whisper.cpp builds through it.
   Without it: ``failed to execute command: program not found / is `cmake` not
   installed?``

Each of those installers updates the PATH of *new* terminals only, so a tool you just
installed will still look missing in the window you installed it from.

```powershell
cd windows\app
cargo run --release
```

First build takes 10–20 minutes because whisper.cpp compiles from source. After that
it is seconds.

```powershell
cd windows
cargo test
```

## Building on an ARM64 Windows machine

A Windows 11 ARM VM on an Apple Silicon Mac is a good way to *test*, but note that a
native build there produces an ARM64 binary, which will not run on the x64 PCs most
schools have. Ship the CI artifact; use the VM to check behaviour.

Two things bite on ARM64 that do not on x64:

**Build scripts always compile for the host.** `--target x86_64-pc-windows-msvc` alone
is not enough — cargo still needs an ARM64 linker for build scripts. Either install the
`MSVC v143 - VS 2022 C++ ARM64/ARM64EC build tools` component and stay native, or move
the whole host toolchain to x64:

```powershell
rustup toolchain install stable-x86_64-pc-windows-msvc --force-non-host
rustup default stable-x86_64-pc-windows-msvc --force-non-host
```

rustup's warning about the toolchain not running is wrong here; Windows 11 ARM emulates
x64 fine.

**libclang must match the rustc architecture.** With an x64 host toolchain, bindgen runs
as an x64 process and cannot load an ARM64 `libclang.dll`. Install the matching build:

```powershell
winget install LLVM.LLVM --architecture x64
```

## What differs from macOS

Same behaviour where it matters, different machinery underneath:

| | macOS | Windows |
|---|---|---|
| Inference | WhisperKit (CoreML, Neural Engine) | whisper.cpp (GGML) |
| Capture | AVAudioEngine | cpal → WASAPI |
| Paste | `CGEvent` ⌘V, needs Accessibility | `SendInput` Ctrl+V, no permission gate |
| Hotkey | Carbon via KeyboardShortcuts | `tauri-plugin-global-shortcut` |
| UI | SwiftUI | HTML in a WebView |

The **polish** dictation style has no local model here — Apple's on-device model has no
Windows equivalent — so it falls back to the deterministic filler pass. A test pins that
behaviour rather than letting it silently return raw text.

Model tiering is one step more conservative than macOS at the top end, because there is
no Neural Engine to assume and GPU offload cannot be relied on.

Transcript processing must stay identical across platforms. `scripts/parity.sh` diffs
the two real binaries on the same input; `docs/scribe-rules.md` is the contract.
