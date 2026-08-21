#!/bin/bash
# Builds "Free Scribe.app". No Xcode project: SwiftPM builds the binary, we assemble
# the bundle around it, and codesign makes the TCC grants stick across rebuilds.
set -euo pipefail
cd "$(dirname "$0")"

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

CONFIG=${1:-release}
APP="Free Scribe.app"
BIN_NAME="FreeScribe"

# The SwiftPM target keeps its original name; only the shipped bundle is rebranded.
swift build -c "$CONFIG" --product WhisperFlow
BINARY="$(swift build -c "$CONFIG" --show-bin-path)/WhisperFlow"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$BIN_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# The translation sidecar. Built here rather than downloaded, and signed with the
# app below — an unsigned helper inside a signed bundle will not launch.
if [ -d ../translator ]; then
	( cd ../translator && cargo build --release >/dev/null 2>&1 ) \
		&& cp ../translator/target/release/free-scribe-translate "$APP/Contents/MacOS/" \
		&& echo "bundled the translation sidecar" \
		|| echo "translation sidecar not built; translation falls back to Apple's languages"
fi
cp Resources/FreeScribe.icns "$APP/Contents/Resources/FreeScribe.icns"

# MIT and Apache-2.0 require their notices to travel with the binary, so the
# bundle is not complete without this.
../scripts/generate-notices.py macos >/dev/null
cp THIRD-PARTY-NOTICES.txt "$APP/Contents/Resources/"
cp ../LICENSE "$APP/Contents/Resources/"

# Sign with a real identity, not ad-hoc: an ad-hoc signature changes hash on every
# build, so macOS revokes Microphone and Accessibility every time you rebuild.
IDENTITY=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')
if [ -n "$IDENTITY" ]; then
	# --options runtime without the audio-input entitlement means macOS denies the
	# microphone silently and never prompts, so the two must stay together.
	codesign --force --sign "$IDENTITY" --options runtime \
		--entitlements Resources/FreeScribe.entitlements --timestamp=none "$APP"
	echo "signed with $IDENTITY"
else
	codesign --force --sign - --entitlements Resources/FreeScribe.entitlements "$APP"
	echo "no Developer identity found; ad-hoc signed (permissions reset on each rebuild)"
fi

# Finder caches icons aggressively; nudge it so the new one shows immediately.
touch "$APP"

echo "built $APP"
echo
echo "smoke test the engine without a mic:"
echo "  say -o /tmp/s.aiff 'the quick brown fox jumps over the lazy dog' \\"
echo "    && afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/s.aiff /tmp/s.wav \\"
echo "    && './$APP/Contents/MacOS/$BIN_NAME' --transcribe /tmp/s.wav"
