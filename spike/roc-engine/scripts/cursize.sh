#!/bin/bash
# cursize.sh APP... -- build each example on the CURRENT engine for wasm32
# (this worktree's platform-web; needs `zig build build-wasm-host
# -Doptimize=ReleaseSmall` first) with --opt=size, then wasm-opt -Oz; prints
# raw / -Oz / gzip -9 sizes. The current host (ReleaseSmall) is linked in.
# Uses the tree's pinned nightly (2026-09-12). Also writes the stack-checked
# module ($D/app.checked.wasm) the current browser runtime requires.
. "$(dirname "$0")/env.sh"
W=$(cd $R/../.. && pwd)
CUR_ROC=${CUR_ROC:-/home/lbw/roc_nightly-linux_x86_64-2026-09-12-220fd47/roc}
for N in "$@"; do
  D=$P/cur/$N-wasm
  rm -rf $D; mkdir -p $D
  cp -r $W/examples-web/$N/. $D/
  REL=$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" $W/platform-web/main.roc $D)
  sed -i "s#pf: platform \"[^\"]*\"#pf: platform \"$REL\"#" $D/main.roc
  (cd $D && /usr/bin/time -f "build %e s, %M KB" timeout 5400 $CUR_ROC build --target=wasm32 --opt=size --no-cache --output=$D/app.wasm main.roc > build.log 2>&1) || { echo "cur-$N build failed"; tail -5 $D/build.log; continue; }
  $R/scripts/wsize.sh $D/app.wasm cur-$N
  cp $D/app.wasm $D/app.checked.wasm
  (cd $W && python3 -c "import sys; sys.path.insert(0, 'scripts'); from instrument_wasm import instrument_wasm; from pathlib import Path; instrument_wasm(Path('$D/app.checked.wasm'))") || echo "cur-$N instrumentation failed"
done
