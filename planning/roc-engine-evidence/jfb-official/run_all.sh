#!/bin/bash
# Run the official js-framework-benchmark runner (all benchmarks, default iteration
# counts, headless Chrome) for each framework in turn, holding the shared timing lock
# per framework. Assumes `npm start` (server on :8080) is already running in $J.
S=/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad
J=$S/spike-results/jfb/jfb
O=$S/spike-results/jfb-official
LOCK=$S/spike-results/timing.lock
mkdir -p $O/logs $O/results
FWS=${FWS:-"keyed/solid keyed/roc-signals keyed/roc-engine-p1 keyed/roc-d-each keyed/roc-d-p3copy keyed/roc-d-p3m"}
cd $J
for f in $FWS; do
  n=${f#keyed/}
  echo "=== $f $(date +%T) waiting for lock"
  flock -w 7200 $LOCK timeout 5400 npm run bench -- --headless true --chromeBinary /usr/bin/google-chrome --framework $f $EXTRA > $O/logs/bench-$n.log 2>&1
  echo "=== $f rc=$? $(date +%T)"
  grep -E "successful run|not completely|ERROR" $O/logs/bench-$n.log | tail -3
  cp $J/webdriver-ts/results/${n}-v*.json $O/results/ 2>/dev/null
done
echo ALLDONE
