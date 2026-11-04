#!/usr/bin/env bash
set -euo pipefail
cd /home/lbw/Documents/Github/roc-signals
zig build-obj .test-out/boxed-graph/host.zig -target wasm32-freestanding -O ReleaseFast -femit-bin=.test-out/boxed-graph/platform/targets/wasm32/host.wasm
roc_spike_bin=${ROC_BIN:-/home/lbw/roc_nightly-linux_x86_64-2026-09-12-220fd47/roc}
"$roc_spike_bin" version
"$roc_spike_bin" build --target=wasm32 --opt=speed --no-cache --output=.test-out/boxed-graph/app.wasm .test-out/boxed-graph/app.roc
node .test-out/boxed-graph/run.mjs
