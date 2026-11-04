#!/bin/bash
# Paired Node/DOM-double timing under the timing lock. Args: label [extra args]
set -euo pipefail
. /tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/p1bin/env.sh
LABEL=$1; shift
NEW=${NEW_WASM:-$R/new/app.wasm}
CUR=${CUR_WASM:-$R/current/current.wasm}
flock $LOCK bash -c "uptime; node --expose-gc benchmarks/js-framework-benchmark/roc-engine-keyed/test/paired_bench.mjs --current $CUR --new $NEW --json $R/paired-$LABEL.json $*; uptime" > $R/paired-$LABEL.txt 2>&1
