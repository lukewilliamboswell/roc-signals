#!/bin/sh
# Usage: mutate.sh NAME LINE SED_EXPR [LINE2 SED_EXPR2]
# Copies engine/ to mut-NAME/, applies the sed edit to Engine.roc on LINE,
# builds, and runs `check` (declared examples incl. traced sequences) plus a
# short exploration. Prints the outcome lines.
P=/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/roc-engine/p0a
ROC=/home/lbw/roc_nightly-linux_x86_64-2026-11-01-48d3369/roc
NAME=$1
rm -rf "$P/mut-$NAME"
mkdir "$P/mut-$NAME"
cp "$P"/engine/*.roc "$P/mut-$NAME/"
cp -r "$P/engine/regressions" "$P/mut-$NAME/"
cd "$P/mut-$NAME" || exit 1
sed -i "$2$3" Engine.roc
if [ -n "$4" ]; then sed -i "$4$5" Engine.roc; fi
diff "$P/engine/Engine.roc" Engine.roc
$ROC build --fuzz main.roc --output=t > build.log 2>&1; [ -x t ] || { tail -5 build.log; exit 1; }
./t check --timeout=100 --report-dir=check > check.out 2>&1
tail -2 check.out
python3 "$P/summ.py" check/report.json | grep "=="
./t explore --time=30 --timeout=20 --report-dir=explore > explore.out 2>&1
tail -2 explore.out
grep -m2 -E "roc crashed|trace|rule" explore/run.log
