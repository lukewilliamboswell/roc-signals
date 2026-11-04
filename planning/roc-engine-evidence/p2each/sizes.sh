#!/bin/bash
# Wasm sizes of jfb and the extra-state variants at --opt=speed and --opt=size.
D=/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/roc-engine/p2each
OUT=$D/results/sizes.txt
[ -z "$APPEND" ] && : > $OUT
for opt in ${OPTS:-speed size}; do
  for v in ${VARIANTS:-keyed/app size/s1 size/s2 size/s3}; do
    o=$D/out/size-$(basename $v)-$opt
    bash $D/build.sh $D/$v $o $opt > /dev/null 2>&1
    b=$(stat -c %s $o/app.wasm 2>/dev/null || echo FAIL)
    g=$(gzip -9c $o/app.wasm 2>/dev/null | wc -c)
    echo "$opt $v wasm=$b gzip=$g" >> $OUT
  done
done
cat $OUT
