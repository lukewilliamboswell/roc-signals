#!/bin/bash
# wbuild.sh APP -- Wasm build of APP on the p4 engine (--opt=size, then wasm-opt -Oz).
# App modules get `import Engine` rewritten to `import pf.Engine`; src/Engine.roc
# is synced into platform-roc. Size line appended to results/sizes.txt.
P=/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/roc-engine/p4apps
ZIG=/home/lbw/.cache/blueprint/v1/trees/sha256/70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00.tar.xz/zig-x86_64-linux-0.16.0/zig
ROC=/home/lbw/roc_nightly-linux_x86_64-2026-11-03-34bd006/roc
A=$1
F=$P/wb-$A
rm -rf $F; mkdir -p $F $P/results
cp $P/src/Engine.roc $P/platform-roc/Engine.roc
if [ ! -f $P/platform-roc/targets/wasm32/host.wasm ]; then
  $ZIG build-obj $P/platform-roc/host/host.zig -target wasm32-freestanding -O ReleaseSmall -fstrip -femit-bin=$P/platform-roc/targets/wasm32/host.wasm || exit 1
fi
for f in $P/src/H.roc $P/apps/$A/*.roc; do
  b=$(basename $f)
  case $b in
    wasm-main.roc) cp $f $F/main.roc ;;
    fuzz-main.roc|timing-main.roc) ;;
    *) sed 's/^import Engine\b/import pf.Engine/' $f > $F/$b ;;
  esac
done
cd $F
/usr/bin/time -f "build %e s, %M KB" timeout 3000 $ROC build --target=wasm32 --opt=size --no-cache --output=$F/app.wasm main.roc > build.log 2>&1
tail -3 build.log | grep -v '^$'
grep -q "^0 errors" build.log || { grep -m3 -A8 "──" build.log; exit 1; }
$P/wsize.sh $F/app.wasm p4-$A | tee -a $P/results/sizes.txt
