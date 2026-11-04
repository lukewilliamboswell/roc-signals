#!/bin/bash
# tbuild.sh APP -- sync src/ + apps/APP into tm-APP and build the native timing binary (basic-cli, --opt=speed).
P=/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/roc-engine/p4apps
ROC=/home/lbw/roc_nightly-linux_x86_64-2026-11-03-34bd006/roc
A=$1
F=$P/tm-$A
mkdir -p $F
cp $P/src/*.roc $F/
for f in $P/apps/$A/*.roc; do
  b=$(basename $f)
  case $b in
    timing-main.roc) cp $f $F/main.roc ;;
    fuzz-main.roc|wasm-main.roc) ;;
    *) cp $f $F/$b ;;
  esac
done
cd $F
/usr/bin/time -f "build %e s, %M KB" timeout 2400 $ROC build --opt=speed --no-cache main.roc --output=timing > build.log 2>&1
tail -4 build.log | grep -v '^$'
grep -q "^0 errors" build.log || { grep -m3 -A8 "──" build.log; exit 1; }
