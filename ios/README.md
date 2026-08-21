# Free Scribe for iOS

Not a port of the desktop app. Two of its central decisions cannot exist here:

- **No global shortcut.** iOS has no system-wide hotkey, and no app may type into
  another app's text field. The only mechanism that can is a **keyboard extension**,
  which is why the app is shaped around one.
- **No child processes.** The translation sidecar both desktop builds use cannot run
  in the iOS sandbox, and MADLAD at 2.8GB is not a phone download in any case.

What does carry over is `core/` — the NAPLAN scribe rules, filler cleanup, history,
search, statistics and model selection — which is why that package was separated out
and why CI builds it for iOS on every push.

## The measurement everything depends on

A keyboard extension is given far less memory than an app, and the ceiling is not
documented. Whether WhisperKit can load inside one decides the architecture:

- **If it fits** — the keyboard transcribes directly, and dictation works the moment
  you switch to it.
- **If it does not** — the keyboard records and hands the audio to the containing app
  through a shared app group, which is slower and more fragile.

`memory-probe/` exists to answer that before anything is built on top of it.

## What the probe found

Measured in the iPhone 17 Pro simulator, iOS 26.5:

| | footprint |
|---|---|
| app at launch | 17.4 MB |
| after loading `tiny.en` | 35.1 MB |

So the smallest model costs about 18MB. Keyboard extensions have historically been
held to roughly 48-60MB, which means **tiny.en plausibly fits inside one** — the
keyboard could transcribe directly rather than handing audio to the containing app.

Two things that figure does not settle:

- **The simulator does not enforce an extension's memory limit**, and it reports the
  host Mac's hardware rather than a phone's: this run claimed 48GB of memory and
  492GB free, so it chose the largest model. Both the ceiling and the hardware
  tiering need a real device.
- Only `tiny.en` was measured. `base.en` is roughly twice the weights and may not fit.

## Next

1. Run the same probe on a device, inside the keyboard rather than the app.
2. If it fits: audio capture in the extension, which needs `RequestsOpenAccess`.
3. If it does not: the keyboard records and the containing app transcribes, through
   a shared app group.
