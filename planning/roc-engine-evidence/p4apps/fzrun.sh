#!/bin/bash
# fzrun.sh APP [nobuild] -- build the fuzz target (unless nobuild), accept baselines, print crashes + per-region stats.
P=/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/roc-engine/p4apps
A=$1
if [ "${2:-}" != nobuild ]; then
  $P/fz.sh $A build || exit 1
fi
cd $P/fz-$A || exit 1
timeout ${FZ_TIMEOUT:-900} ./t accept > accept.out 2>&1
tail -2 accept.out
R=$(ls -td .roc-fuzz/reports/*/ | head -1)
cat $R/run.log | head -40
python3 $P/tools/summ.py $R/report.json > $P/fz-$A/summary.txt
cat $P/fz-$A/summary.txt
# keep only the newest report
ls -td .roc-fuzz/reports/*/ | tail -n +2 | xargs -r rm -rf
