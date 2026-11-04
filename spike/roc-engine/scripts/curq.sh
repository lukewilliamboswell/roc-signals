#!/bin/bash
# Queue current-engine builds: curq.sh name:kind ...
P=/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/roc-engine/p4apps
for a in "$@"; do
  $P/curbuild.sh ${a%%:*} ${a##*:}
  echo "$a done" >> $P/curq.log
done
