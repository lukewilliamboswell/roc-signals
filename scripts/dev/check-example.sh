#!/bin/bash
# Type-check one example against the LOCAL platform, in a private scratch dir.
#
# `roc check examples/<slug>/main.roc` resolves the *released* platform from the
# roc cache, so it reports errors that do not exist locally. `scripts/test.py
# roc-check` rewrites the header first but shares one `.test-out/` directory,
# so parallel runs clobber each other. This does the same rewrite into a dir
# keyed by slug, which makes it safe to run several at once.
#
# Usage: scripts/dev/check-example.sh <slug>
set -euo pipefail
SLUG="${1:?usage: check-example.sh <slug>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROC="${ROC_BIN:-roc}"
OUT="$ROOT/.test-out/check-$SLUG"

rm -rf "$OUT"
mkdir -p "$OUT"
cp -r "$ROOT/examples/$SLUG" "$OUT/$SLUG"
PLATFORM="$ROOT/platform/main.roc"
find "$OUT/$SLUG" -name '*.roc' -print0 | xargs -0 -r sed -i -E "s|platform \"[^\"]+\"|platform \"$PLATFORM\"|"
"$ROC" check "$OUT/$SLUG/main.roc"
