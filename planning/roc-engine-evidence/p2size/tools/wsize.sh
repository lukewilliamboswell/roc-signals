#!/bin/sh
# Usage: wsize.sh DIR...  -- wasm-opt -Oz each DIR/app.wasm and print raw, -Oz and gzip -9 sizes
for d in "$@"; do
  timeout 900 wasm-opt -Oz --all-features "$d/app.wasm" -o "$d/app.oz.wasm" 2>&1 | tail -2
  echo "$d raw=$(stat -c%s "$d/app.wasm") oz=$(stat -c%s "$d/app.oz.wasm") gz=$(gzip -9c "$d/app.oz.wasm" | wc -c) rawgz=$(gzip -9c "$d/app.wasm" | wc -c)"
done
