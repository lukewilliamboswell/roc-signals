// -*- mode: Bluespec; -*-
// Model B: the runtime's bounded ingress queue (design.md, "Re-entrancy"
// 1466-1486 and "Reports and occurrences" 1488-1567; the queue itself is
// platform/runtime.mjs `dispatch`, `takeIngress`, `drainQueue`,
// `scheduleReports`, `dropReports`).
//
// What is modelled
//   - report sources with one replaceable entry each, reached through a
//     source index; occurrences that pin earlier reports by advancing an
//     epoch; the plain drain (stops at a waiting report of the current
//     epoch) and the frame drain (takes everything);
//   - delivery as a window: a delivered turn is "running" until it returns,
//     and inputs raised meanwhile (re-entrant callbacks, 1468-1470) are
//     queued behind it; a returned turn may leave a view transition waiting
//     (the runtime stays busy until the transition is applied);
//   - the full-queue rules: early drain when idle (1532-1540), forced apply
//     of a waiting transition (1478-1479), poison when really busy (1474-1477);
//   - CANCEL of a source (1555-1557);
//   - the one scheduled report drain (frame request or its 100 ms timer).
// Not modelled: the 4096-turn drain budget, hidden pages' microtask, size
// reports' own drain, DOM-identity checks of DOM reports, `Every` port
// messages' one-per-subscription rule, manual mode's holds.
//
// Every field of `Q` whose name starts with `g` is a ghost.
module ingress {
  const BUG: str
  const MAXQ: int            // design: 4096
  const MAX_INPUTS: int      // reports and occurrences ever raised
  pure val SOURCES = Set("x", "y")

  type Entry = {
    eid: int,
    report: bool,
    src: str,        // "" for an occurrence
    first: int,      // the clock when the entry joined the queue
    seq: int,        // the clock when its current payload was raised
    epoch: int,
    dead: bool,      // payload dropped by CANCEL
    reentrant: bool, // ghost: it joined while a turn was running
  }
  type Out = { eid: int, report: bool, src: str, first: int, seq: int, at: int }
  type Drain = { reports: bool, before: int }

  type Q = {
    queue: List[Entry],
    epoch: int,
    index: str -> int,          // source -> eid of its replaceable entry, -1 for none
    liveSrc: Set[str],
    phase: str,                 // "idle" | "delivering" | "transition"
    loop: Drain, looping: bool, // the drain loop a delivery is suspended in
    pend: List[Drain],          // drain calls that follow the running delivery
    reportDue: bool,
    sched: bool,                // a frame request (and its timer) is outstanding
    poisoned: bool,
    nextEid: int,
    clock: int,
    lateEpoch: bool,            // bug "pin-late" only
    // ghosts
    out: List[Out],
    gOccs: Set[int],            // seq of every occurrence raised
    gReports: Set[{ src: str, seq: int }],
    gCancelAt: str -> int,      // -1 while live
    gInputs: int,
    gPoisonPhase: str,
    gPoisonWaiters: int,        // entries in the queue at poison that had not been raised during a turn
  }

  pure val noDrain: Drain = { reports: false, before: -1 }
  pure def busy(q: Q): bool = q.phase != "idle"

  pure def toOut(en: Entry, at: int): Out =
    { eid: en.eid, report: en.report, src: en.src, first: en.first, seq: en.seq, at: at }

  // `takeIngress`: the head leaves the queue and, if the index still names
  // it, the index.
  pure def takeHead(q: Q): Q = {
    val h = q.queue.head()
    {
      ...q, queue: q.queue.tail(),
      index: if (h.report and q.index.get(h.src) == h.eid) q.index.set(h.src, -1) else q.index,
    }
  }

  // The turn of `en` starts: it is in `out` from here on.
  pure def begin(q: Q, en: Entry): Q =
    { ...q, out: q.out.append(toOut(en, q.clock + 1)), clock: q.clock + 1, phase: "delivering" }

  // A drain loop ends: `scheduleReports` if anything still waits, else the
  // outstanding frame request is cancelled.
  pure def endLoop(q: Q): Q =
    { ...q, looping: false, sched: q.queue.length() > 0 }

  // One step of the runtime while it is not inside a delivery: continue the
  // suspended loop, or start the next pending drain call. Stops (changes
  // nothing) once a delivery has begun or nothing is left to do.
  pure def tick(q: Q): Q =
    if (q.phase == "delivering" or q.poisoned) q
    else if (not(q.looping)) {
      if (q.pend.length() == 0) q
      else {
        // drainQueue(reports, before) is entered (the runtime is not busy)
        val d = q.pend.head()
        val reports = d.reports or q.reportDue
        {
          ...q, pend: q.pend.tail(), looping: true, loop: { reports: reports, before: d.before },
          reportDue: false, sched: if (reports) false else q.sched,
        }
      }
    } else if (q.queue.length() == 0) endLoop(q)
    else {
      val h = q.queue.head()
      if (h.eid == q.loop.before) endLoop(q)
      // "Current-epoch reports wait; an occurrence has pinned older epochs."
      else if (h.report and h.epoch == q.epoch and not(q.loop.reports) and not(h.dead)) endLoop(q)
      else {
        val q1 = takeHead(q)
        if (h.dead) q1 else begin(q1, h)
      }
    }

