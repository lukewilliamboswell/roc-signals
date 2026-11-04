#!/usr/bin/env bash
set -euo pipefail
cd /home/lbw/Documents/Github/roc-signals
roc_spike_bin=${ROC_BIN:-/home/lbw/roc_nightly-linux_x86_64-2026-09-12-220fd47/roc}
zig build-obj .test-out/roc-cutoff/native_runner.zig -target x86_64-linux-musl -lc -O Debug -femit-bin=.test-out/roc-cutoff/native_host.o
zig ar rcs .test-out/roc-cutoff/platform/targets/x64musl/libhost.a .test-out/roc-cutoff/native_host.o
"$roc_spike_bin" build --opt=dev --specialize=yes --target=x64musl --no-cache --output=.test-out/roc-cutoff/native-app .test-out/roc-cutoff/main.roc
.test-out/roc-cutoff/native-app fixture
"$roc_spike_bin" build --opt=dev --specialize=yes --target=x64musl --no-cache --output=.test-out/roc-cutoff/native-cutoff .test-out/roc-cutoff/cutoff-check.roc
.test-out/roc-cutoff/native-cutoff cutoff
for n in 10 100 1000; do
    "$roc_spike_bin" build --opt=dev --specialize=yes --target=x64musl --no-cache --output=.test-out/roc-cutoff/native-scale .test-out/roc-cutoff/scale-$n.roc
    echo "rows=$n"
    .test-out/roc-cutoff/native-scale "$n"
done
