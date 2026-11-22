// -*- mode: Bluespec; -*-
// Model A: the effect channel's request lifecycle (design.md, "The Effect
// Channel": "Ids, results and staleness" 2871-2904, "Bounds" 2914-2917,
// "Disposal and reparenting" 2989-3025, "Supersession and asynchronous
// layers" 3029-3066, "Counters" 3111-3122, "Explicit Scopes and Disposal"
// 1284-1299).
//
// What is modelled
//   - a scope tree  R (root, never disposed) -> A -> B,  R -> S.  Each of A,
//     B, S is the body of a `when` site that lives in its parent, and holds
//     one effect site with a policy: "watch" (keeps everything),
//     "latest" (watch_latest: supersedes) or "current" (keep_current).
//   - request kinds: "kept" (Http and the other admitted kinds: reparent on
//     disposal), "scoped" (Timer: one result, cancelled on disposal), "sub"
//     (Interval / port subscription: many results, cancelled on disposal).
//   - the in-flight table with its cap, refusal as a queued follow-up,
//     supersession, disposal (cancel / reparent / drop queued follow-ups),
//     re-reparenting when an adopter is itself disposed, results arriving
//     from an adversarial host for any id in any order, and the seven
//     counters.
// What is not modelled: progress reports, `Self` follow-ups, the follow-up
// depth and breadth bounds, `resource`/`gather` layers (they supersede
// exactly as "latest" does), table-view row orphans, payloads.
//
// Every field of `Eng` whose name starts with `g` is a ghost: the engine
// never reads it, the invariants do.
//
// Run: `. ./env.sh`, then e.g.
//   quint run effects.qnt --main fx --invariant safe
//   quint verify effects.qnt --main fx_small_latest --invariant safe --backend tlc
//   quint run effects.qnt --main fx_reuse_ids --invariant noOldAnswerToNewRequest --mbt --out-itf t.itf.json
// (`run_all.sh` has every check; `show_trace.py t.itf.json` prints a trace.)
module effects {
  // The seeded defect, "none" for the design's rules (see the instances
  // at the end of the file).
  const BUG: str
  const MAX_REQS: int         // requests ever planned (admitted or refused)
  const MAX_STEPS: int        // issuing steps (mounts and value changes)
  const POLICIES: Set[str]    // each site's policy is any one of these

  // ---------------------------------------------------------------- bounds
  pure val CAP = 2            // in-flight cap (design: 32 by default)
  pure val MAX_GEN = 2        // mounts per scope
  pure val MAX_LATE = 1       // results for ids that are not in flight
  pure val MAX_MSGS = 1       // non-terminal subscription messages

  pure val SCOPES = Set("A", "B", "S")
  pure val VALUES = Set(0, 1)
  pure val PLANS: Set[List[str]] = Set(List(), ["kept"], ["scoped"], ["sub"], ["kept", "sub"])

  pure def parent(x: str): str = if (x == "B") "A" else "R"
  pure def subtree(x: str): Set[str] = if (x == "A") Set("A", "B") else Set(x)
  // The states a reaction of scope x's site may write: its own scope's, an
  // ancestor's, or a store cell / root state ("R": outlives every scope).
  pure def targets(x: str): Set[str] = if (x == "B") Set("B", "A", "R") else Set(x, "R")

  // ----------------------------------------------------------------- types
  type Req = {
    scope: str, gen: int,          // the issuing site and its incarnation
    value: int,                    // the value it was issued for
    step: int,                     // ghost: the issuing step (global order)
    kind: str,                     // "kept" | "scoped" | "sub"
    tgtScope: str, tgtGen: int,    // the state its reaction writes
    nonce: int,                    // the host's identity for this request
    fate: str,                     // ghost: "live" | "refusedQ" | "final" | "cancelled" | "refDelivered" | "refDropped"
  }
  // An in-flight table entry. `holder` is the path results route to: the
  // site of scope `holder`, or (orphan) the `when` site that toggles scope
  // `holder`, which lives in parent(holder).
  type Live = { holder: str, orphan: bool, eligible: bool }
  type Commit = { scope: str, step: int, nonce: int, tgt: str }

