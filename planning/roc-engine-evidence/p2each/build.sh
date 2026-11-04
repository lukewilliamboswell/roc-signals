#!/bin/bash
# Build a Phase 2 Wasm app. Usage: build.sh APPDIR OUTDIR [opt]
# APPDIR holds main.roc (+ app modules); src/Engine.roc is synced into the
# platform and src/<Mod>.roc app modules listed in APPDIR/modules are copied
# with `import Engine` rewritten to `import pf.Engine`.
set -euo pipefail
D=/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/roc-engine/p2each
ZIG=/home/lbw/.cache/blueprint/v1/trees/sha256/70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00.tar.xz/zig-x86_64-linux-0.16.0/zig
ROC=/home/lbw/roc_nightly-linux_x86_64-2026-11-03-34bd006/roc
APP=$1; OUT=$2; OPT=${3:-speed}
cp ${ENGINE:-$D/src/Engine.roc} $D/platform-roc/Engine.roc
for m in $(cat $APP/modules 2>/dev/null); do
  sed 's/^import Engine\b/import pf.Engine/' $D/src/$m.roc > $APP/$m.roc
done
mkdir -p $D/platform-roc/targets/wasm32 $OUT
if [ ! -f $D/platform-roc/targets/wasm32/host.wasm ]; then
  $ZIG build-obj $D/platform-roc/host/host.zig -target wasm32-freestanding -O ReleaseFast -fstrip -femit-bin=$D/platform-roc/targets/wasm32/host.wasm
fi
cd $APP
/usr/bin/time -f "build %e s, %M KB" timeout 3000 $ROC build --target=wasm32 --opt=$OPT --no-cache --output=$OUT/app.wasm main.roc 2>&1 | grep -v '^$' | tail -30
cp $D/platform-roc/runtime.mjs $OUT/runtime.mjs
ls -la $OUT/app.wasm
