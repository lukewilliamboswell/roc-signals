#!/bin/bash
# wsize.sh IN.wasm LABEL -- wasm-opt -Oz, print raw / -Oz / gzip -9 sizes
IN=$1; L=$2
OUT=${IN%.wasm}.oz.wasm
wasm-opt -Oz --all-features "$IN" -o "$OUT" || exit 1
echo "$L raw=$(stat -c %s "$IN") oz=$(stat -c %s "$OUT") oz_gz=$(gzip -9 -c "$OUT" | wc -c)"