  type Eng = {
    bug: str,
    pol: str -> str,
    next: int,
    live: int -> Live,
    queue: List[int],              // follow-ups (refusals), in order
    waiting: Set[int],             // follow-ups still to run
    alive: str -> bool,
    gen: str -> int,
    watch: str -> int,             // each site's watched value (a store cell: it moves while the site is disposed)
    owned: str -> Set[int],        // ids a live site holds (in flight or refused and queued)
    cur: str -> Set[int],          // the ids of the site's latest issuing step
    adopted: str -> Set[int],      // orphans held by the `when` site of a scope
    issued: int, delivered: int, stale: int, refused: int,
    cancelled: int, reparented: int, skipped: int,
    // host side: every (id, nonce) a request command carried
    host: Set[{ id: int, nonce: int }],
    nonce: int,
    // ghosts
    reqs: int -> Req,
    gStep: int,
    gTerminal: int, gMsgs: int, gRefDelivered: int, gRefDropped: int,
    gLate: int, gSiteMiss: int,
    gRefusedAt: Set[int], gAdmittedAt: Set[int],
    gOrphaned: Set[int],
    gViol: Set[str],
    gNewest: str -> int,           // per scope: the newest issuing step whose reaction committed
  }

  // --------------------------------------------------------------- helpers
  pure def mapRemove(m: int -> a, k: int): int -> a = m.keys().exclude(Set(k)).mapBy(i => m.get(i))
  // (No short-circuit `or` guards a map lookup anywhere in this file: TLC
  // evaluates both sides of the translated disjunction.)
  pure def isAlive(e: Eng, x: str): bool = if (x == "R") true else e.alive.get(x)
  pure def inFlight(e: Eng, id: int): bool = e.live.keys().contains(id)
  pure def note(e: Eng, cond: bool, what: str): Eng =
    if (cond) { ...e, gViol: e.gViol.union(Set(what)) } else e
  pure def setFate(e: Eng, id: int, fate: str): Eng =
    { ...e, reqs: e.reqs.setBy(id, r => { ...r, fate: fate }) }

  // design 2873: "Awaited ids are instance-wide, issued in order from 1."
  pure def freshId(e: Eng): int =
    if (e.bug == "reuse-ids") {
      val busy = e.live.keys().union(e.waiting)
      1.to(MAX_REQS + 1).filter(i => not(busy.contains(i))).fold(MAX_REQS + 1, (a, i) => if (i < a) i else a)
    } else e.next

  // design 2914-2917: "A request beyond it is not issued: it is refused,
  // counted, and its owner receives a typed Refused result in a follow-up
  // turn."  2892-2896: a refused request "takes an id but no slot".
  pure def request(e: Eng, x: str, kind: str, tgt: str): Eng = {
    val id = freshId(e)
    val n = e.live.keys().size()
    val full = if (e.bug == "cap-off-by-one") n > CAP else n >= CAP
    val r: Req = {
      scope: x, gen: e.gen.get(x), value: e.watch.get(x), step: e.gStep, kind: kind,
      tgtScope: tgt, tgtGen: if (tgt == "R") 0 else e.gen.get(tgt), nonce: e.nonce,
      fate: if (full) "refusedQ" else "live",
    }
    val e1 = {
      ...e, next: e.next + 1, nonce: e.nonce + 1, reqs: e.reqs.put(id, r),
      owned: e.owned.setBy(x, s => s.union(Set(id))),
      cur: e.cur.setBy(x, s => s.union(Set(id))),
    }
    if (full) {
      ...e1, refused: e1.refused + 1, queue: e1.queue.append(id),
      waiting: e1.waiting.union(Set(id)), gRefusedAt: e1.gRefusedAt.union(Set(n)),
    } else {
      ...e1, issued: e1.issued + 1,
      live: e1.live.put(id, { holder: x, orphan: false, eligible: false }),
      host: e1.host.union(Set({ id: id, nonce: e.nonce })),
      gAdmittedAt: e1.gAdmittedAt.union(Set(n)),
    }
  }

  // One issuing step of a site: the plan's requests in plan order.
  pure def issue(e: Eng, x: str, plan: List[str], tgt: str): Eng = {
    val e1 = { ...e, gStep: e.gStep + 1, cur: e.cur.set(x, Set()) }
    plan.foldl(e1, (acc, kind) => request(acc, x, kind, tgt))
  }

  // CANCEL: leaves the in-flight table, counts `cancelled` (2998, 3037-3038).
  pure def cancelOne(e: Eng, id: int): Eng =
    { ...setFate(e, id, "cancelled"), live: e.live.mapRemove(id), cancelled: e.cancelled + 1 }

