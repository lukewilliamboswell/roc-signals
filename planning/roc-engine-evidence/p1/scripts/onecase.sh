#!/bin/bash
# Run one paired case in its own process with a timeout. Args: case iterations warmups [lock]
. /tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/p1bin/env.sh
C=$1; N=${2:-1}; WU=${3:-0}
CMD="timeout ${TMO:-600} node --expose-gc --max-old-space-size=4096 benchmarks/js-framework-benchmark/roc-engine-keyed/test/paired_bench.mjs --current $R/current/current.wasm --new ${NEW_WASM:-$R/new/app.wasm} --iterations $N --warmups $WU --case $C --json $R/case-$C.json"
if [ "$4" = lock ]; then
  flock $LOCK bash -c "$CMD"
else
  $CMD
fi
echo "exit=$?"