  pure def pump(q: Q): Q = 0.to(MAXQ + 5).fold(q, (acc, _) => tick(acc))

  // Poison and unmount "discard the queue and index and cancel scheduled
  // drains" (1559-1560).
  pure def poison(q: Q): Q = {
    ...q, poisoned: true, gPoisonPhase: q.phase,
    gPoisonWaiters: q.queue.select(en => not(en.reentrant)).length(), queue: List(), index: SOURCES.mapBy(_ => -1),
    sched: false, reportDue: false, pend: List(), looping: false, phase: "idle",
  }

  // The shared tail of `dispatch`: a new entry joins the queue.
  pure def enqueue(q: Q, en: Entry): Q = {
    val full = q.queue.length() >= MAXQ
    if (full and q.phase == "delivering") poison(q)   // 1474-1477
    else {
      // 1478-1479 (a waiting transition is forced to apply) and 1532-1540
      // (an idle full queue drains early): the oldest entry becomes the
      // initiating turn, and the new entry takes the freed slot first.
      val q0 = if (full) { ...takeHead(q), phase: "idle" } else q
      val q1 = {
        ...q0, queue: q0.queue.append(en),
        index: if (en.report) q0.index.set(en.src, en.eid) else q0.index,
        sched: if (en.report) true else q0.sched,
      }
      if (full) {
        val h = q.queue.head()
        // "Capacity pressure flushes older inputs, not this newly admitted
        // report": drainQueue(true, entry), then drainQueue().
        val after: List[Drain] =
          if (en.report) [{ reports: true, before: en.eid }, noDrain] else [noDrain]
        if (h.dead) pump({ ...q1, pend: after })
        else begin({ ...q1, pend: after }, h)
      } else if (not(en.report) and not(busy(q1))) pump({ ...q1, pend: [noDrain] })
      else q1
    }
  }

  // A report source states a value (rule 1, 1514-1516).
  pure def report(q: Q, s: str): Q =
    if (q.poisoned or not(q.liveSrc.contains(s))) q
    else {
      val now = q.clock + 1
      val q1 = { ...q, clock: now, gInputs: q.gInputs + 1, gReports: q.gReports.union(Set({ src: s, seq: now })) }
      val eid = q1.index.get(s)
      val waiting = q1.queue.select(en => en.eid == eid)
      val replace = if (eid >= 0 and waiting.length() > 0) waiting.head().epoch == q1.epoch else false
      if (replace) {
        // "A newer report replaces that entry's payload in place, keeping
        // the source's position."
        ...q1, sched: true,
        queue: q1.queue.foldl(List(), (l, en) => l.append(if (en.eid == eid) { ...en, seq: now } else en)),
      } else
        enqueue({ ...q1, nextEid: q1.nextEid + 1 },
          { eid: q1.nextEid, report: true, src: s, first: now, seq: now, epoch: q1.epoch, dead: false,
            reentrant: q1.phase == "delivering" })
    }

  // An occurrence (rules 2 and 4, 1517-1519, 1527-1529).
  pure def occurrence(q: Q): Q =
    if (q.poisoned) q
    else {
      val now = q.clock + 1
      val late = BUG == "pin-late" and q.queue.length() >= MAXQ and q.phase != "delivering"
      val q1 = {
        ...q, clock: now, gInputs: q.gInputs + 1, gOccs: q.gOccs.union(Set(now)),
        // "Queuing an occurrence pins all earlier reports in O(1), by
        // advancing the index's epoch."
        epoch: if (BUG == "no-pin" or late) q.epoch else q.epoch + 1,
        lateEpoch: late,
        nextEid: q.nextEid + 1,
      }
      val en: Entry = { eid: q.nextEid, report: false, src: "", first: now, seq: now, epoch: q1.epoch, dead: false,
                        reentrant: q1.phase == "delivering" }
      // "Keep an idle occurrence synchronous, including its user activation."
      if (not(busy(q1)) and q1.queue.length() == 0) begin({ ...q1, pend: [noDrain] }, en)
      else enqueue(q1, en)
    }