  // A queued follow-up is dropped and counts `stale` (1296, 3038-3039).
  pure def dropOne(e: Eng, id: int): Eng = {
    ...setFate(e, id, "refDropped"), waiting: e.waiting.exclude(Set(id)),
    stale: if (e.bug == "drop-uncounted") e.stale else e.stale + 1,
    gRefDropped: e.gRefDropped + 1,
  }

  // design 3034-3040: watch_latest "gives up everything it still owns from
  // earlier values: every awaited request still in flight, of any kind (an
  // admitted Http request included), gets CANCEL, leaves the in-flight
  // table and counts cancelled; a follow-up or refusal still queued for it
  // is dropped and counts stale."
  pure def supersede(e: Eng, x: str): Eng = {
    val ids = e.owned.get(x)
    if (e.bug == "supersede-forgets")
      // counts the cancel but forgets to forget the request
      ids.fold(e, (acc, id) =>
        if (inFlight(acc, id)) { ...setFate(acc, id, "cancelled"), cancelled: acc.cancelled + 1 }
        else if (acc.waiting.contains(id)) dropOne(acc, id) else acc)
    else {
      val e1 = ids.fold(e, (acc, id) =>
        if (inFlight(acc, id)) cancelOne(acc, id)
        else if (acc.waiting.contains(id)) dropOne(acc, id) else acc)
      { ...e1, owned: e1.owned.set(x, Set()) }
    }
  }

  // The watched value of scope x's site becomes v. A disposed site sees
  // nothing. design 3029-3031 (watch keeps everything), 3034 (latest),
  // 3043-3046 (current: a new step replaces the eligible one, even with an
  // empty plan).
  pure def bump(e: Eng, x: str, v: int, plan: List[str], tgt: str): Eng = {
    val e1 = { ...e, watch: e.watch.set(x, v) }
    if (not(e1.alive.get(x))) e1
    else if (e1.pol.get(x) == "latest") issue(supersede(e1, x), x, plan, tgt)
    else issue(e1, x, plan, tgt)
  }

  // Mounting is a new incarnation of the scope; all three policies issue
  // at mount (2483-2484).
  pure def mount(e: Eng, x: str, plan: List[str], tgt: str): Eng = {
    val e1 = { ...e, alive: e.alive.set(x, true), gen: e.gen.setBy(x, g => g + 1) }
    issue(e1, x, plan, tgt)
  }

  // Disposal of the site of scope y while `top` is being disposed
  // (1294-1299, 2994-3007): scoped kinds get CANCEL, queued follow-ups are
  // dropped, admitted requests are handed up to the `when` site of `top`.
  // 3051: "On disposal, eligibility freezes for each admitted request."
  pure def disposeSite(e: Eng, y: str, top: str): Eng = {
    val ids = e.owned.get(y)
    val e1 = ids.fold(e, (acc, id) =>
      if (inFlight(acc, id)) {
        val keep = acc.reqs.get(id).kind == "kept" or acc.bug == "reparent-scoped"
        if (keep) {
          ...acc,
          live: acc.live.set(id, { holder: top, orphan: true, eligible: acc.cur.get(y).contains(id) }),
          adopted: acc.adopted.setBy(top, s => s.union(Set(id))),
          reparented: acc.reparented + 1,
          gOrphaned: acc.gOrphaned.union(Set(id)),
        } else if (acc.bug == "dispose-keeps-table")
          // CANCEL is emitted and counted but the table entry stays
          { ...setFate(acc, id, "cancelled"), cancelled: acc.cancelled + 1 }
        else cancelOne(acc, id)
      } else if (acc.waiting.contains(id)) dropOne(acc, id) else acc)
    { ...e1, alive: e1.alive.set(y, false), owned: e1.owned.set(y, Set()), cur: e1.cur.set(y, Set()) }
  }

  // The `when` site of y (y below top) goes with top's body: the orphans it
  // had adopted are handed up again and adopted by top's `when` site
  // (Core.roc: `Orphaned(adopted.concat(orph))`, then `fx_adopt`, which
  // counts `reparented` once more for each).
  pure def handUp(e: Eng, y: str, top: str): Eng = {
    val ids = e.adopted.get(y)
    {
      ...e,
      adopted: e.adopted.set(y, Set()).setBy(top, s => s.union(ids)),
      live: ids.fold(e.live, (m, id) => m.setBy(id, l => { ...l, holder: top })),
      reparented: e.reparented + ids.size(),
    }
  }

