#!/bin/bash
# fzrun.sh APP [nobuild] -- build the fuzz target (unless nobuild), accept baselines, print crashes + per-region stats.
. "$(dirname "$0")/env.sh"
A=$1
if [ "${2:-}" != nobuild ]; then
  $R/scripts/fz.sh $A build || exit 1
fi
cd $P/fz-$A || exit 1
timeout ${FZ_TIMEOUT:-1800} ./t ${FZ_MODE:-accept} ${FZ_ARGS:---timeout=900} > accept.out 2>&1
tail -2 accept.out
RP=$(ls -td .roc-fuzz/reports/*/ | head -1)
head -40 $RP/run.log
python3 $R/tools/summ.py $RP/report.json > $P/fz-$A/summary.txt
cat $P/fz-$A/summary.txt
ls -td .roc-fuzz/reports/*/ | tail -n +2 | xargs -r rm -rf
