#!/usr/bin/env bash
set -euo pipefail
cd /home/lbw/Documents/Github/roc-signals
zig build build-test-hosts -Doptimize=Debug
roc_spike_bin=${ROC_BIN:-/home/lbw/roc_nightly-linux_x86_64-2026-09-12-220fd47/roc}
"$roc_spike_bin" version
"$roc_spike_bin" build --target=x64musl --no-cache --output=.test-out/generic-engine/same-api/native-debug .test-out/generic-engine/same-api/main.roc
.test-out/generic-engine/same-api/native-debug --host-run-spec-json .test-out/generic-engine/same-api/spec.scm
