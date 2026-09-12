#!/bin/bash
# Type-check one example against the LOCAL platform, in a private scratch dir.
#
# `roc check examples-web/<slug>/main.roc` resolves the *released* platform from
# the roc cache, so it reports errors that do not exist locally. This does the
# same local-platform rewrite as `scripts/test.py roc-check`, focused on one
# example. Its atomically-created scratch directory also permits concurrent
# checks of the same example.
#
# Usage: scripts/dev/check-example.sh <slug>
set -euo pipefail
SLUG="${1:?usage: check-example.sh <slug>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROC="${ROC_BIN:-roc}"
mkdir -p "$ROOT/.test-out"
OUT="$(mktemp -d "$ROOT/.test-out/check-$SLUG.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT

cp -r "$ROOT/examples-web/$SLUG" "$OUT/$SLUG"
PLATFORM="$ROOT/platform-web/main.roc"
find "$OUT/$SLUG" -name '*.roc' -print0 | xargs -0 -r sed -i -E "s|platform \"[^\"]+\"|platform \"$PLATFORM\"|"
"$ROC" check "$OUT/$SLUG/main.roc"
