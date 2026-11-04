#!/bin/bash
# Build the pure-Roc-engine jfb artifact into $R/new (or $1).
set -euo pipefail
. /tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/p1bin/env.sh
OUT=${1:-$R/new}
ROC_ENGINE_OUT=$OUT ZIG=zig python3 benchmarks/js-framework-benchmark/roc-engine-keyed/build.py 2>&1 | grep -v '^$' | tail -${TAILN:-40}
ls -la $OUT
