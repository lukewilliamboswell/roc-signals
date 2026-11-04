#!/usr/bin/env bash
set -euo pipefail
cd /home/lbw/Documents/Github/roc-signals
zig build-obj .test-out/roc-owned/host.zig -target wasm32-freestanding -O Debug -femit-bin=.test-out/roc-owned/platform/targets/wasm32/host.wasm
roc_spike_bin=${ROC_BIN:-/home/lbw/roc_nightly-linux_x86_64-2026-09-12-220fd47/roc}
"$roc_spike_bin" version
for n in 10 100 1000; do
  "$roc_spike_bin" build --opt=dev --specialize=yes --target=wasm32 --no-cache --output=".test-out/roc-owned/scale-$n.wasm" ".test-out/roc-owned/scale-$n.roc"
  node .test-out/roc-owned/scale-run.mjs "$n"
done
