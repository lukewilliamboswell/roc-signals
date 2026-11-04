#!/bin/bash
# Mutation checks against the accepted baseline. Each mutation: copy the
# fuzz dir, mutate Engine.roc, build, run `check`, report the verdict.
D=/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/roc-engine/p2each
OUT=$D/results/mutations.txt
: > $OUT
for m in prune swapmove extraalloc; do
  M=$D/mut-$m
  rm -rf $M; mkdir -p $M
  cp $D/fuzz/*.roc $D/fuzz/p2-each_baseline.json $M/
  python3 $D/tools/mutfuzz.py $m $M/Engine.roc >> $OUT 2>&1 || continue
  (cd $M && timeout 2400 /home/lbw/roc_nightly-linux_x86_64-2026-11-03-34bd006/roc build --fuzz main.roc --output=t > build.log 2>&1)
  [ -x $M/t ] || { echo "$m: build failed" >> $OUT; tail -5 $M/build.log >> $OUT; continue; }
  (cd $M && timeout 1800 ./t check --timeout=900 --report-dir=check > check.out 2>&1)
  echo "== $m: $(head -1 $M/check.out)" >> $OUT
  python3 $D/tools/summ.py $M/check/report.json 2>/dev/null | grep -v " passed" | grep "==\|message\|failure" | head -8 >> $OUT
  grep -h -m2 "crashed\|mismatch\|eval count\|recreated" $M/check/*.log 2>/dev/null | head -3 >> $OUT
  rm -f $M/t; rm -rf $M/check/*.shared
done
echo DONE >> $OUT
