#!/bin/bash
# fz.sh APP [check|build] -- sync src/ + apps/APP into $P/fz-APP and type-check or build the fuzz target.
. "$(dirname "$0")/env.sh"
A=$1; M=${2:-check}
F=$P/fz-$A
mkdir -p $F
cp $R/src/*.roc $R/platform/Engine.roc $F/
for f in $R/apps/$A/*.roc; do
  b=$(basename $f)
  case $b in
    fuzz-main.roc) sed "s#platform \"[^\"]*fuzzpf/main.roc\"#platform \"$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' $FUZZPF $F)\"#" $f > $F/main.roc ;;
    wasm-main.roc|timing-main.roc) ;;
    *) cp $f $F/$b ;;
  esac
done
cd $F
if [ $M = check ]; then
  timeout 900 $ROC check main.roc 2>&1 | grep -v '^$' | head -${LINES_OUT:-60}
else
  /usr/bin/time -f "build %e s, %M KB" timeout 2400 $ROC build --fuzz --opt=${ROCOPT:-speed} main.roc --output=t > build.log 2>&1
  tail -15 build.log | grep -v "^$"; grep -q "^0 errors" build.log || { grep -m3 -A6 "──" build.log; exit 1; }
fi