  // The running turn returns. `transition`: its batch started a view
  // transition, so the runtime stays busy and every drain call that would
  // have followed returns at once (a frame drain leaves `reportDue`).
  pure def returned(q: Q, transition: bool): Q = {
    val q0 = if (q.lateEpoch) { ...q, epoch: q.epoch + 1, lateEpoch: false } else q
    if (transition) {
      val q1 = if (q0.looping) endLoop(q0) else q0
      {
        ...q1, phase: "transition", pend: List(),
        reportDue: q1.reportDue or q1.pend.select(d => d.reports and d.before == -1).length() > 0,
      }
    } else pump({ ...q0, phase: "idle" })
  }

  // The waiting transition's update callback ran: `busy = false; drainQueue()`.
  pure def transitionApplied(q: Q): Q = pump({ ...q, phase: "idle", pend: [noDrain] })

  // The frame (or its timer) fires: `cancelReportDrain(); drainQueue(true)`.
  pure def frame(q: Q): Q =
    if (busy(q)) { ...q, sched: false, reportDue: true }
    else pump({ ...q, sched: false, pend: [{ reports: true, before: -1 }] })

  // CANCEL "makes all waiting reports of its request or subscription dead
  // and removes its source index entry" (1555-1557).
  pure def cancel(q: Q, s: str): Q = {
    val eid = q.index.get(s)
    {
      ...q, clock: q.clock + 1, liveSrc: q.liveSrc.exclude(Set(s)), index: q.index.set(s, -1),
      gCancelAt: q.gCancelAt.set(s, q.clock + 1),
      queue: q.queue.foldl(List(), (l, en) => l.append(
        if (en.report and en.src == s and (BUG != "cancel-index-only" or en.eid == eid)) { ...en, dead: true } else en)),
    }
  }

  // ----------------------------------------------------------------- state
  var q: Q