  pure def dispose(e: Eng, top: str): Eng =
    subtree(top).fold(e, (acc, y) => {
      val a1 = if (acc.alive.get(y)) disposeSite(acc, y, top) else acc
      if (y != top) handUp(a1, y, top) else a1
    })

  // Run a reaction's write. design 3010-3014: "a write to a retired state
  // is skipped and counted (skipped), writes to surviving states commit";
  // store cells always commit. 3055: "A remount is a new scope".
  pure def react(e: Eng, id: int, resultNonce: int, orphan: bool): Eng = {
    val r = e.reqs.get(id)
    val there = if (r.tgtScope == "R") true else (e.alive.get(r.tgtScope) and e.gen.get(r.tgtScope) == r.tgtGen)
    val commit = if (e.bug == "orphan-writes-remount") isAlive(e, r.tgtScope) else there
    val ownerThere = e.alive.get(r.scope) and e.gen.get(r.scope) == r.gen
    val e1 = e
      .note(r.fate != "live" and r.fate != "refusedQ", "ran-after-end")
      .note(r.kind != "kept" and not(ownerThere), "scoped-ran-after-dispose")
      .note(not(orphan) and not(ownerThere), "successor-received")
      .note(commit and not(there), "wrote-retired-state")
      .note(resultNonce != r.nonce, "old-answer-to-new-request")
      .note(e.pol.get(r.scope) == "latest" and not(orphan) and r.value != e.watch.get(r.scope), "latest-ran-superseded")
      .note(e.pol.get(r.scope) == "current" and r.value != e.watch.get(r.scope), "current-ran-old-question")
      // design questions (see the Q_ properties below)
      .note(commit and e.pol.get(r.scope) == "latest" and r.step < e.gNewest.get(r.scope), "Q-latest-older-after-newer")
      .note(commit and e.pol.get(r.scope) == "current" and r.step < e.gNewest.get(r.scope), "Q-current-older-after-newer")
    if (commit) {
      ...e1, gNewest: e1.gNewest.setBy(r.scope, s => if (r.step > s) r.step else s),
    } else { ...e1, skipped: e1.skipped + 1 }
  }

  // A result arrives for `id` (2875-2882). `ends`: for a subscription, the
  // result is its Closed/Threw (2890-2891); every other kind's first result
  // is terminal (a Timeout, a WorkLost and a refusal by the service are all
  // just results here).
  pure def deliver(e: Eng, id: int, resultNonce: int, ends: bool): Eng =
    if (not(inFlight(e, id))) {
      // 2879-2881: "dropped before any state is touched and counted stale"
      ...e, stale: e.stale + 1, gLate: e.gLate + 1,
    } else {
      val l = e.live.get(id)
      val r = e.reqs.get(id)
      // 2881-2882: "The owning site also checks that it holds the id"
      val held =
        if (l.orphan) e.adopted.get(l.holder).contains(id) and isAlive(e, parent(l.holder))
        else e.alive.get(l.holder) and e.owned.get(l.holder).contains(id)
      if (not(held)) { ...e, stale: e.stale + 1, gSiteMiss: e.gSiteMiss + 1 }
      else {
        val terminal = r.kind != "sub" or ends
        // 3043-3048 keep_current: "delivering readers and reactions only
        // for the latest issuing step"; 3051-3054: an eligible orphan also
        // requires its declared signal to equal its issued-for value.
        val runs =
          if (e.pol.get(r.scope) != "current") true
          else if (l.orphan) l.eligible and e.watch.get(r.scope) == r.value
          else e.cur.get(r.scope).contains(id)
        val e1 = if (runs) react(e, id, resultNonce, l.orphan) else e
        val e2 = { ...e1, delivered: e1.delivered + 1 }
        if (terminal) {
          ...setFate(e2, id, "final"),
          live: e2.live.mapRemove(id),
          owned: if (l.orphan) e2.owned else e2.owned.setBy(l.holder, s => s.exclude(Set(id))),
          cur: if (l.orphan) e2.cur else e2.cur.setBy(l.holder, s => s.exclude(Set(id))),
          adopted: if (l.orphan) e2.adopted.setBy(l.holder, s => s.exclude(Set(id))) else e2.adopted,
          gTerminal: e2.gTerminal + 1,
        } else { ...e2, gMsgs: e2.gMsgs + 1 }
      }
    }

