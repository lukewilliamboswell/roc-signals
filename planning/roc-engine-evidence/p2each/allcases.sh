#!/bin/bash
# Every case in its own Node process. Args: OUTFILE lock|nolock N10k N1k [extra...]
D=/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/roc-engine/p2each
OUT=$1; L=$2; N10=${3:-9}; N1=${4:-11}; shift 4
: > $OUT
for spec in create_1k:$N1 replace_1k:$N1 select_1k:$N1 swap_1k:$N1 remove_1k:$N1 update_10k:$N10 create_10k:$N10 append_1k_to_10k:$N10 clear_10k:$N10; do
  c=${spec%%:*}; n=${spec##*:}
  TMO=900 bash $D/onecase.sh $c $n ${WU:-2} $L "$@" >> $OUT 2>&1
done
echo ALLDONE >> $OUT
