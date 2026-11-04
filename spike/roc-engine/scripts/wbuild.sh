#!/bin/bash
# wbuild.sh APP -- Wasm build of APP (--opt=size, then wasm-opt -Oz) into $P/wb-APP.
# The platform (Engine.roc, main.roc, host) is copied to $P/platform-roc and the
# Zig host rebuilt whenever host.zig changes.
. "$(dirname "$0")/env.sh"
A=$1
F=$P/wb-$A
rm -rf $F; mkdir -p $F $P/platform-roc/targets/wasm32
cp $R/platform/Engine.roc $R/platform/main.roc $P/platform-roc/
mkdir -p $P/platform-roc/host
if ! cmp -s $R/platform/host/host.zig $P/platform-roc/host/host.zig || [ ! -f $P/platform-roc/targets/wasm32/host.wasm ]; then
  cp $R/platform/host/host.zig $P/platform-roc/host/host.zig
  $ZIG build-obj $P/platform-roc/host/host.zig -target wasm32-freestanding -O ReleaseSmall -fstrip -femit-bin=$P/platform-roc/targets/wasm32/host.wasm || exit 1
fi
for f in $R/src/H.roc $R/apps/$A/*.roc; do
  b=$(basename $f)
  case $b in
    wasm-main.roc) sed "s#platform \"[^\"]*\"#platform \"../platform-roc/main.roc\"#" $f > $F/main.roc ;;
    fuzz-main.roc|timing-main.roc|*Specs.roc) ;;
    *) sed 's/^import Engine\b/import pf.Engine/' $f > $F/$b ;;
  esac
done
cd $F
/usr/bin/time -f "build %e s, %M KB" timeout 3000 $ROC build --target=wasm32 --opt=${WOPT:-size} --no-cache --output=$F/app.wasm main.roc > build.log 2>&1
tail -3 build.log | grep -v '^$'
grep -q "^0 errors" build.log || { grep -m3 -A8 "──" build.log; exit 1; }