  // The head follow-up runs (1396-1397: "follow-up turns queued by the turn
  // run next, in order"). One dropped by supersession or disposal was
  // counted then and takes no turn.
  pure def followUp(e: Eng): Eng = {
    val id = e.queue.head()
    val e0 = { ...e, queue: e.queue.tail() }
    if (not(e0.waiting.contains(id))) e0
    else {
      val r = e0.reqs.get(id)
      val runs = e0.pol.get(r.scope) != "current" or e0.cur.get(r.scope).contains(id)
      val e1 = if (runs) react(e0, id, r.nonce, false) else e0
      {
        ...setFate(e1, id, "refDelivered"),
        waiting: e1.waiting.exclude(Set(id)),
        owned: e1.owned.setBy(r.scope, s => s.exclude(Set(id))),
        cur: e1.cur.setBy(r.scope, s => s.exclude(Set(id))),
        delivered: e1.delivered + 1, gRefDelivered: e1.gRefDelivered + 1,
      }
    }
  }

  // ----------------------------------------------------------------- state
  var e: Eng

  pure def start(bug: str, pol: str -> str): Eng = {
    bug: bug, pol: pol, next: 1, live: Map(), queue: List(), waiting: Set(),
    alive: SCOPES.mapBy(_ => false), gen: SCOPES.mapBy(_ => 0), watch: SCOPES.mapBy(_ => 0),
    owned: SCOPES.mapBy(_ => Set()), cur: SCOPES.mapBy(_ => Set()), adopted: SCOPES.mapBy(_ => Set()),
    issued: 0, delivered: 0, stale: 0, refused: 0, cancelled: 0, reparented: 0, skipped: 0,
    host: Set(), nonce: 0, reqs: Map(), gStep: 0,
    gTerminal: 0, gMsgs: 0, gRefDelivered: 0, gRefDropped: 0, gLate: 0, gSiteMiss: 0,
    gRefusedAt: Set(), gAdmittedAt: Set(), gOrphaned: Set(), gViol: Set(),
    gNewest: SCOPES.mapBy(_ => 0),
  }

  action init = {
    nondet pa = POLICIES.oneOf()
    nondet pb = POLICIES.oneOf()
    nondet ps = POLICIES.oneOf()
    e' = start(BUG, Map("A" -> pa, "B" -> pb, "S" -> ps))
  }

  // A plan a site of this policy may return, that fits the model's bounds.
  def plansFor(x: str): Set[List[str]] =
    PLANS.filter(p => e.nonce + p.length() <= MAX_REQS and (e.pol.get(x) != "current" or not(p.select(k => k == "sub").length() > 0)))

