#!/bin/bash
# Rebuild the current engine's wasm host as ReleaseSmall (production) and the
# four example wasm builds; record sizes.
export PATH=/home/lbw/.cache/blueprint/v1/trees/sha256/70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00.tar.xz/zig-x86_64-linux-0.16.0:$PATH
P=/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/roc-engine/p4apps
cd /home/lbw/Documents/Github/roc-signals/.claude/worktrees/agent-a33232d168c0dba47 || exit 1
zig build build-wasm-host -Doptimize=ReleaseSmall > $P/wasmhost.log 2>&1 || exit 1
ls -l platform-web/targets/wasm32/host.wasm >> $P/wasmhost.log
: > $P/cur-sizes.txt
for n in "$@"; do
  $P/curbuild.sh $n wasm
  $P/wsize.sh $P/cur/$n-wasm/app.wasm cur-$n >> $P/cur-sizes.txt
done
