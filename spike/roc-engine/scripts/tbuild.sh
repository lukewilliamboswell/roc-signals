#!/bin/bash
# tbuild.sh APP -- sync src/ + apps/APP into $P/tm-APP and build the native timing binary (basic-cli, --opt=speed).
. "$(dirname "$0")/env.sh"
A=$1
F=$P/tm-$A
mkdir -p $F
cp $R/src/*.roc $R/platform/Engine.roc $F/
for f in $R/apps/$A/*.roc; do
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
