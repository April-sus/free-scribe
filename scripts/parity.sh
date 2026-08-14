#!/bin/bash
# Diffs the macOS and Windows implementations on identical input. Needs the
# macOS app built (cd macos && ./build.sh) and a Rust toolchain.
set -uo pipefail
cd "$(dirname "$0")/.."
APP="./macos/Free Scribe.app/Contents/MacOS/FreeScribe"
CASES=(
"Hello, um, my name is Sarah. I I want to write about, uh, the beach command comma it was sunny command full stop command new paragraph We swam."
"the capital of france is paris command full stop command capital y o command comma command capital sarah went home"
"It's a well-known fact, you know, that um the the dog ran"
"you put a comma there and a full stop at the end"
"Hello, uh, what do I need, um, today?"
"umm so ahh yeah I I think that that works"
)
fail=0
for c in "${CASES[@]}"; do
  s=$("$APP" --clean "$c" 2>/dev/null | grep -E '^(verbatim|scribe|tidy) ')
  r=$(cd windows && cargo run -q --example clean -- "$c" 2>/dev/null | grep -E '^(verbatim|scribe|tidy) ')
  if [ "$s" = "$r" ]; then
    echo "MATCH   ${c:0:50}"
  else
    fail=1
    echo "DIFFER  ${c:0:50}"
    diff <(echo "$s") <(echo "$r") | sed 's/^/    /'
  fi
done
exit $fail
