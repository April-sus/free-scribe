#!/bin/bash
# Fetches the model that ships inside the app.
#
# Not committed: it is ~145 MB of binaries, and a git history carrying that costs
# every clone and every CI run forever. Downloading it at build time gets the same
# app with a repository people can still clone in a minute.
#
# Only the compiled .mlmodelc folders are taken. The repository also holds an
# .mlpackage copy of each, which CoreML does not need once compiled and which would
# double the size of the app for nothing.
set -euo pipefail

MODEL="${1:-openai_whisper-base.en}"
DESTINATION="$(cd "$(dirname "$0")" && pwd)/Resources/Model"
BASE="https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/main/$MODEL"

# The files a usable model needs. `Transcriber.isComplete` checks for exactly these.
FILES=(
  "config.json"
  "generation_config.json"
  "MelSpectrogram.mlmodelc/coremldata.bin"
  "MelSpectrogram.mlmodelc/metadata.json"
  "MelSpectrogram.mlmodelc/model.mil"
  "MelSpectrogram.mlmodelc/analytics/coremldata.bin"
  "MelSpectrogram.mlmodelc/weights/weight.bin"
  "AudioEncoder.mlmodelc/coremldata.bin"
  "AudioEncoder.mlmodelc/metadata.json"
  "AudioEncoder.mlmodelc/model.mil"
  "AudioEncoder.mlmodelc/model.mlmodel"
  "AudioEncoder.mlmodelc/analytics/coremldata.bin"
  "AudioEncoder.mlmodelc/weights/weight.bin"
  "TextDecoder.mlmodelc/coremldata.bin"
  "TextDecoder.mlmodelc/metadata.json"
  "TextDecoder.mlmodelc/model.mil"
  "TextDecoder.mlmodelc/model.mlmodel"
  "TextDecoder.mlmodelc/analytics/coremldata.bin"
  "TextDecoder.mlmodelc/weights/weight.bin"
)

# The tokenizer lives in OpenAI's own repository, not the CoreML one. Without it
# WhisperKit downloads it at load time — which makes a model that is supposedly
# bundled fail on a phone with no network, quietly, on first use.
TOKENIZER="https://huggingface.co/openai/${MODEL#openai_}/resolve/main"
for file in tokenizer.json tokenizer_config.json config.json; do
  target="$DESTINATION/$file"
  if [ -s "$target" ] && [ "$file" != "config.json" ]; then continue; fi
  # config.json comes from the CoreML repo below; only fetch it here if missing.
  if [ "$file" = "config.json" ] && [ -s "$target" ]; then continue; fi
  mkdir -p "$(dirname "$target")"
  echo "fetching $file"
  curl -fL --retry 3 -o "$target" "$TOKENIZER/$file" || echo "  (not in the tokenizer repo, continuing)"
done

for file in "${FILES[@]}"; do
  target="$DESTINATION/$file"
  # Resumable and skipped when already there, so a second build costs nothing.
  if [ -s "$target" ]; then continue; fi
  mkdir -p "$(dirname "$target")"
  echo "fetching $file"
  curl -fL --retry 3 --continue-at - -o "$target" "$BASE/$file"
done

echo "$MODEL is in $DESTINATION"
