#!/bin/bash
# For each mutation name: build probe p1 on the mutated engine and count.
D=/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/roc-engine/p2each
P=${PROBE:-p1}
for m in "$@"; do
  python3 $D/tools/mut.py $m $D/out/Engine-$m.roc || continue
  echo "== $m"
  ENGINE=$D/out/Engine-$m.roc bash $D/probe.sh $P | head -2
done