  action bumpStep = {
    nondet x = SCOPES.oneOf()
    nondet v = VALUES.oneOf()
    nondet plan = plansFor(x).oneOf()
    nondet tgt = targets(x).oneOf()
    all { v != e.watch.get(x), e.gStep < MAX_STEPS, e' = bump(e, x, v, plan, tgt) }
  }
  action mountStep = {
    nondet x = SCOPES.oneOf()
    nondet plan = plansFor(x).oneOf()
    nondet tgt = targets(x).oneOf()
    all {
      not(e.alive.get(x)), isAlive(e, parent(x)), e.gen.get(x) < MAX_GEN, e.gStep < MAX_STEPS,
      e' = mount(e, x, plan, tgt),
    }
  }
  action disposeStep = {
    nondet x = SCOPES.oneOf()
    all { e.alive.get(x), e' = dispose(e, x) }
  }
  // The host answers any id, issued or not, in any order, as often as it
  // likes: after a cancel, after a disposal, after the final result.
  action deliverStep = {
    nondet id = 1.to(MAX_REQS + 1).oneOf()
    nondet ends = Set(true, false).oneOf()
    val sent = e.host.filter(h => h.id == id).map(h => h.nonce)
    nondet n = (if (sent.size() == 0) Set(-1) else sent).oneOf()
    all {
      if (inFlight(e, id)) (ends or e.reqs.get(id).kind != "sub" or e.gMsgs < MAX_MSGS)
      else e.gLate < MAX_LATE,
      e' = deliver(e, id, n, ends),
    }
  }
  // A follow-up turn, and what its reaction's write may set off in the same
  // turn's Changed pass: nothing, a new value at a site, or a disposal.
  // (An over-approximation: a follow-up that was dropped takes no turn in
  // the engine, yet may be followed by a consequence here.)
  action followUpStep = {
    nondet conseq = Set("none", "bump", "dispose").oneOf()
    nondet x = SCOPES.oneOf()
    nondet v = VALUES.oneOf()
    nondet plan = plansFor(x).oneOf()
    nondet tgt = targets(x).oneOf()
    val e1 = followUp(e)
    any {
      all { conseq == "none", e' = e1 },
      all { conseq == "bump", v != e1.watch.get(x), e1.gStep < MAX_STEPS, e1.nonce + plan.length() <= MAX_REQS, e' = bump(e1, x, v, plan, tgt) },
      all { conseq == "dispose", e1.alive.get(x), e' = dispose(e1, x) },
    }
  }

  // Follow-ups drain inside the call that queued them: no external input
  // is interleaved (1396-1397, 1441-1442).
  action step =
    if (e.queue.length() > 0) followUpStep
    else any { bumpStep, mountStep, disposeStep, deliverStep }

  // ------------------------------------------------------------ invariants
  // I1 (2914): the in-flight table never exceeds the cap ...
  val capHolds = e.live.keys().size() <= CAP
  // I2 ... and a refusal happens exactly at the cap, an admission only below it.
  val refusalExactlyAtCap =
    e.gRefusedAt.forall(n => n == CAP) and e.gAdmittedAt.forall(n => n < CAP)
  // I3: every id ever planned is in exactly one place, and the table, the
  // follow-up index and the ghost fate agree on which.
  val fatesAgree = e.reqs.keys().forall(id => {
    val f = e.reqs.get(id).fate
    and {
      (f == "live") iff inFlight(e, id),
      (f == "refusedQ") iff e.waiting.contains(id),
      not(inFlight(e, id) and e.waiting.contains(id)),
    }
  })
  // I4: the counters balance (3113-3115, with the breakdown the design does
  // not state; see the report).
  val countersBalance = and {
    e.nonce == e.issued + e.refused,
    e.issued == e.live.keys().size() + e.cancelled + e.gTerminal,
    e.refused == e.waiting.size() + e.gRefDelivered + e.gRefDropped,
    e.delivered == e.gTerminal + e.gMsgs + e.gRefDelivered,
    e.stale == e.gLate + e.gRefDropped + e.gSiteMiss,
    e.cancelled == e.reqs.keys().filter(id => e.reqs.get(id).fate == "cancelled").size(),
    e.skipped <= e.delivered,
    e.reparented >= e.gOrphaned.size(),
  }
  // I5: the in-flight table and the sites agree on who holds what, so the
  // site's own ownership check (2881-2882) never has to refuse anything.
  val tableAgreesWithSites = and {
    e.live.keys().forall(id => {
      val l = e.live.get(id)
      if (l.orphan) e.adopted.get(l.holder).contains(id) and isAlive(e, parent(l.holder))
      else and { e.alive.get(l.holder), e.owned.get(l.holder).contains(id),
                 e.reqs.get(id).scope == l.holder, e.reqs.get(id).gen == e.gen.get(l.holder) }
    }),
    SCOPES.forall(x => e.owned.get(x).forall(id => inFlight(e, id) or e.waiting.contains(id))),
    SCOPES.forall(x => e.adopted.get(x).forall(id => if (inFlight(e, id)) e.live.get(id).orphan else false)),
    e.gSiteMiss == 0,
  }
  // I6 (2994-2999, 1323-1325): only admitted kinds survive their site, so
  // with every scope disposed only kept requests remain in flight.
  val onlyKeptOrphans = e.live.keys().forall(id => e.live.get(id).orphan implies e.reqs.get(id).kind == "kept")
  // I7 (3034-3036): a live watch_latest site owns only requests of its
  // current value and its own incarnation.
  val latestOwnsOnlyCurrent = SCOPES.forall(x =>
    (e.alive.get(x) and e.pol.get(x) == "latest") implies
      e.owned.get(x).forall(id => e.reqs.get(id).value == e.watch.get(x) and e.reqs.get(id).gen == e.gen.get(x)))
  // I8-I13: what a reaction run must never be (recorded when it ran).
  def never(what: str): bool = not(e.gViol.contains(what))
  val noRunAfterEnd = never("ran-after-end")                    // delivered twice, or after a cancel
  val noScopedRunAfterDispose = never("scoped-ran-after-dispose")
  val successorNeverReceives = never("successor-received")       // 2881-2882
  val noWriteToRetired = never("wrote-retired-state")            // 3010-3013
  val noOldAnswerToNewRequest = never("old-answer-to-new-request") // 2873: ids are never reused
  val supersededNeverRuns = never("latest-ran-superseded")       // 3039-3040
  val currentRunsOnlyCurrentQuestion = never("current-ran-old-question") // 3047-3054

  val safe = and {
    capHolds, refusalExactlyAtCap, fatesAgree, countersBalance, tableAgreesWithSites,
    onlyKeptOrphans, latestOwnsOnlyCurrent, noRunAfterEnd, noScopedRunAfterDispose,
    successorNeverReceives, noWriteToRetired, noOldAnswerToNewRequest, supersededNeverRuns,
    currentRunsOnlyCurrentQuestion,
  }

  // Design questions: properties one might expect that the design's rules do
  // NOT give. The checker's counterexamples are the questions.
  // Q1: once an answer of a newer issuing step of a watch_latest site has
  // committed, no answer of an older step commits.
  val Q_latestNeverCommitsOlderAfterNewer = never("Q-latest-older-after-newer")
  // Q2: the same for keep_current.
  val Q_currentNeverCommitsOlderAfterNewer = never("Q-current-older-after-newer")
  // Q3: `reparented` counts requests (it counts adoptions).
  val Q_reparentedCountsRequests = e.reparented == e.gOrphaned.size()
  // Q4: orphans never keep a live site from issuing (they hold slots).
  val Q_orphansNeverCauseRefusal =
    e.refused == 0 or e.live.keys().forall(id => not(e.live.get(id).orphan)) or e.waiting.size() == 0

  // Witnesses (reachability: these should be violated as invariants).
  val W_noRefusal = e.refused == 0
  val W_noSkip = e.skipped == 0
  val W_noReReparent = e.reparented <= e.gOrphaned.size()
}

// The design's rules: `fx` gives each site any policy (27 assignments);
// the `fx_small_*` instances are small enough to search exhaustively.
module fx { import effects(BUG = "none", MAX_REQS = 4, MAX_STEPS = 5, POLICIES = Set("watch", "latest", "current")).* }
module fx_small_watch { import effects(BUG = "none", MAX_REQS = 3, MAX_STEPS = 3, POLICIES = Set("watch")).* }
module fx_small_latest { import effects(BUG = "none", MAX_REQS = 3, MAX_STEPS = 3, POLICIES = Set("latest")).* }
module fx_small_current { import effects(BUG = "none", MAX_REQS = 3, MAX_STEPS = 3, POLICIES = Set("current")).* }
// One instance per seeded defect.
module fx_reparent_scoped { import effects(BUG = "reparent-scoped", MAX_REQS = 4, MAX_STEPS = 5, POLICIES = Set("watch", "latest", "current")).* }
module fx_supersede_forgets { import effects(BUG = "supersede-forgets", MAX_REQS = 4, MAX_STEPS = 5, POLICIES = Set("watch", "latest", "current")).* }
module fx_orphan_writes_remount { import effects(BUG = "orphan-writes-remount", MAX_REQS = 4, MAX_STEPS = 5, POLICIES = Set("watch", "latest", "current")).* }
module fx_reuse_ids { import effects(BUG = "reuse-ids", MAX_REQS = 4, MAX_STEPS = 5, POLICIES = Set("watch", "latest", "current")).* }
module fx_cap_off_by_one { import effects(BUG = "cap-off-by-one", MAX_REQS = 4, MAX_STEPS = 5, POLICIES = Set("watch", "latest", "current")).* }
module fx_drop_uncounted { import effects(BUG = "drop-uncounted", MAX_REQS = 4, MAX_STEPS = 5, POLICIES = Set("watch", "latest", "current")).* }
module fx_dispose_keeps_table { import effects(BUG = "dispose-keeps-table", MAX_REQS = 4, MAX_STEPS = 5, POLICIES = Set("watch", "latest", "current")).* }
