// The ingress queue's rules over generated sessions (design.md,
// "Re-entrancy", "Reports and occurrences" and "Boundedness"). A seeded
// generator drives the real runtime's dispatch, drains, frames, timers,
// cancellation and view-transition hand-off, with its `Ingress` given a
// bound of 2 or 3 so a few inputs fill it. Only the Wasm call (`deliver`),
// the browser's frame, timer and transition callbacks and the root are
// fake. A delivered turn may raise reports and occurrences, cancel a
// source or leave a view transition waiting, as a batch can.
//
// After every input the two budgets must hold; after every step an idle
// runtime must hold only waiting reports, with a drain scheduled. At the
// end the recorded deliveries must satisfy the rules the queue keeps:
// FIFO by joining order, an occurrence after every earlier report with its
// newest value and before every later one, nothing non-lossy dropped short
// of a poison, no delivery from a cancelled source, and a poison only from
// a real feedback loop: a raised budget that is full on its own, or a
// drain's turn budget. A small reference model of the source index checks
// each replacement as it happens.
//
// `node tests/runtime/ingress-unit.mjs [SEEDS]` (default 10000 per bound).
import { RocEngineRuntime, Ingress, FRAME_WAIT_MS } from "../../platform/runtime.mjs";

const SEEDS = Number(process.argv[2] ?? 10000);
const STEPS = 30;
const MAX_INPUTS = 24;

// mulberry32: a small seeded generator, so a failing seed replays exactly.
const generator = (seed) => {
  let a = seed >>> 0;
  return (n) => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return (((t ^ (t >>> 14)) >>> 0) % n);
  };
};

// The frame-wait timer is the browser's; the test owns it.
const timers = new Map();
let timerId = 0;
globalThis.setTimeout = (fn, ms) => { timers.set(++timerId, { fn, ms }); return timerId; };
globalThis.clearTimeout = (id) => { timers.delete(id); };
const quietError = console.error;

const events = { addEventListener() {}, removeEventListener() {} };
const fakeRoot = () => ({ nodeType: 1, namespaceURI: "http://www.w3.org/1999/xhtml", prefix: null, localName: "div", hasAttributeNS: () => false, ...events, textContent: "" });

const RAISED_POISON = (bound) => `resource_limit: more than ${bound} events raised since the runtime left idle are waiting (an event feedback loop)`;
const TURN_POISON = (bound) => `resource_limit: more than ${bound} turns for events raised since the runtime left idle in one drain (an event feedback loop)`;

