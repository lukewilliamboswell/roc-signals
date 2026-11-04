#!/bin/bash
# Usage: mutate.sh NAME SED_EXPR  (applied to Engine.roc in a copy of p1/fuzz)
P=/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/roc-engine
D=$P/p1/mut-$1
rm -rf $D; mkdir $D
cp $P/p1/fuzz/*.roc $P/p1/fuzz/p1-engine_baseline.json $D/; cp -r $P/p1/fuzz/regressions $D/
cd $D
sed -i "$2" Engine.roc
diff $P/p1/fuzz/Engine.roc Engine.roc | head -6
/home/lbw/roc_nightly-linux_x86_64-2026-11-03-34bd006/roc build --fuzz main.roc --output=t > build.log 2>&1 || { tail -5 build.log; exit 1; }
./t check --timeout=100 --report-dir=check > check.out 2>&1
tail -2 check.out
python3 $P/p0a/summ.py check/report.json | grep "==" | grep -v "passed" | head -5
grep -m2 -h "roc crashed\|crashed" check/*.log check/*/*.log 2>/dev/null | head -2
cd $P/p1; rm -rf $D
