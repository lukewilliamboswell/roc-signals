#!/bin/bash
# Each case in its own process, lock held per case. Output: $R/paired-percase.txt
. /tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/p1bin/env.sh
OUT=$R/paired-percase.txt
: > $OUT
for spec in create_1k:11 replace_1k:11 select_1k:11 swap_1k:11 remove_1k:11 update_10k:9 create_10k:9 append_1k_to_10k:9 clear_10k:9; do
  c=${spec%%:*}; n=${spec##*:}
  uptime >> $OUT
  TMO=900 bash /tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/p1bin/onecase.sh $c $n 2 lock >> $OUT 2>&1
done
echo ALLDONE >> $OUT
