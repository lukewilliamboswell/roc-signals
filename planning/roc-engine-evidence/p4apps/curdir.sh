#!/bin/bash
# curdir.sh DIR -- build DIR/main.roc (a copy of an example) natively on the CURRENT engine.
W=/home/lbw/Documents/Github/roc-signals/.claude/worktrees/agent-a33232d168c0dba47
ROC=/home/lbw/roc_nightly-linux_x86_64-2026-11-03-34bd006/roc
D=$(realpath $1)
REL=$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" $W/platform-web/main.roc $D)
sed -i "s#pf: platform \"[^\"]*\"#pf: platform \"$REL\"#" $D/main.roc
cd $D
/usr/bin/time -f "build %e s, %M KB" timeout 5400 $ROC build --target=x64musl --opt=speed --no-cache --output=$D/cur main.roc > build.log 2>&1
tail -3 build.log
