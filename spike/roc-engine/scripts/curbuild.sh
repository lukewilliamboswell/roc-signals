#!/bin/bash
# Build an example on the CURRENT engine (platform-web in the worktree).
# Usage: curbuild.sh NAME KIND   KIND = native (x64musl speed) | wasm (wasm32 size + wasm-opt -Oz)
set -u
W=/home/lbw/Documents/Github/roc-signals/.claude/worktrees/agent-a33232d168c0dba47
P=/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/roc-engine/p4apps
ROC=/home/lbw/roc_nightly-linux_x86_64-2026-11-03-34bd006/roc
N=$1; K=$2
D=$P/cur/$N-$K
rm -rf $D; mkdir -p $D
cp -r $W/examples-web/$N/. $D/
REL=$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" $W/platform-web/main.roc $D)
sed -i "s#pf: platform \"[^\"]*\"#pf: platform \"$REL\"#" $D/main.roc
cd $D
if [ $K = native ]; then
  /usr/bin/time -f "build %e s, %M KB" timeout 5400 $ROC build --target=x64musl --opt=speed --no-cache --output=$D/cur main.roc > build.log 2>&1
else
  /usr/bin/time -f "build %e s, %M KB" timeout 5400 $ROC build --target=wasm32 --opt=size --no-cache --output=$D/app.wasm main.roc > build.log 2>&1
  wasm-opt -Oz --all-features $D/app.wasm -o $D/app.oz.wasm >> build.log 2>&1
  ls -l $D/app.wasm $D/app.oz.wasm >> build.log
  gzip -9 -c $D/app.oz.wasm | wc -c >> build.log
fi
echo "exit $?" >> build.log
