# Free Scribe for iOS

An app plus a keyboard. iOS does not let an app extension record audio, so the
**app** holds the microphone and runs Whisper, and the **keyboard** tells it when to
start and stop and types back what comes out. The Action button can start dictation
too. Everything runs on the phone; nothing is sent anywhere.

The transcript processing (scribe rules, filler cleanup, history, vocabulary) is the
shared `core/` package, the same code the Mac app uses.

## What you need

- A Mac with **Xcode 16 or newer** (iOS 18 SDK)
- **XcodeGen**, which generates the Xcode project from `project.yml`:
  ```bash
  brew install xcodegen
  ```
- An **iPhone on iOS 18 or newer** with Developer Mode on
  (Settings → Privacy & Security → Developer Mode)
- An Apple ID signed in to Xcode (Xcode → Settings → Accounts). A free account works;
  its apps expire after 7 days and have to be reinstalled.

## Build and install

### 1. Fetch the bundled model

The app ships with `base.en` inside it (~145 MB) so dictation works with no download.
It is not in the repository:

```bash
cd ios
./fetch-model.sh
```

Safe to run again; files already there are skipped.

### 2. Use your own signing team and IDs

Skip this if you are building on the original developer's account.

Bundle and App Group IDs are unique across all of Apple, so yours must differ.
In `ios/project.yml`, change:

| Setting | Change to |
|---|---|
| `DEVELOPMENT_TEAM: RDDHPR73MC` | your Team ID (Xcode → Settings → Accounts → your team) |
| `bundleIdPrefix: local.freescribe` | something of yours, e.g. `com.yourname.freescribe` |
| `PRODUCT_BUNDLE_IDENTIFIER: local.freescribe.FreeScribe.Keyboard` | `<your prefix>.FreeScribe.Keyboard` |
| `group.local.freescribe.shared` (both targets) | `group.<your prefix>.shared` |

Then set the same App Group in `core/Sources/WhisperFlowCore/Transcriber.swift`:

```swift
public static let appGroup = "group.<your prefix>.shared"
```

The app and the keyboard share the model and history through that group. If the
two don't match, the keyboard can't see anything the app writes.

### 3. Generate the project

```bash
xcodegen generate
```

Run this again whenever `project.yml` changes or files are added. The generated
`FreeScribe.xcodeproj` is not committed.

### 4. Run it on the phone

**From Xcode:** open `FreeScribe.xcodeproj`, pick the **FreeScribe** scheme and
your iPhone as the destination, and press ⌘R. Xcode creates the provisioning profiles
on the first build.

**From the terminal:**

```bash
xcrun devicectl list devices          # find your phone's identifier
xcodebuild -project FreeScribe.xcodeproj -scheme FreeScribe \
  -destination 'platform=iOS,id=<device-id>' \
  -allowProvisioningUpdates -derivedDataPath build build
xcrun devicectl device install app --device <device-id> \
  build/Build/Products/Debug-iphoneos/FreeScribe.app
```

On a free account, the first launch is blocked until you trust the developer:
Settings → General → VPN & Device Management → your Apple ID → Trust.

If an install fails with "unable to locate device", unlock the phone and run
`xcrun devicectl device info details --device <device-id>` first. That wakes the
developer disk image, then retry.

### 5. First run

The app walks you through setup:

1. Allow the microphone.
2. Add the keyboard: Settings → General → Keyboard → Keyboards → Add New Keyboard →
   **Free Scribe**.
3. Turn on **Allow Full Access** on the same screen. The keyboard needs it to read
   transcripts from the app's shared storage. It has no network code, so nothing
   leaves the phone.
4. Try a practice dictation.

To use the Action button: Settings → Action Button → Shortcut → **Free Scribe**.

## Using it

Switch to the Free Scribe keyboard (🌐) and tap the microphone. The first time, the
keyboard opens the app so it can take the microphone. After that the app keeps
listening in the background, and later taps dictate without leaving the app you're
typing in.

If the audio route changes mid-session (AirPods removed, say), the app moves to
whichever microphone is left. If iOS won't allow that from the background, the
keyboard shows "not ready", and the next tap brings the app forward to reopen it.

## Checks

```bash
cd ../core && swift test
```

Settings → Debug mode in the app shows live state and the log. The log is also
written to the shared container, so the keyboard's side shows up there too.
