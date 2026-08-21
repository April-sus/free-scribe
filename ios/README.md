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

| | simulator | iPhone 16 Pro |
|---|---|---|
| app at launch | 17.4 MB | **8.6 MB** |
| after loading `tiny.en` | 35.1 MB | **18.9 MB** |

The simulator overstated the cost by nearly double. On the device the smallest model
adds about 10MB, against an extension ceiling historically around 48-60MB — so
**tiny.en fits comfortably**, and the keyboard can transcribe on its own rather than
handing audio to the containing app.

The device also proved the hardware tiering, which the simulator could not: with 7GB
free it chose `base.en`, where the simulator — seeing the host Mac's 492GB — had
chosen the largest model.

Still open: only `tiny.en` has been measured, and the ceiling itself is enforced only
on device, so the figure to watch is the one the keyboard reports rather than the app.

## Next

1. Run the same probe on a device, inside the keyboard rather than the app.
2. If it fits: audio capture in the extension, which needs `RequestsOpenAccess`.
3. If it does not: the keyboard records and the containing app transcribes, through
   a shared app group.
