#!/bin/bash
# jfb.sh -- build the js-framework-benchmark keyed app (jfb/roc-d-each) on the
# current platform (Engine.roc, host, runtime.mjs) in $P/jfb and run the
# keyed-operation DOM checks in headless Chrome (browser/jfb-check.mjs).
. "$(dirname "$0")/env.sh"
J=$P/jfb
rm -rf $J; mkdir -p $J $P/platform-roc/targets/wasm32
cp -r $R/jfb/roc-d-each/{app,src,index.html,build.sh} $J/
cp $R/platform/main.roc $R/platform/runtime.mjs $P/platform-roc/
if [ ! -f $P/platform-roc/targets/wasm32/host.wasm ] || ! cmp -s $R/platform/host/host.zig $P/platform-roc/host/host.zig; then
  mkdir -p $P/platform-roc/host; cp $R/platform/host/host.zig $P/platform-roc/host/
  $ZIG build-obj $P/platform-roc/host/host.zig -target wasm32-freestanding -O ReleaseSmall -fstrip -femit-bin=$P/platform-roc/targets/wasm32/host.wasm || exit 1
fi
(cd $J && PLATFORM=$P/platform-roc ENGINE=$R/platform/Engine.roc ROC=$ROC bash build.sh > build.log 2>&1) || { tail -20 $J/build.log; exit 1; }
NODE_PATH=$PUPPETEER_NODE_PATH timeout 300 node $R/browser/jfb-check.mjs $J/dist
