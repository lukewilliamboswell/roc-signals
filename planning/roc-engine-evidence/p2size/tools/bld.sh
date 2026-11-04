#!/bin/sh
# Usage: bld.sh DIR FILE OUT [roc build flags...]  -- build with 25 min timeout, append exit code and /usr/bin/time stats
d=$1; f=$2; o=$3; shift 3
cd "$d" || exit 1
/usr/bin/time -v timeout 1500 /home/lbw/roc_nightly-linux_x86_64-2026-11-03-34bd006/roc build "$f" --output="$o" "$@" > build.log 2>&1
echo "exit $?" >> build.log
grep -E "errors and|Elapsed|Maximum resident" build.log
size "$o" 2>/dev/null | tail -1
