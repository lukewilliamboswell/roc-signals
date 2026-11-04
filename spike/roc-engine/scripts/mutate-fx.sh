#!/bin/bash
# mutate-fx.sh -- build the effects fuzz target against deliberately broken
# engines; each mutation must make the target fail (examples, then a bounded
# exploration). Mutates only the build copy in $P/fz-effects.
. "$(dirname "$0")/env.sh"
$R/scripts/fz.sh effects build > /dev/null || exit 1
F=$P/fz-effects
cp $F/Engine.roc $F/Engine.good.roc
OUT=$P/results/mutations-fx.txt
: >> $OUT
run() {
  name=$1; from=$2; to=$3
  if [ -n "${ONLY:-}" ] && [ "$ONLY" != "$name" ]; then return; fi
  python3 - "$F/Engine.good.roc" "$F/Engine.roc" "$from" "$to" <<'PY'
import sys
s = open(sys.argv[1]).read()
assert s.count(sys.argv[3]) == 1, sys.argv[3]
open(sys.argv[2], 'w').write(s.replace(sys.argv[3], sys.argv[4]))
PY
  (cd $F && timeout 900 $ROC build --fuzz --opt=speed main.roc --output=tm > mbuild.log 2>&1) || { echo "mutation $name: BUILD FAILED" | tee -a $OUT; return; }
  rm -rf $F/.roc-fuzz/mut; mkdir -p $F/.roc-fuzz/mut
  out=$(cd $F && timeout 300 ./tm run --time=60 --report-dir=.roc-fuzz/mut/$name 2>&1 | tail -2 | head -1)
  msg=$(grep -ho 'roc crashed[^"]*\|crashed: [^"]*' $F/.roc-fuzz/mut/$name/run.log 2>/dev/null | head -1 | cut -c1-200)
  echo "mutation $name: $out :: $msg" | tee -a $OUT
}
run dispose-no-cancel 'Dispose(_) => (Engine.noop({}), Done, Engine.fx_release(tx, owned))' 'Dispose(_) => (Engine.noop({}), Done, tx)'
run result-keeps-live 'tx1 = if entry.sub tx else Engine.with_fx(tx, |fx| { ..fx, live: fx.live.keep_if(|l| l.id != id) })' 'tx1 = tx'
run no-bound '		if live.len() >= max {' '		if live.len() >= max + 1000 {'
run followups-lifo '			q = tx.fx.queue.first() ?? crash "queue"
			tx1 = Engine.with_fx(tx, |fx| { ..fx, queue: fx.queue.drop_first(1) })' '			q = tx.fx.queue.last() ?? crash "queue"
			tx1 = Engine.with_fx(tx, |fx| { ..fx, queue: fx.queue.drop_last(1) })'
run stale-applied '			Err(_) => (Engine.effect_inst(cfg, last, owned), Pending(env, 0), Engine.fx_count(tx, Stale))' '			Err(_) => (Engine.effect_inst(cfg, last, owned), Pending((cfg.react.run)(env, last, res), cfg.react.mask), Engine.fx_count(tx, Stale))'
run site-keeps-owned 'kept = if entry.sub owned else owned.drop_at(i)' 'kept = owned'
run no-queue-purge '			} else if $tx.fx.queue.any(|q| q.id == id) {' '			} else if $tx.fx.queue.len() > 1000000 {'
cp $F/Engine.good.roc $F/Engine.roc
rm -f $F/tm
