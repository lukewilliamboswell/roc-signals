#!/bin/bash
# Build and count a bisect probe: probe.sh NAME [opt]
D=/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/roc-engine/p2each
W=/home/lbw/Documents/Github/roc-signals/.claude/worktrees/agent-a65a650fdc810bc91
rm -f $D/out/probe-$1/app.wasm
bash $D/build.sh $D/probe/$1 $D/out/probe-$1 ${2:-speed} > $D/out/probe-$1.log 2>&1
[ -f $D/out/probe-$1/app.wasm ] || { echo build failed; grep -B2 -A8 "✗" $D/out/probe-$1.log | head -20; exit 1; }
cd $W && node benchmarks/js-framework-benchmark/roc-d-keyed/test/probe_counts.mjs $D/out/probe-$1/app.wasm $D/out/probe-$1/runtime.mjs
