#!/usr/bin/env bash
set -euo pipefail
echo "Rejected identity experiment: a pure hosted fresh call can reuse identities. Use .test-out/roc-cutoff/native.sh." >&2
exit 1
cd /home/lbw/Documents/Github/roc-signals
roc_spike_bin=${ROC_BIN:-/home/lbw/roc_nightly-linux_x86_64-2026-09-12-220fd47/roc}
zig build-obj .test-out/roc-unboxed/native_runner.zig -target x86_64-linux-musl -lc -O Debug -femit-bin=.test-out/roc-unboxed/native_host.o
zig ar rcs .test-out/roc-unboxed/platform/targets/x64musl/libhost.a .test-out/roc-unboxed/native_host.o
"$roc_spike_bin" build --opt=dev --specialize=yes --target=x64musl --no-cache --output=.test-out/roc-unboxed/native-app .test-out/roc-unboxed/main.roc
.test-out/roc-unboxed/native-app fixture
for n in 10 100 1000; do
    "$roc_spike_bin" build --opt=dev --specialize=yes --target=x64musl --no-cache --output=.test-out/roc-unboxed/native-scale .test-out/roc-unboxed/scale-$n.roc
    echo "rows=$n"
    .test-out/roc-unboxed/native-scale "$n"
done
