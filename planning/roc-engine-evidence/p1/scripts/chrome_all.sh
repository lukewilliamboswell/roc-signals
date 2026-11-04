#!/bin/bash
# Headless Chrome paired timing, one Chrome per case, lock held per case.
. /tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/p1bin/env.sh
OUT=$R/chrome-percase.txt
: > $OUT
for spec in create_1k:9 replace_1k:9 select_1k:9 swap_1k:9 remove_1k:9 update_10k:7 create_10k:7 append_1k_to_10k:7 clear_10k:7; do
  c=${spec%%:*}; n=${spec##*:}
  uptime >> $OUT
  flock $LOCK timeout 900 python3 benchmarks/js-framework-benchmark/roc-engine-keyed/test/chrome_bench.py --current $R/current/current.wasm --new $R/new/app.wasm --out $R/chrome-$c.json --iterations $n --warmups 2 --cases $c --timeout 850 >> $OUT 2>&1
  echo "exit=$? $c" >> $OUT
done
echo ALLDONE >> $OUT
