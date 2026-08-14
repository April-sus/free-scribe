# Free Scribe

Wispr Flow's dictation loop, running entirely on your Mac. Hold a shortcut, speak,
release — the text is typed into whatever app you were in. No cloud, no subscription.

Whisper runs through [WhisperKit](https://github.com/argmaxinc/WhisperKit) (CoreML,
Neural Engine). On first launch the app checks the chip and RAM and installs a model
sized to the machine.

## Build and run

```bash
./build.sh && open 'Free Scribe.app'
```

It appears in the menu bar only — no Dock icon. Default shortcut is **⌘⌥D**; change it
in Settings.

Hold the shortcut to talk and release to insert, or tap it once to start and tap again
to stop.

## Dictation styles

Switch from the menu bar icon or Settings:

- **Verbatim** — every word as spoken, "um" and "uh" included. For scribing, where the
  disfluencies are the point and a student still has to do the editing themselves.
- **Clean up fillers** (default) — strips fillers that cannot mean anything else, plus
  repeated words. Pure pattern matching: instant, offline, predictable. Ambiguous words
  are left alone, so "I like coffee" and "you know the answer" survive intact.
- **Polish with AI** — Apple's on-device model also fixes false starts and punctuation.
  Still local and free; needs macOS 26 with Apple Intelligence on, and adds about a
  second. Falls back to Clean up fillers when unavailable.

```
verbatim  hello, uh, what do I need, um, I I think it's, you know, basically the the report for, uh, tomorrow
tidy      Hello, what do I need, I think it's, basically the report for, tomorrow
polished  Hello, what do I need? I think it's basically the report for tomorrow.
```

The AI pass never sees the network, and its output is length-checked before use — if
the model answers the dictation instead of cleaning it, the deterministic result is
pasted instead.

## Permissions

macOS asks for these the first time they are needed:

- **Microphone** — prompted on your first dictation.
- **Accessibility** — needed to press ⌘V in the other app. Grant it in
  System Settings → Privacy & Security → Accessibility. Without it the transcript
  still lands on the clipboard, and the pill says so.

The app is signed with your Apple Development identity, so these grants survive
rebuilds. Without a signing identity `build.sh` falls back to ad-hoc signing and macOS
will ask again after every build.

## Models

Stored in `~/Library/Application Support/WhisperFlow/models` (the folder keeps the original
name so a rename does not orphan a 1.5 GB download) — outside the bundle, so
rebuilding never throws away a download. Settings lets you switch models, delete them,
and pin a language.

Choice on this machine: WhisperKit's own device recommendation, falling back to a RAM
tier (`base.en` under 8 GB, `small.en` under 16 GB, `large-v3-turbo` above) when it has
no entry for the Mac. Intel Macs are capped at `base.en` — no Neural Engine.

## Checks

```bash
swift test
```

Engine path without a microphone:

```bash
say -o /tmp/s.aiff 'the quick brown fox jumps over the lazy dog' && afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/s.aiff /tmp/s.wav && './Free Scribe.app/Contents/MacOS/FreeScribe' --transcribe /tmp/s.wav
```
