#!/bin/bash
# curconduit.sh N -- build the original Conduit natively on the CURRENT engine
# (this worktree's platform-web; needs `zig build build-test-hosts
# -Doptimize=ReleaseFast` first) with host-bench specs for N articles.
. "$(dirname "$0")/env.sh"
N=$1
# The current engine in this tree is pinned to nightly 2026-09-12 (examples-web pins);
# nightly 2026-11-03 segfaults in monotype on this Conduit.
CUR_ROC=${CUR_ROC:-/home/lbw/roc_nightly-linux_x86_64-2026-09-12-220fd47/roc}
W=$(cd $R/../.. && pwd)
D=$P/cur/cd-n$N
python3 $R/tools/cur_conduit_variant.py $W/examples-web/conduit $D $N || exit 1
REL=$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" $W/platform-web/main.roc $D)
sed -i "s#pf: platform \"[^\"]*\"#pf: platform \"$REL\"#" $D/main.roc
cd $D
/usr/bin/time -f "build %e s, %M KB" timeout 5400 $CUR_ROC build --target=x64musl --opt=speed --no-cache --output=$D/cur main.roc > build.log 2>&1
tail -3 build.log
