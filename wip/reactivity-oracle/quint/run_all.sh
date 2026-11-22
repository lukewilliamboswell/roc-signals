#!/usr/bin/env bash
# Every check of the spike, in the order the report lists them. Run from
# this directory; `env.sh` puts the local Quint, its Apalache and the local
# JDK 21 first (nothing global is used or changed).
set -u
cd "$(dirname "${BASH_SOURCE[0]}")"
. ./env.sh
mkdir -p logs traces

FX_INVS="capHolds refusalExactlyAtCap fatesAgree countersBalance tableAgreesWithSites onlyKeptOrphans latestOwnsOnlyCurrent noRunAfterEnd noScopedRunAfterDispose successorNeverReceives noWriteToRetired noOldAnswerToNewRequest supersededNeverRuns currentRunsOnlyCurrentQuestion"
ING_INVS="boundHolds indexSound fifo pinned newestBeforeOccurrence occurrencesKept newestReportKept deadNeverDelivered idleHoldsOnlyWaitingReports noStrandedReport poisonOnlyWhenRunning"

say() { printf '\n=== %s\n' "$*"; }

say typecheck
quint typecheck effects.qnt && quint typecheck ingress.qnt

say "simulate: design rules"
quint run effects.qnt --main fx --invariants $FX_INVS --max-samples 2000000 --max-steps 40 --verbosity 1
quint run ingress.qnt --main ing --invariants $ING_INVS --max-samples 2000000 --max-steps 30 --verbosity 1
quint run ingress.qnt --main ing_tight --invariants $ING_INVS --max-samples 2000000 --max-steps 30 --verbosity 1

say "simulate: seeded defects (each must be found)"
for m in fx_reparent_scoped fx_supersede_forgets fx_orphan_writes_remount fx_reuse_ids fx_cap_off_by_one fx_drop_uncounted fx_dispose_keeps_table; do
  echo "-- $m"; quint run effects.qnt --main $m --invariants $FX_INVS --max-samples 200000 --max-steps 30 --verbosity 1
done
for m in ing_no_pin ing_cancel_index_only ing_pin_late; do
  echo "-- $m"; quint run ingress.qnt --main $m --invariants $ING_INVS --max-samples 300000 --max-steps 30 --verbosity 1
done

say "simulate: design questions (each is expected to be violated)"
for q in Q_latestNeverCommitsOlderAfterNewer Q_currentNeverCommitsOlderAfterNewer Q_reparentedCountsRequests Q_orphansNeverCauseRefusal; do
  echo "-- $q"; quint run effects.qnt --main fx --invariant $q --max-samples 200000 --max-steps 30 --verbosity 1
done
quint run ingress.qnt --main ing_tight --invariant Q_poisonOnlyFromInputsRaisedDuringTurns --max-samples 200000 --max-steps 30 --verbosity 1

say "TLC, exhaustive (about 4 min, 1 min and 4 min for the fx instances on 14 cores)"
for m in fx_small_latest fx_small_current fx_small_watch; do
  quint verify effects.qnt --main $m --invariant safe --backend tlc > logs/$m-tlc-safe.log 2>&1; tail -8 logs/$m-tlc-safe.log
done
for m in ing_small ing_tight; do
  quint verify ingress.qnt --main $m --invariant safe --backend tlc > logs/$m-tlc-safe.log 2>&1; tail -8 logs/$m-tlc-safe.log
done

say "TLC, liveness"
quint verify ingress.qnt --main ing_live --temporal eventuallyDrained --backend tlc > logs/ing_live-tlc-temporal.log 2>&1; tail -8 logs/ing_live-tlc-temporal.log

say "Apalache, bounded (slow: see the report)"
timeout 300 quint verify ingress.qnt --main ing_live --invariant safe --max-steps 6 > logs/ing_live-apalache-safe.log 2>&1; tail -3 logs/ing_live-apalache-safe.log
