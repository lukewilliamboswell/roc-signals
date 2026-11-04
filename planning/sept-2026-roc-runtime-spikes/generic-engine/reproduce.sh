#!/usr/bin/env bash
set -euo pipefail
cd /home/lbw/Documents/Github/roc-signals
mkdir -p .test-out/generic-engine/platform/targets/wasm32
zig build-obj .test-out/generic-engine/host.zig -target wasm32-freestanding -O Debug -femit-bin=.test-out/generic-engine/platform/targets/wasm32/host.wasm
roc_spike_bin=${ROC_BIN:-/home/lbw/roc_nightly-linux_x86_64-2026-09-12-220fd47/roc}
"$roc_spike_bin" version
"$roc_spike_bin" build --target=wasm32 --no-cache --output=.test-out/generic-engine/app.wasm .test-out/generic-engine/app.roc
node .test-out/generic-engine/run.mjs
