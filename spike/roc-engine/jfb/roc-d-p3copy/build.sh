#!/bin/bash
# D+each app on the Phase 3 column-copy workaround engine (p3copy/src/Engine.roc).
# Builds app/ against a private copy of the spike platform (build/), then copies
# app.wasm, runtime.mjs and main.mjs into dist/. Override PLATFORM, ENGINE, ROC, OPT.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
PLATFORM=${PLATFORM:-/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/roc-engine/p3copy/platform-roc}
ENGINE=${ENGINE:-/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/roc-engine/p3copy/src/Engine.roc}
ROC=${ROC:-/home/lbw/roc_nightly-linux_x86_64-2026-11-03-34bd006/roc}
OPT=${OPT:-speed}
B=$HERE/build; mkdir -p $B/pf/targets/wasm32 $B/app $HERE/dist
cp $PLATFORM/main.roc $B/pf/main.roc
cp $PLATFORM/targets/wasm32/host.wasm $B/pf/targets/wasm32/host.wasm
cp $ENGINE $B/pf/Engine.roc
cp $HERE/app/main.roc $HERE/app/Jfb.roc $B/app/
sed -i 's#platform "[^"]*"#platform "../pf/main.roc"#' $B/app/main.roc
rm -f $B/app.wasm
(cd $B/app && $ROC build --target=wasm32 --opt=$OPT --no-cache --output=$B/app.wasm main.roc)
cp $B/app.wasm $HERE/dist/app.wasm
cp $PLATFORM/runtime.mjs $HERE/dist/runtime.mjs
cp $HERE/src/main.mjs $HERE/dist/main.mjs
ls -la $HERE/dist
