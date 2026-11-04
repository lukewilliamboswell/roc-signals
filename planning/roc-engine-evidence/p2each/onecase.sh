#!/bin/bash
# One paired case in its own Node process. Args: case iterations warmups [lock] [extra...]
S=/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad
R=$S/spike-results/roc-engine
D=$R/p2each
W=/home/lbw/Documents/Github/roc-signals/.claude/worktrees/agent-a65a650fdc810bc91
LOCK=$S/spike-results/timing.lock
C=$1; N=${2:-1}; WU=${3:-0}; L=$4; shift 4 2>/dev/null
mkdir -p $D/results
cd $W
CMD="timeout ${TMO:-900} node --expose-gc --max-old-space-size=4096 benchmarks/js-framework-benchmark/roc-d-keyed/test/paired3.mjs --current $R/p1/current/current.wasm --p1 $R/p1/new/app.wasm --p1-runtime $R/p1/new/runtime.mjs --p2 ${P2_WASM:-$D/out/jfb/app.wasm} --p2-runtime ${P2_RT:-$D/out/jfb/runtime.mjs} --iterations $N --warmups $WU --case $C --json $D/results/case-$C.json $*"
if [ "$L" = lock ]; then
  flock -w ${LOCKWAIT:-3600} $LOCK bash -c "uptime; $CMD"
else
  bash -c "$CMD"
fi
echo "exit=$? $C"
