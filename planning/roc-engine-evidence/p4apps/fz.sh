#!/bin/bash
# fz.sh APP [check|build] -- sync src/ + apps/APP into fz-APP and type-check or build the fuzz target.
P=/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/roc-engine/p4apps
ROC=/home/lbw/roc_nightly-linux_x86_64-2026-11-03-34bd006/roc
A=$1; M=${2:-check}
F=$P/fz-$A
mkdir -p $F
cp $P/src/*.roc $F/
for f in $P/apps/$A/*.roc; do
  b=$(basename $f)
  [ $b = fuzz-main.roc ] && cp $f $F/main.roc || cp $f $F/$b
done
rm -f $F/wasm-main.roc
cd $F
if [ $M = check ]; then
  timeout 900 $ROC check main.roc 2>&1 | grep -v '^$' | head -${LINES_OUT:-60}
else
  /usr/bin/time -f "build %e s, %M KB" timeout 2400 $ROC build --fuzz --opt=${ROCOPT:-speed} main.roc --output=t > build.log 2>&1
  tail -15 build.log | grep -v "^$"; grep -q "^0 errors" build.log || { grep -m3 -A6 "──" build.log; exit 1; }
fi
