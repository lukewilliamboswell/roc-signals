#!/bin/sh
# Current engine (platform-web, ReleaseFast host) on the generated gate app.
# Usage: run-cur.sh APPDIR  -> APPDIR/bench.csv
A=$1; B=${2:-cur}; O=${3:-bench}
: > "$A/$O.csv"
for c in mount:0 sparse:5 swap:0; do
  name=${c%%:*}; warm=${c##*:}
  "$A/$B" --host-bench-app --host-bench-name "$name" --host-bench-warmup "$warm" \
    --host-bench-iterations 1 --host-bench-samples 7 --host-entropy-seed 0 \
    "$A/specs/$name.scm" >> "$A/$O.csv" 2>> "$A/$O.err"
done
