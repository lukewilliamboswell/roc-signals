#!/bin/sh
# Usage: opts.sh DIR FILE.roc [opts...] -- build and run under each opt mode
cd "$1" || exit 1
f=$2; shift 2
R=/home/lbw/roc_nightly-linux_x86_64-2026-11-03-34bd006/roc
[ $# -eq 0 ] && set -- speed dev interpreter
for o in "$@"; do
  $R build "$f" --opt=$o --output=/tmp/claude-1000/re/p1b/h1/bin-$o >/tmp/claude-1000/re/p1b/h1/build-$o.log 2>&1 || { echo "$o: build failed"; tail -5 /tmp/claude-1000/re/p1b/h1/build-$o.log; continue; }
  echo "$f $o: $(/tmp/claude-1000/re/p1b/h1/bin-$o hi)"
done