const session = (bound, seed, witness) => {
  const rand = generator(seed * 2 + bound);
  timers.clear();
  const frames = new Map();
  let frameId = 0;
  const win = { ...events, requestAnimationFrame: (cb) => { frames.set(++frameId, cb); return frameId; }, cancelAnimationFrame: (id) => { frames.delete(id); } };
  const rt = new RocEngineRuntime({ drop() {}, fault: () => 0 }, fakeRoot(), { document: { ...events }, window: win, environment: { visible: () => true } });
  rt.queue = new Ingress(bound);
  const problems = [];
  const fail = (rule, detail) => { if (problems.length < 4) problems.push(`${rule}: ${detail}`); };

  let clock = 0, inputs = 0, depth = 0, draining = 0, nextSource = 1;
  const live = new Set();
  const addSource = () => { const id = nextSource++; live.add(id); rt.live.set(id, { cancel() {} }); };
  for (let i = 0; i < 3; i += 1) addSource();
  // The reference index: each source's replaceable entry of the current
  // epoch, by the clock at which it joined.
  const current = new Map();
  const delivered = [], reports = [], occurrences = [], cancelledAt = new Map();
  let poison = null;

  const queued = () => { const out = []; for (let e = rt.queue.head; e !== null; e = e.next) out.push(e); return out; };
  const waiting = () => queued().filter((e) => e.payload !== null).map((e) => e.payload);
  const idle = () => !rt.busy && !rt.poisoned && depth === 0;

  const bounds = (where) => {
    const q = rt.queue;
    if (q.length > 2 * bound) fail("boundHolds", `${where}: ${q.length} entries`);
    if (q.raised > bound) fail("boundHolds", `${where}: ${q.raised} raised`);
    if (q.waiting > bound) fail("boundHolds", `${where}: ${q.waiting} waiting`);
  };
  // `indexSound`: one replaceable entry per source, and the index names it.
  const index = (where) => {
    const all = queued();
    for (const [source, entry] of rt.queue.sources) {
      if (!all.includes(entry) || entry.source !== source || entry.payload === null) fail("indexSound", `${where}: index of ${source} names no live queued entry`);
      if (!live.has(source)) fail("indexSound", `${where}: index of cancelled ${source}`);
    }
    const seen = new Set();
    for (const e of all) {
      if (e.source === undefined || e.payload === null || e.epoch !== rt.queue.epoch) continue;
      if (seen.has(e.source)) fail("indexSound", `${where}: two current entries of ${e.source}`);
      seen.add(e.source);
      if (rt.queue.sources.get(e.source) !== e) fail("indexSound", `${where}: current entry of ${e.source} not indexed`);
    }
  };

  const report = () => {
    const src = [...live][rand(live.size)];
    if (src === undefined) return;
    const seq = ++clock;
    inputs += 1;
    const replace = current.has(src);
    const payload = { report: true, src, seq, first: replace ? current.get(src) : seq };
    if (!replace) current.set(src, seq);
    const before = rt.poisoned;
    const said = rt.report(src, payload);
    if (!before && said !== undefined) reports.push({ src, seq });
    if (said === true && !replace) fail("indexSound", `report ${seq} of ${src} replaced an entry the source no longer had`);
    if (said === false && replace) fail("indexSound", `report ${seq} of ${src} queued beside its current entry`);
    if (said === true) witness.replaced += 1;
    bounds(`report ${seq}`);
  };
  const occurrence = () => {
    const seq = ++clock;
    inputs += 1;
    // An occurrence pins every earlier report.
    current.clear();
    if (!rt.poisoned) occurrences.push(seq);
    if (idle() && rt.queue.length >= bound) witness.early += 1;
    rt.dispatch(1, 0, { report: false, seq, first: seq });
    bounds(`occurrence ${seq}`);
  };
  const cancel = () => {
    const src = [...live][rand(live.size)];
    if (src === undefined) return;
    cancelledAt.set(src, ++clock);
    current.delete(src);
    live.delete(src);
    rt.cancel(src);
    // CANCEL releases every waiting payload of the source at once.
    for (const e of queued()) if (e.source === src && e.payload !== null) fail("deadNeverDelivered", `cancel of ${src} left a payload queued`);
  };
  const transition = () => {
    // The runtime's waiting-transition record, as `applyTransition` makes it.
    const t = {
      phase: "waiting", applied: false, cancelled: false, transition: null, timer: null, resolve() {},
      batch: { definitions: new Map(), spans: new Map(), types: [] },
      update(cause = "callback", drain = true) {
        if (t.applied || rt.pendingTransition !== t) return;
        t.applied = true; t.phase = "applying";
        if (cause === "queue") witness.forced += 1;
        rt.pendingTransition = null;
        rt.busy = false;
        if (drain) rt.drainQueue();
      },
    };
    rt.pendingTransition = t;
  };
  // What a turn's batch may do synchronously. A batch that starts a view
  // transition leaves it waiting when its call returns, after everything
  // else the batch raised.
  const reentrant = () => {
    const count = [0, 0, 0, 0, 1, 1, 2, 3][rand(8)];
    let starts = false;
    for (let i = 0; i < count && inputs < MAX_INPUTS && !rt.poisoned; i += 1) {
      const pick = rand(10);
      if (pick < 4) report();
      else if (pick < 8) occurrence();
      else if (pick < 9) cancel();
      else starts = rt.pendingTransition === null;
    }
    if (starts && !rt.poisoned) transition();
  };

  rt.deliver = (_node, _handler, payload) => {
    const at = ++clock;
    delivered.push({ ...payload, at });
    if (payload.report && current.get(payload.src) === payload.first) current.delete(payload.src);
    depth += 1;
    try { reentrant(); } finally { depth -= 1; }
  };
  const drainQueue = rt.drainQueue.bind(rt);
  rt.drainQueue = (...args) => { draining += 1; try { return drainQueue(...args); } finally { draining -= 1; } };
  const contain = rt.contain.bind(rt);
  rt.contain = (error, klass) => {
    if (!rt.poisoned) poison = { message: String(error?.message ?? error), depth, draining, raised: rt.queue.raised };
    console.error = () => {};
    try { contain(error, klass); } finally { console.error = quietError; }
  };

  for (let step = 0; step < STEPS && !rt.poisoned; step += 1) {
    const pick = rand(16);
    if (inputs < MAX_INPUTS && pick < 5) report();
    else if (inputs < MAX_INPUTS && pick < 8) occurrence();
    else if (pick < 10) { const due = [...frames.values()]; frames.clear(); for (const cb of due) cb(); }
    else if (pick < 11) { for (const [id, t] of [...timers]) if (t.ms === FRAME_WAIT_MS) { timers.delete(id); t.fn(); } }
    else if (pick < 12) cancel();
    else if (pick < 13) addSource();
    else if (rt.pendingTransition !== null) rt.pendingTransition.update();
    if (rt.poisoned) break;
    bounds(`step ${step}`);
    index(`step ${step}`);
    if (idle()) {
      if (rt.queue.length > bound) fail("boundHolds", `idle with ${rt.queue.length} entries`);
      // `idleHoldsOnlyWaitingReports` and `noStrandedReport`.
      for (const e of queued()) if (e.payload !== null && (e.source === undefined || e.epoch !== rt.queue.epoch)) fail("idleHoldsOnlyWaitingReports", `step ${step}: ${e.payload.report ? "a pinned report" : "an occurrence"} ${e.payload.seq} waits while idle`);
      if (rt.queue.length > 0 && rt.reportDrain === null) fail("noStrandedReport", `step ${step}: ${rt.queue.length} entries and no drain scheduled`);
    }
  }

  const rest = rt.poisoned ? [] : waiting();
  const everything = delivered.concat(rest);
  // `fifo`: entries leave in the order they joined.
  for (let i = 1; i < delivered.length; i += 1) if (!(delivered[i - 1].first < delivered[i].first)) fail("fifo", `${delivered[i - 1].seq} then ${delivered[i].seq}`);
  for (const w of rest) if (delivered.length > 0 && !(delivered.at(-1).first < w.first)) fail("fifo", `${w.seq} waits behind a later delivery`);
  // `pinned`: a report that joined before an occurrence holds a value from before it.
  for (const r of everything) for (const o of everything) if (r.report && !o.report && r.first < o.first && !(r.seq < o.seq)) fail("pinned", `report ${r.seq} joined before occurrence ${o.seq}`);
  // `newestBeforeOccurrence`.
  for (const o of delivered) {
    if (o.report) continue;
    const sources = new Set(reports.map((r) => r.src));
    for (const src of sources) {
      const newest = reports.filter((r) => r.src === src && r.seq < o.seq).reduce((m, r) => Math.max(m, r.seq), -1);
      const gone = cancelledAt.has(src) && cancelledAt.get(src) < o.at;
      if (newest >= 0 && !gone && !delivered.some((r) => r.report && r.src === src && r.seq === newest && r.at < o.at)) fail("newestBeforeOccurrence", `occurrence ${o.seq} before report ${newest} of ${src}`);
    }
  }
  if (!rt.poisoned) {
    // `occurrencesKept` and `newestReportKept`.
    for (const seq of occurrences) if (!everything.some((o) => !o.report && o.seq === seq)) fail("occurrencesKept", `occurrence ${seq} lost`);
    for (const src of live) {
      const newest = reports.filter((r) => r.src === src).reduce((m, r) => Math.max(m, r.seq), -1);
      if (newest >= 0 && !everything.some((r) => r.report && r.src === src && r.seq === newest)) fail("newestReportKept", `report ${newest} of ${src} lost`);
    }
  }
  // `deadNeverDelivered`.
  for (const r of delivered) if (r.report && cancelledAt.has(r.src) && !(r.at < cancelledAt.get(r.src))) fail("deadNeverDelivered", `report ${r.seq} of cancelled ${r.src}`);
  // `poisonOnlyWhenRunning`: a raised budget full on its own, while a turn
  // runs, or a drain's turn budget; never waiting entries.
  if (poison !== null) {
    if (poison.message === RAISED_POISON(bound)) {
      witness.raisedPoison += 1;
      if (poison.depth === 0 || poison.raised !== bound) fail("poisonOnlyWhenRunning", `raised-budget poison at depth ${poison.depth} with ${poison.raised} raised`);
    } else if (poison.message === TURN_POISON(bound)) {
      witness.turnPoison += 1;
      if (poison.depth !== 0 || poison.draining === 0) fail("poisonOnlyWhenRunning", "turn-budget poison outside a drain");
    } else fail("poisonOnlyWhenRunning", `unexpected fault ${poison.message}`);
  }
  rt.unmount();
  return problems;
};

