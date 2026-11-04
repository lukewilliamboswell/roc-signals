#!/bin/sh
# Usage: fz.sh DIR [roc]  -- builds main.roc as fuzz target, runs check, prints summary
cd "$1" || exit 1
ROC=${2:-/home/lbw/roc_nightly-linux_x86_64-2026-11-03-34bd006/roc}
rm -rf check t
$ROC build --fuzz main.roc --output=t > build.log 2>&1; [ -x t ] || { tail -30 build.log; exit 1; }
./t check --timeout=300 --report-dir=check > check.out 2>&1
tail -2 check.out | head -1
python3 -I /tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/roc-engine/p0a/summ.py check/report.json | grep -v 'property\|^=='
