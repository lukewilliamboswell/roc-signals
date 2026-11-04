#!/bin/bash
# timeapp.sh APP CURDIR1 [CURDIR2 ...] -- under the shared timing lock (taken per
# measurement): the p4 native timing binary, then each current-engine build's
# host-bench cases (one per spec in CURDIR/specs). Results in results/time-APP.txt.
P=/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/roc-engine/p4apps
LOCK=/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/timing.lock
A=$1; shift
mkdir -p $P/results
flock -w 7200 $LOCK $P/tm-$A/timing > $P/results/time-$A-p4.txt || echo "p4 timing failed/lock timeout"
for C in "$@"; do
  T=$P/results/time-$A-cur-$(basename $C).csv
  : > $T
  for f in $C/specs/*.scm; do
    name=$(basename $f .scm)
    warm=5; [ $name = mount ] && warm=0
    flock -w 7200 $LOCK $C/cur --host-bench-app --host-bench-name $name --host-bench-warmup $warm \
      --host-bench-iterations 1 --host-bench-samples 7 --host-entropy-seed 0 $f >> $T 2>> $T.err
  done
done
python3 $P/tools/tstat.py $P/results/time-$A-p4.txt "$@" > $P/results/time-$A.txt
cat $P/results/time-$A.txt