  action init = q' = {
    queue: List(), epoch: 0, index: SOURCES.mapBy(_ => -1), liveSrc: SOURCES, phase: "idle",
    loop: noDrain, looping: false, pend: List(), reportDue: false, sched: false, poisoned: false,
    nextEid: 0, clock: 0, lateEpoch: false,
    out: List(), gOccs: Set(), gReports: Set(), gCancelAt: SOURCES.mapBy(_ => -1), gInputs: 0,
    gPoisonPhase: "", gPoisonWaiters: 0,
  }

  action reportStep = {
    nondet s = SOURCES.oneOf()
    all { q.gInputs < MAX_INPUTS, not(q.poisoned), q.liveSrc.contains(s), q' = report(q, s) }
  }
  action occurrenceStep = all { q.gInputs < MAX_INPUTS, not(q.poisoned), q' = occurrence(q) }
  action returnStep = {
    nondet transition = Set(true, false).oneOf()
    all { q.phase == "delivering", q' = returned(q, transition) }
  }
  action transitionStep = all { q.phase == "transition", q' = transitionApplied(q) }
  action frameStep = all { q.sched, q' = frame(q) }
  action cancelStep = {
    nondet s = SOURCES.oneOf()
    all { q.liveSrc.contains(s), not(q.poisoned), q' = cancel(q, s) }
  }
  action step = any { reportStep, occurrenceStep, returnStep, transitionStep, frameStep, cancelStep }

  // ------------------------------------------------------------ invariants
  val waitingOut: List[Out] = q.queue.foldl(List(), (l, en) => if (en.dead) l else l.append(toOut(en, -1)))
  val outSet = q.out.indices().map(i => q.out[i])
  val waitSet = waitingOut.indices().map(i => waitingOut[i])
  val everything = outSet.union(waitSet)

  // J1 (1472): the bound holds.
  val boundHolds = q.queue.length() <= MAXQ
  // J2 (rule 1): at most one replaceable entry per source, and the index
  // names exactly it.
  val indexSound = SOURCES.forall(s => {
    val cur = q.queue.select(en => en.report and en.src == s and en.epoch == q.epoch and not(en.dead))
    and {
      cur.length() <= 1,
      if (cur.length() == 1) q.index.get(s) == cur.head().eid else true,
      if (q.index.get(s) >= 0) q.queue.select(en => en.eid == q.index.get(s) and en.src == s and not(en.dead)).length() == 1 else true,
      if (q.index.get(s) >= 0) q.liveSrc.contains(s) else true,
    }
  })
  // J3 (1544): entries leave in the order they joined ("Sources keep the
  // order of their first report since the drain"; occurrences are FIFO).
  val fifo = and {
    q.out.indices().forall(i => q.out.indices().forall(j => i < j implies q.out[i].first < q.out[j].first)),
    outSet.forall(o => waitSet.forall(w => o.first < w.first)),
  }
  // J4 (1542-1544): an occurrence follows every report queued before it,
  // and no report that joined before it carries a value raised after it:
  // it "precedes every report raised after it joined".
  val pinned = everything.forall(r => everything.forall(o =>
    (r.report and not(o.report) and r.first < o.first) implies r.seq < o.seq))
  // J5 (1542-1543): "each with its newest value from before the
  // occurrence": when an occurrence is delivered, every source that was not
  // cancelled before then has had its newest earlier report delivered.
  val newestBeforeOccurrence = outSet.forall(o => o.report or SOURCES.forall(s => {
    val earlier = q.gReports.filter(r => r.src == s and r.seq < o.seq)
    val newest = earlier.fold(-1, (m, r) => if (r.seq > m) r.seq else m)
    val cancelled = q.gCancelAt.get(s) >= 0 and q.gCancelAt.get(s) < o.at
    newest < 0 or cancelled or outSet.exists(r => r.report and r.src == s and r.seq == newest and r.at < o.at)
  }))
  // J6 (1476): nothing non-lossy is dropped: every occurrence raised is
  // delivered or still waiting, unless the runtime was poisoned.
  val occurrencesKept = q.poisoned or q.gOccs.forall(t => everything.exists(o => not(o.report) and o.seq == t))
  // J7: a live source's newest value is never lost either.
  val newestReportKept = q.poisoned or q.liveSrc.forall(s => {
    val newest = q.gReports.filter(r => r.src == s).fold(-1, (m, r) => if (r.seq > m) r.seq else m)
    newest < 0 or everything.exists(r => r.report and r.src == s and r.seq == newest)
  })
  // J8 (1555-1557): a report of a cancelled source is never delivered after
  // the CANCEL.
  val deadNeverDelivered = outSet.forall(r =>
    not(r.report) or q.gCancelAt.get(r.src) < 0 or r.at < q.gCancelAt.get(r.src))
  // J9 (rule 4): an idle runtime holds only reports that wait for the
  // frame; an occurrence and everything it pinned have drained.
  val idleHoldsOnlyWaitingReports = q.phase != "idle" or
    q.queue.indices().forall(i => q.queue[i].dead or (q.queue[i].report and q.queue[i].epoch == q.epoch))
  // J10 (rule 3): whatever waits while idle has a drain scheduled.
  val noStrandedReport = q.phase != "idle" or q.queue.length() == 0 or q.sched
  // J11 (1476-1479, 1533-1534): poison only when a turn is really running.
  val poisonOnlyWhenRunning = not(q.poisoned) or q.gPoisonPhase == "delivering"

  val safe = and {
    boundHolds, indexSound, fifo, pinned, newestBeforeOccurrence, occurrencesKept,
    newestReportKept, deadNeverDelivered, idleHoldsOnlyWaitingReports, noStrandedReport,
    poisonOnlyWhenRunning,
  }

  // Liveness (rule 3; TLC only, on `ing_live`): under a fair scheduler
  // whatever waits is eventually delivered or discarded.
  temporal eventuallyDrained = weakFair(step, q) implies always(eventually(q.queue.length() == 0))
  // The same without fairness: false (the frame may never come), kept to
  // show the liveness check is not vacuous.
  temporal W_drainedWithoutFairness = always(eventually(q.queue.length() == 0))

  // A design question (expected to be violated; see the report). 1474-1477
  // call the overflow "a feedback loop between the DOM and the engine", and
  // 1533-1534 promise that the number of sources "never causes a poison
  // merely because reports waited for a frame": so at a poison, the queue
  // should hold only inputs raised while a turn was running.
  val Q_poisonOnlyFromInputsRaisedDuringTurns = not(q.poisoned) or q.gPoisonWaiters == 0

  // Witnesses (should be violated: the interesting paths are reachable).
  val W_noPoison = not(q.poisoned)
  val W_noReplace = q.gReports.size() <= q.nextEid - q.gOccs.size()
  val W_noEarlyDrain = not(q.phase == "delivering" and q.pend.length() == 2)
  val W_noDueFrame = not(q.reportDue)
}

// `ing` is the instance simulated; `ing_small` and `ing_tight` are small
// enough to search exhaustively (`ing_tight`'s queue is as small as its
// two sources, so an idle queue can be full of waiting reports).
module ing { import ingress(BUG = "none", MAXQ = 3, MAX_INPUTS = 7).* }
module ing_small { import ingress(BUG = "none", MAXQ = 3, MAX_INPUTS = 5).* }
module ing_live { import ingress(BUG = "none", MAXQ = 2, MAX_INPUTS = 3).* }
module ing_tight { import ingress(BUG = "none", MAXQ = 2, MAX_INPUTS = 5).* }
module ing_no_pin { import ingress(BUG = "no-pin", MAXQ = 3, MAX_INPUTS = 7).* }
module ing_cancel_index_only { import ingress(BUG = "cancel-index-only", MAXQ = 3, MAX_INPUTS = 7).* }
module ing_pin_late { import ingress(BUG = "pin-late", MAXQ = 3, MAX_INPUTS = 7).* }
