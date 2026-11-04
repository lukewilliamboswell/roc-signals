#!/bin/bash
# Build the current engine's js-framework-benchmark production Wasm (ReleaseFast host, --opt=speed).
set -euo pipefail
. /tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/p1bin/env.sh
zig version
python3 scripts/prepare_platforms.py
zig build build-wasm-benchmark-host
O=$R/current
rm -rf $O; mkdir -p $O/platform $O/src
cp -r platform-web/. $O/platform/
mkdir -p $O/platform/targets/wasm32
cp zig-out/wasm-benchmark/production-host.o $O/platform/targets/wasm32/host.wasm
cp -r examples-web/_fixtures/js-framework-benchmark/. $O/src/
sed -i -E '0,/platform "[^"]*"/s##platform "../platform/main.roc"#' $O/src/main.roc
head -3 $O/src/main.roc
$ROC build --target=wasm32 --opt=speed --no-cache --output=$O/current.wasm $O/src/main.roc
python3 scripts/instrument_wasm.py $O/current.wasm
ls -la $O/current.wasm