let failed = 0;
for (const bound of [2, 3]) {
  const witness = { early: 0, forced: 0, replaced: 0, raisedPoison: 0, turnPoison: 0 };
  for (let seed = 0; seed < SEEDS; seed += 1) {
    const problems = session(bound, seed, witness);
    if (problems.length > 0) {
      failed += 1;
      if (failed <= 5) console.log(`FAIL bound ${bound} seed ${seed}: ${problems.join("; ")}`);
    }
  }
  // The generator reaches the paths that matter: early drains at a full
  // idle queue, transitions forced to apply, replacements and both poisons.
  const missing = ["early", "forced", "replaced", "raisedPoison", "turnPoison"].filter((k) => witness[k] === 0);
  if (missing.length > 0) { failed += 1; console.log(`FAIL bound ${bound}: the generator never reached ${missing.join(", ")}`); }
  console.log(`bound ${bound}: ${SEEDS} seeds, ${JSON.stringify(witness)}`);
}

// The native spec runner's ingress model must deliver what this runtime
// delivers. Its `expect`s replay scripts at bound 3 (`ingress_replay` in
// platform/SpecRunner.roc, under `roc test`) against the deliveries
// recorded there; this replays the same scripts here. A script is
// space-separated steps: `rN` a report from source N, `o` an occurrence,
// `f` a frame, `cN` a cancel of source N. Step k (from 1) carries k, and a
// delivery is `handler:k`. `--emit-differential COUNT` prints fresh
// scripts with this runtime's deliveries.
const replayScript = (script) => {
  const rt = new RocEngineRuntime({ drop() {}, fault: () => 0 }, fakeRoot(), { manualEffects: true, document: { ...events }, window: { ...events }, environment: { visible: () => true } });
  rt.queue = new Ingress(3);
  for (const id of [1, 2, 3, 4]) rt.live.set(id, { cancel() {} });
  const out = [];
  rt.deliver = (_node, handler, payload) => { out.push(`${handler}:${payload}`); };
  script.split(" ").forEach((op, at) => {
    const k = at + 1;
    if (op === "f") rt.releaseReports();
    else if (op === "o") rt.result(9000, k);
    else if (op[0] === "r") rt.report(Number(op.slice(1)), k);
    else if (op[0] === "c") rt.cancel(Number(op.slice(1)));
    else throw new Error(`unknown ingress script step ${op}`);
  });
  if (rt.poisoned) out.push("poisoned");
  rt.unmount();
  return out.join(" ");
};
const emit = process.argv.indexOf("--emit-differential");
if (emit >= 0) {
  const rand = generator(7);
  for (let i = 0; i < Number(process.argv[emit + 1]); i += 1) {
    const ops = [];
    for (let n = 0; n < 14 + rand(10); n += 1) { const p = rand(12); ops.push(p < 7 ? `r${1 + rand(4)}` : p < 10 ? "o" : p < 11 ? "f" : `c${1 + rand(4)}`); }
    const script = ops.join(" ");
    console.log(`\tingress_replay("${script}") == "${replayScript(script)}",`);
  }
} else {
  const roc = (await import("node:fs")).readFileSync(new URL("../../platform/SpecRunner.roc", import.meta.url), "utf8");
  const cases = [...roc.matchAll(/ingress_replay\("([^"]*)"\) == "([^"]*)"/g)];
  if (cases.length === 0) { failed += 1; console.log("FAIL differential: no ingress_replay cases in SpecRunner.roc"); }
  for (const [, script, want] of cases) {
    const got = replayScript(script);
    if (got !== want) { failed += 1; console.log(`FAIL differential "${script}": runtime delivers "${got}", the native model "${want}"`); }
  }
  console.log(`differential: ${cases.length} scripts replayed against the native model's recorded deliveries`);
}
if (failed > 0) process.exitCode = 1;
else console.log("ingress-unit: all pass");
