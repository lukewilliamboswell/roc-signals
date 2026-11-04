#!/bin/bash
# mutate.sh APP -- run APP's fuzz target against deliberately broken engines;
# each mutation must make the target fail. Restores src/Engine.roc after.
P=/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/roc-engine/p4apps
A=$1
cp $P/src/Engine.roc $P/tools/Engine.good.roc
run() {
  name=$1; from=$2; to=$3
  python3 - "$P/tools/Engine.good.roc" "$P/src/Engine.roc" "$from" "$to" <<'EOF'
import sys
s = open(sys.argv[1]).read()
assert s.count(sys.argv[3]) == 1, sys.argv[3]
open(sys.argv[2], 'w').write(s.replace(sys.argv[3], sys.argv[4]))
EOF
  out=$($P/fzrun.sh $A 2>&1 | grep -E "^== specs|roc crashed" | head -3 | tr '\n' ' ')
  echo "mutation $name: $out" | tee -a $P/results/mutations.txt
}
# 1. holes never re-render a changed value (refresh skips the emit)
run hole-no-update '				if v == last {
					$holes = list.set($i, { node, mask: m, attr, read, last }) ?? crash "hole"' '				if True {
					$holes = list.set($i, { node, mask: m, attr, read, last }) ?? crash "hole"'
# 2. a derived value always compares equal (derive never propagates)
run derive-stuck '						if v2 == v {
							(b2, t2) = Engine.refresh(block, In.{ outer: env, value: v }, mask, t1)' '						if True {
							(b2, t2) = Engine.refresh(block, In.{ outer: env, value: v }, mask, t1)'
# 3. the root never runs the Changed pass after an event
run no-root-settle '				if mask == 0 {
					{ root: root2, tx: tx2 }' '				if True {
					{ root: root2, tx: tx2 }'
# 4. rows never forward changes to their nested sites
run row-kids-skip '			if cfg.dynamic and kid_mask.bitwise_and(m) != 0 {' '			if False {'
cp $P/tools/Engine.good.roc $P/src/Engine.roc
$P/fz.sh $A build > /dev/null
