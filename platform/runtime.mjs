// Browser runtime for the pure Roc engine (platform/Engine.roc). The engine
// decides everything; this file applies its command bytes to the DOM and
// routes DOM events back as (node id, handler number, payload bytes).
// Commands are read straight out of Wasm linear memory after each call; views
// are re-created per apply (a call may grow memory).
//
// Encoding: design.md, Appendix B, protocol version PROTOCOL_VERSION. A module
// whose `protocol_version()` differs is refused at mount.
//
// Event payloads (UTF-8, staged with `payload_reserve` and moved into Roc by
// `event`): click/submit "", input: the target's value, change: "true"/"false"
// for a checkbox or radio, else the target's value, keydown/keyup: the key.
// A `submit` event that reaches the mount root is always default-prevented:
// forms are app-managed and never navigate the page.
//
// Boot bytes carry the URL, the declared storage values, whether the browser
// is online and the page visible, and whether local storage is available at
// all (it is not when reaching or reading it throws); the `OnlineChanges` and
// `VisibilityChanges` subscriptions (FX kinds 6 and 7) report later changes.
//
// Ingress: events raised while a batch is applied are queued, at most
// MAX_QUEUED of them. Exceeding the bound poisons the runtime with class
// `resource_limit` (a feedback loop between the DOM and the engine); queued
// work is never dropped silently.
//
// Effects (see "Effects" in Engine.roc): the engine emits FX requests with
// ids, CANCEL, NAV, STORE and TITLE commands. They are collected while a
// batch is applied and performed only after the whole batch is applied.
// Each awaited result comes back as its own event on FX_NODE (one turn, in
// completion order). In manual mode (options.manualEffects) HTTP requests,
// timers and work jobs wait in `pending` until runEffect() answers or runs them and intervals
// tick only through tick(); the engine, not this file, decides staleness: a
// result for a cancelled subscription or timer is never sent because CANCEL
// forgets it here, and anything late is dropped by the engine and counted.
// The engine cancels an admitted HTTP request only when a superseding site
// (`latest`, `resource`) moves to a new value: CANCEL aborts the fetch and
// clears its timeout timer. Disposal never cancels one (it reparents), so
// a request that is not superseded is always answered.
//
// Work (FX kind 8): a pure program of the app's catalogue runs on bytes in a
// Web Worker that instantiates this same compiled module (`worker.mjs`,
// beside this file or at options.workerUrl). The pool holds at most
// options.maxWorkers workers (default min(hardwareConcurrency, 8)), one job
// each at a time; idle workers are reused and jobs beyond the pool wait in a
// FIFO queue that the engine's in-flight cap bounds. CANCEL removes a
// queued job and terminates a running job's worker (replaced lazily); a
// deadline does the same and answers `Timeout`. A worker whose instance
// faults is discarded and its job answered `WorkLost(class)`; the
// diagnostic goes to console.error and options.onWorkerFault, never into
// the result. Without a Worker constructor every job is `WorkLost
// (unavailable)`. options.workers === "inline" runs jobs on this thread in a
// second instance of the module instead, one at a time (a deadline then
// only stops a job that has not started). Poisoning or unmounting this
// runtime terminates every worker. In manual mode a job waits in `pending`
// until runEffect(id) runs it.
//
// Handler event names may carry a policy suffix: "click:prevent" listens to
// "click" and calls preventDefault when it dispatches (in-app links, forms).
//
// Attribute values: "" removes the attribute. `value` and `checked` are set
// as properties (the live control state), boolean attributes (disabled,
// selected, readonly, required, hidden, multiple) are present for any value
// other than "" and "false".

// The wire protocol version this runtime implements (design.md, Appendix B).
export const PROTOCOL_VERSION = 4;

// The most events queued behind a running batch (see "Ingress" above).
export const MAX_QUEUED = 4096;

// The engine's work counters start at this `metric` index (design.md,
// Appendix B); `workRecord()` decodes the whole record.
export const WORK_METRIC_BASE = 16;

const OP_INST = 1;
const OP_TEXT = 2;
const OP_HATTR = 3;
const OP_MOVE = 4;
const OP_REMOVE = 5;
const OP_CLEAR = 6;
const OP_TEMPLATE = 7;
const OP_ELEM = 8;
const OP_ATTR = 9;
const OP_TEXTNODE = 10;
const OP_LISTEN = 11;
const OP_SETTEXT = 12;

const OP_FX = 13;
const OP_CANCEL = 14;
const OP_NAV = 15;
const OP_STORE = 16;
const OP_TITLE = 17;
const OP_FOCUS = 18;

// Effect results are events on this node; the handler number is the id.
const FX_NODE = 0xffffffff;
const RES_HTTP = 1;
const RES_NETWORK = 2;
const RES_VALUE = 3;
const RES_MISSING = 4;
const RES_FIRED = 5;
const RES_LOCATION = 6;
const RES_TIMEOUT = 7;
const RES_ONLINE = 8;
const RES_VISIBLE = 9;
const RES_WORK = 10;
const RES_WORK_LOST = 11;

// Result tag 11's class byte: an instance's fault code (1-5) is its class.
const LOST_UNAVAILABLE = 6;
const LOST_EXECUTOR = 7;
const LOST_CLASSES = ["", "contract", "resource_limit", "out_of_memory", "app_crash", "expect_failed", "unavailable", "executor"];

const HOLE_TEXT = 1;
const HOLE_ATTR = 2;
const HOLE_CLICK = 3;
const HOLE_BIND = 4;


export async function instantiateEngineBytes(bytes) {
  return WebAssembly.instantiate(bytes, { env: {} });
}

export async function instantiateEngineWasm(url) {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`failed to fetch ${url}: ${response.status}`);
  return instantiateEngineBytes(await response.arrayBuffer());
}

const utf8 = new TextDecoder();

function readStr(u8, at, n) {
  if (n <= 32) {
    let s = "";
    for (let i = 0; i < n; i += 1) {
      const c = u8[at + i];
      if (c > 127) return utf8.decode(u8.subarray(at, at + n));
      s += String.fromCharCode(c);
    }
    return s;
  }
  return utf8.decode(u8.subarray(at, at + n));
}

function walk(root, path) {
  let node = root;
  for (let i = 0; i < path.length; i += 1) {
    node = node.firstChild;
    for (let k = path[i]; k > 0; k -= 1) node = node.nextSibling;
  }
  return node;
}

const BOOL_ATTRS = new Set(["disabled", "selected", "readonly", "required", "hidden", "multiple", "open"]);

const SVG_NS = "http://www.w3.org/2000/svg";

// Elements are created in the SVG namespace for <svg> and anything inside it.
function createIn(doc, tag, parent) {
  if (tag === "svg" || (parent && parent.namespaceURI === SVG_NS && parent.tagName !== "foreignObject")) return doc.createElementNS(SVG_NS, tag);
  return doc.createElement(tag);
}

function toSvg(doc, node) {
  if (node.nodeType !== 1) return node.cloneNode(true);
  const el = doc.createElementNS(SVG_NS, node.tagName.toLowerCase());
  for (const a of node.attributes) el.setAttribute(a.name, a.value);
  for (const c of node.childNodes) el.appendChild(toSvg(doc, c));
  return el;
}

// Controlled text values (design.md, "Controlled inputs"): an equal value is
// a no-op (caret and selection stay put); a differing value is deferred while
// the control is focused or composing (IME) and applied on blur, unless a
// later input echo already matched it.
function setValue(el, value) {
  if (el.value === value) {
    el.__deferred = undefined;
    return;
  }
  const doc = el.ownerDocument;
  if (el.__composing || (doc && doc.activeElement === el && el.tagName !== "SELECT")) {
    el.__deferred = value;
    return;
  }
  el.__deferred = undefined;
  el.value = value;
}

function setAttr(el, name, value) {
  if (name === "class" && el.namespaceURI === SVG_NS) {
    if (value === "") el.removeAttribute("class");
    else el.setAttribute("class", value);
  } else if (name === "class") {
    el.className = value;
  } else if (name === "value") {
    setValue(el, value);
    if (el.tagName === "SELECT") el.__v = value;
    if (value === "") el.removeAttribute("value");
    else el.setAttribute("value", value);
    // An option whose value changes may now be the one its select wants.
    if (el.tagName === "OPTION") settleSelect(el.parentNode);
  } else if (name === "checked") {
    el.checked = value === "true";
    if (el.checked) el.setAttribute("checked", "");
    else el.removeAttribute("checked");
  } else if (BOOL_ATTRS.has(name)) {
    if (value === "" || value === "false") el.removeAttribute(name);
    else el.setAttribute(name, "");
  } else if (value === "") {
    el.removeAttribute(name);
  } else {
    el.setAttribute(name, value);
  }
}

// A <select>'s value can only be set once its options exist: re-apply the
// desired value when an option is inserted below it.
function settleSelect(parent) {
  let p = parent;
  if (p && p.tagName === "OPTGROUP") p = p.parentNode;
  if (p && p.tagName === "SELECT" && p.__v !== undefined && p.value !== p.__v) p.value = p.__v;
}

const DOM_EVENT = { focus: "focusin", blur: "focusout" };
const APP_EVENT = { focusin: "focus", focusout: "blur" };

function payloadOf(event) {
  const t = event.target;
  switch (event.type) {
    case "focusin":
    case "focusout":
      return t.value ?? "";
    case "input":
      return t.value ?? "";
    case "change":
      if (t.type === "checkbox" || t.type === "radio") return t.checked ? "true" : "false";
      return t.value ?? "";
    case "keydown":
    case "keyup":
      return event.key;
    default:
      return "";
  }
}

const utf8enc = new TextEncoder();

function u32(v) {
  const b = new Uint8Array(4);
  new DataView(b.buffer).setUint32(0, v, true);
  return b;
}

function encStr(s) {
  const b = utf8enc.encode(s);
  return concat([u32(b.length), b]);
}

function concat(parts) {
  let n = 0;
  for (const p of parts) n += p.length;
  const out = new Uint8Array(n);
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}

// ---------------------------------------------------------------------------
// The monitor: observation of work jobs, worker instances and turns
// (design.md, "Observation"). It never decides anything: the pool and the
// runtime call it at each transition, after they have acted, and it keeps
// bounded aggregates, a bounded history and optional User Timing entries.
//
// Clocks: every time it reports is this page's `performance.now()` in ms. A
// worker stamps with its own clock and reports its `performance.timeOrigin`
// once, when its instance is ready; the monitor converts its stamps by
// adding `workerOrigin - pageOrigin`. Each stamp carries the browser's timer
// coarsening (0.1 ms when the page is not cross-origin isolated), so a span
// between two threads is good to about ±0.2 ms; spans are reported raw,
// never clamped, and one shorter than the resolution may read 0 or slightly
// negative.
//
// Bounds: live jobs are bounded by the engine's in-flight cap and live
// instances by `maxWorkers`; the rest is MONITOR_LIMITS (see each field).

// Histogram bucket edges in ms (1-2-5 series). Bucket i counts values below
// edges[i] and at least edges[i - 1]; the last bucket counts the rest.
export const MONITOR_EDGES = Object.freeze([0.1, 0.2, 0.5, 1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000]);

// history: the most job records `snapshot().recent` keeps (the option's
// maximum; oldest overwritten, counted in recentDropped). retired: ended
// instances kept (oldest overwritten, counted in retiredDropped). programs:
// per-program aggregates (the catalogue's bound; any further name is
// aggregated under "*"). subscribers: a further subscribe throws. timeline:
// roc entries held in the performance timeline; reaching it clears them
// (observers and DevTools traces have already seen them).
export const MONITOR_LIMITS = Object.freeze({ history: 1024, retired: 16, programs: 64, subscribers: 16, timeline: 1024 });

// The engine's effect counters in the work record (design.md, Appendix B),
// present when the record carries at least `ENGINE_FX_FIRST + 8` counters.
const ENGINE_FX_FIRST = 32;
const ENGINE_FX_NAMES = ["issued", "delivered", "stale", "refused", "cancelled", "reparented", "skipped", "live"];

const END_CAUSES = ["cancel", "deadline", "fault", "executor", "unmount", "contained"];

function newHist() {
  return { counts: new Array(MONITOR_EDGES.length + 1).fill(0), n: 0, sum: 0, min: null, max: null };
}

function addHist(h, v) {
  if (v === null || !Number.isFinite(v)) return;
  let i = 0;
  while (i < MONITOR_EDGES.length && v >= MONITOR_EDGES[i]) i += 1;
  h.counts[i] += 1;
  h.n += 1;
  h.sum += v;
  if (h.min === null || v < h.min) h.min = v;
  if (h.max === null || v > h.max) h.max = v;
}

function copyHist(h) {
  return { edges: MONITOR_EDGES, counts: [...h.counts], n: h.n, sum: h.sum, min: h.min, max: h.max };
}

const span = (a, b) => (a === null || b === null ? null : b - a);

// A ring of at most `cap` items, oldest first.
class Ring {
  constructor(cap) {
    this.cap = cap;
    this.items = [];
    this.at = 0;
    this.dropped = 0;
  }

  push(v) {
    if (this.cap === 0) {
      this.dropped += 1;
      return;
    }
    if (this.items.length < this.cap) this.items.push(v);
    else {
      this.items[this.at] = v;
      this.at = (this.at + 1) % this.cap;
      this.dropped += 1;
    }
  }

  list() {
    return this.items.slice(this.at).concat(this.items.slice(0, this.at));
  }

  clear() {
    this.items = [];
    this.at = 0;
    this.dropped = 0;
  }
}

export class WorkMonitor {
  // `options` is the `monitor` mount option: { history = 128 (0 to
  // MONITOR_LIMITS.history), userTiming = false, payloads = false }. `env`
  // adapts it to its runtime: `now()` and `performance` (a clock and User
  // Timing; default the global `performance`), `page()` (the page
  // instance's figures for a snapshot), `mode()` and `maxWorkers`.
  // A history outside its range is a programmer error and throws.
  constructor(options = {}, env = {}) {
    const history = options.history ?? 128;
    if (!Number.isInteger(history) || history < 0 || history > MONITOR_LIMITS.history) {
      throw new Error(`monitor.history must be an integer from 0 to ${MONITOR_LIMITS.history} (got ${history})`);
    }
    this.perf = env.performance ?? globalThis.performance ?? null;
    const perf = this.perf;
    this.now = env.now ?? (() => perf.now());
    this.origin = perf && typeof perf.timeOrigin === "number" ? perf.timeOrigin : 0;
    this.page = env.page ?? (() => null);
    this.mode = env.mode ?? (() => "workers");
    this.maxWorkers = env.maxWorkers ?? 0;
    this.userTiming = !!options.userTiming && !!perf && typeof perf.measure === "function";
    this.payloads = !!options.payloads;
    this.subs = [];
    this.turnSubs = 0;
    this.jobs = new Map();
    this.answered = new Set();
    this.insts = new Map();
    this.seq = 0;
    this.generation = 0;
    this.state = "new";
    this.ending = null;
    this.timeline = 0;
    this.timelineNames = new Set();
    this.recent = new Ring(history);
    this.retired = new Ring(MONITOR_LIMITS.retired);
    this.gauge = { instances: 0, spawning: 0, busy: 0, queued: 0 };
    this.lastAt = this.now();
    this.reset();
  }

  // -- Pull ---------------------------------------------------------------

  // Zero the aggregates (counts, peaks, integrals, histograms, per-program
  // figures and the job history) and start a new measurement window at
  // `snapshot().since`. Live jobs and instances are still tracked; peaks
  // restart from the current gauges.
  reset() {
    this.tick();
    this.since = this.lastAt;
    this.count = { issued: 0, done: 0, lost: 0, timeout: 0, cancelled: 0, unavailable: 0, lateReplies: 0, wastedMs: 0, inputBytes: 0, outputBytes: 0 };
    this.spawns = 0;
    this.ended = Object.fromEntries(END_CAUSES.map((c) => [c, 0]));
    this.peak = { instances: this.gauge.instances, busy: this.gauge.busy, queued: this.gauge.queued };
    this.integral = { busyMs: 0, aliveMs: 0, queuedMs: 0 };
    this.hist = { queue: newHist(), cold: newHist(), compute: newHist(), total: newHist(), resultTurn: newHist() };
    this.programs = new Map();
    this.recent.clear();
    this.retired.clear();
  }

  // Plain serialisable data (no BigInt, no bytes) describing the pool, its
  // jobs and instances since the last reset; see the worker-monitoring
  // documentation for every field. Cost: proportional to the history,
  // the retired instances and the programs held; nothing is computed until
  // it is called.
  snapshot() {
    this.tick();
    const programs = {};
    for (const [name, p] of this.programs) {
      programs[name] = { ...p, hist: { queue: copyHist(p.hist.queue), compute: copyHist(p.hist.compute), total: copyHist(p.hist.total) } };
    }
    let page = null;
    let engine = null;
    try {
      const pg = this.page();
      if (pg !== null) {
        const counters = pg.counters ?? [];
        page = { memBytes: pg.memBytes, liveAllocs: pg.liveAllocs, liveBytes: pg.liveBytes, turns: counters.length > 30 ? Number(counters[30]) : 0 };
        if (counters.length >= ENGINE_FX_FIRST + ENGINE_FX_NAMES.length) {
          engine = Object.fromEntries(ENGINE_FX_NAMES.map((n, i) => [n, Number(counters[ENGINE_FX_FIRST + i])]));
        }
      }
    } catch (_) {
      page = null;
      engine = null;
    }
    const g = this.gauge;
    return {
      version: 1,
      at: this.lastAt,
      since: this.since,
      generation: this.generation,
      state: this.state,
      mode: this.mode(),
      maxWorkers: this.maxWorkers,
      crossOriginIsolated: !!globalThis.crossOriginIsolated,
      pool: { instances: g.instances, spawning: g.spawning, idle: this.idle(), busy: g.busy, queued: g.queued, peak: { ...this.peak }, ...this.integral },
      jobs: { ...this.count, inFlight: this.jobs.size },
      instances: {
        spawns: this.spawns,
        respawns: Math.max(0, this.spawns - this.peak.instances),
        ended: { ...this.ended },
        live: [...this.insts.values()].map((i) => this.instRecord(i)),
        retired: this.retired.list(),
        retiredDropped: this.retired.dropped,
      },
      hist: Object.fromEntries(Object.entries(this.hist).map(([k, h]) => [k, copyHist(h)])),
      programs,
      recent: this.recent.list(),
      recentDropped: this.recent.dropped,
      page,
      engine,
    };
  }

  // -- Push ---------------------------------------------------------------

  // Call `listener(event)` synchronously at every lifecycle transition (the
  // event kinds are in the worker-monitoring documentation); with
  // `{ turns: true }` also once per turn (`turn` events). Returns the
  // function that unsubscribes. A listener must only observe: it may call
  // snapshot(), and one that throws is reported and unsubscribed. More than
  // MONITOR_LIMITS.subscribers listeners is a programmer error and throws.
  subscribe(listener, { turns = false } = {}) {
    if (typeof listener !== "function") throw new Error("monitor.subscribe needs a function");
    if (this.subs.length >= MONITOR_LIMITS.subscribers) throw new Error(`monitor: more than ${MONITOR_LIMITS.subscribers} subscribers`);
    const sub = { listener, turns: !!turns };
    this.subs.push(sub);
    if (sub.turns) this.turnSubs += 1;
    return () => this.unsubscribe(sub);
  }

  unsubscribe(sub) {
    const i = this.subs.indexOf(sub);
    if (i < 0) return;
    this.subs.splice(i, 1);
    if (sub.turns) this.turnSubs -= 1;
  }

  emit(event, turn = false) {
    if (this.subs.length === 0) return;
    for (const sub of [...this.subs]) {
      if (turn && !sub.turns) continue;
      try {
        sub.listener(event);
      } catch (e) {
        console.error(`roc monitor: a listener threw and was unsubscribed: ${e && e.stack ? e.stack : e}`);
        this.unsubscribe(sub);
      }
    }
  }

  // -- Gauges -------------------------------------------------------------

  tick() {
    const now = this.now();
    const dt = now - this.lastAt;
    if (dt > 0 && this.integral) {
      this.integral.aliveMs += dt * this.gauge.instances;
      this.integral.busyMs += dt * this.gauge.busy;
      this.integral.queuedMs += dt * this.gauge.queued;
    }
    this.lastAt = now;
    return now;
  }

  move(name, delta) {
    this.gauge[name] += delta;
    if (this.peak[name] !== undefined && this.gauge[name] > this.peak[name]) this.peak[name] = this.gauge[name];
  }

  // Ready instances holding no job (at most maxWorkers to count).
  idle() {
    let n = 0;
    for (const i of this.insts.values()) if (i.ready && i.job === null) n += 1;
    return n;
  }

  live() {
    return this.state === "mounted";
  }

  program(name) {
    let p = this.programs.get(name);
    if (p === undefined) {
      if (name !== "*" && this.programs.size >= MONITOR_LIMITS.programs) return this.program("*");
      p = { jobs: 0, done: 0, lost: 0, timeout: 0, cancelled: 0, unavailable: 0, inputBytes: 0, outputBytes: 0, hist: { queue: newHist(), compute: newHist(), total: newHist() } };
      this.programs.set(name, p);
    }
    return p;
  }

  // -- Runtime transitions (called by RocEngineRuntime) ---------------------

  // The runtime mounted (or recovered into) a fresh instance.
  runtimeMounted() {
    this.generation += 1;
    this.state = "mounted";
    this.ending = null;
    this.emit({ kind: "runtime", state: "mounted", at: this.tick(), generation: this.generation });
  }

  // The runtime is about to tear down (`contained` or `unmount`): cancels and
  // terminations reported until runtimeEnded are attributed to it.
  runtimeEnding(cause) {
    if (this.live()) this.ending = cause;
  }

  // Teardown is complete: every job and instance still tracked ends with
  // the teardown's cause, then the `runtime` event; nothing more is
  // reported until the runtime mounts again.
  runtimeEnded(state, fault = null) {
    if (this.state !== "mounted") {
      this.state = state;
      return;
    }
    if (this.ending === null) this.ending = state === "poisoned" ? "contained" : "unmount";
    for (const job of [...this.jobs.values()]) this.cancelJob(job);
    for (const inst of [...this.insts.values()]) this.endInstance(inst, this.ending, null);
    this.state = state;
    const event = { kind: "runtime", state, at: this.tick(), generation: this.generation };
    if (fault !== null) event.fault = { class: fault.class, message: fault.message };
    this.emit(event);
  }

  // Whether the turn about to run is timed: always for a job's result turn,
  // and for every turn while a subscriber asked for turns.
  timesTurn(node, handler) {
    return this.turnSubs > 0 || (node === FX_NODE && this.answered.has(handler));
  }

  // One timed turn: t0 before staging its payload, t1 after `event`, t2 after
  // the batch was applied and its effects performed.
  turn(node, handler, t0, t1, t2, bytes) {
    const job = node === FX_NODE && this.answered.has(handler) ? this.jobs.get(handler) : undefined;
    if (this.turnSubs > 0) {
      this.emit({ kind: "turn", node, handler, fx: job ? job.id : null, at: t2, eventMs: t1 - t0, applyMs: t2 - t1, bytes }, true);
    }
    if (job !== undefined) {
      job.t.turnStart = t0;
      job.t.turnEnd = t2;
      this.answered.delete(job.id);
      this.endJob(job, t2);
    }
  }

  // -- Job transitions ----------------------------------------------------

  // A work request was performed (`held`: manual mode keeps it pending until
  // runEffect). `input` is only kept for the event when payloads are on.
  jobIssued(id, program, input, deadlineMs, held) {
    if (!this.live()) return;
    const at = this.tick();
    const job = {
      id,
      program,
      instance: null,
      thread: null,
      outcome: null,
      fault: null,
      cancelledBy: null,
      phase: held ? "held" : "issued",
      cold: false,
      firstJobOnInstance: false,
      inputBytes: input.length,
      outputBytes: null,
      deadlineMs,
      wasted: false,
      output: null,
      t: { issue: at, submit: null, post: null, recv: null, begin: null, call: null, ret: null, sent: null, reply: null, turnStart: null, turnEnd: null, end: null },
    };
    this.jobs.set(id, job);
    this.count.issued += 1;
    this.count.inputBytes += input.length;
    const p = this.program(program);
    p.jobs += 1;
    p.inputBytes += input.length;
    const event = { kind: "job-issue", id, program, inputBytes: input.length, deadlineMs, at, held: !!held };
    if (this.payloads) event.input = input.slice();
    this.emit(event);
  }

  // The job was handed to the pool (its deadline starts now).
  jobSubmitted(id) {
    const job = this.jobs.get(id);
    if (job === undefined || !this.live()) return;
    job.t.submit = this.tick();
    job.phase = "queued";
    this.move("queued", 1);
  }

  // The pool posted the job to instance `seq` (ready or still starting).
  jobPosted(id, seq) {
    const job = this.jobs.get(id);
    const inst = this.insts.get(seq);
    if (job === undefined || inst === undefined || !this.live()) return;
    const at = this.tick();
    if (job.phase === "queued") this.move("queued", -1);
    job.t.post = at;
    job.instance = seq;
    job.thread = inst.thread;
    job.cold = !inst.ready;
    job.firstJobOnInstance = inst.jobs === 0;
    job.phase = inst.ready ? "running" : "starting";
    inst.job = id;
    inst.postAt = at;
    this.move("busy", 1);
    this.emit({ kind: "job-start", id, instance: seq, at, cold: job.cold });
  }

  // The instance answered the job. `reply` is { t: [recv, begin, call, ret,
  // sent], mem: [memBytes, liveAllocs, liveBytes], outputBytes } in the
  // instance's clock.
  jobReplied(id, seq, reply) {
    const job = this.jobs.get(id);
    const inst = this.insts.get(seq);
    if (job === undefined || inst === undefined || !this.live()) return;
    const at = this.tick();
    job.t.reply = at;
    if (reply && Array.isArray(reply.t) && reply.t.length === 5) {
      const [recv, begin, call, ret, sent] = reply.t.map((v) => v + inst.off);
      Object.assign(job.t, { recv, begin, call, ret, sent });
    }
    if (reply && typeof reply.outputBytes === "number") job.outputBytes = reply.outputBytes;
    if (reply && Array.isArray(reply.mem)) this.memory(inst, reply.mem);
    this.release(inst, at);
    inst.jobs += 1;
  }

  // The runtime decided the job's result and is delivering it as a turn:
  // `outcome` is done, lost, timeout or unavailable.
  jobAnswered(id, outcome, faultClass, output) {
    const job = this.jobs.get(id);
    if (job === undefined || !this.live()) return;
    this.tick();
    this.leave(job);
    job.outcome = outcome;
    job.fault = faultClass ?? null;
    if (this.payloads && output) job.output = output.slice();
    job.phase = "answered";
    this.answered.add(id);
  }

  // The job was cancelled (CANCEL, or the runtime's teardown).
  jobCancelled(id) {
    const job = this.jobs.get(id);
    if (job === undefined || !this.live()) return;
    this.cancelJob(job);
  }

  // A reply arrived for a job the pool no longer holds.
  lateReply() {
    this.count.lateReplies += 1;
  }

  cancelJob(job) {
    const at = this.tick();
    const phase = job.phase;
    this.leave(job);
    this.answered.delete(job.id);
    job.outcome = "cancelled";
    job.cancelledBy = this.ending ?? "engine";
    job.phase = phase === "issued" ? "queued" : phase;
    this.endJob(job, at);
  }

  // Take the job out of the queue gauge and off its instance, counting
  // compute thrown away when it was running.
  leave(job) {
    if (job.phase === "queued") this.move("queued", -1);
    if ((job.phase === "running" || job.phase === "starting") && job.t.reply === null) {
      this.waste(job, this.lastAt);
      const inst = this.insts.get(job.instance);
      if (inst !== undefined && inst.job === job.id) this.release(inst, this.lastAt);
    }
  }

  // A started job that will never reply: its time on the instance is lost.
  waste(job, at) {
    if (job.wasted || job.t.post === null || job.t.reply !== null) return;
    job.wasted = true;
    this.count.wastedMs += at - job.t.post;
  }

  release(inst, at) {
    if (inst.job === null) return;
    inst.job = null;
    inst.busyMs += at - inst.postAt;
    this.move("busy", -1);
  }

  endJob(job, at) {
    this.jobs.delete(job.id);
    job.t.end = at;
    const t = job.t;
    const ms = {
      held: span(t.issue, t.submit),
      queue: span(t.submit, t.post),
      toWorker: job.cold ? null : span(t.post, t.recv),
      cold: job.cold ? span(t.post, t.begin) : t.post === null ? null : 0,
      stage: span(t.begin, t.call),
      compute: span(t.call, t.ret),
      copyOut: span(t.ret, t.sent),
      fromWorker: span(t.sent, t.reply),
      resultWait: span(t.reply, t.turnStart),
      resultTurn: span(t.turnStart, t.turnEnd),
      total: span(t.issue, t.end),
    };
    const outcome = job.outcome;
    this.count[outcome] += 1;
    if (job.outputBytes !== null) this.count.outputBytes += job.outputBytes;
    const p = this.program(job.program);
    p[outcome] += 1;
    if (job.outputBytes !== null) p.outputBytes += job.outputBytes;
    if (outcome !== "cancelled") {
      addHist(this.hist.queue, ms.queue);
      addHist(p.hist.queue, ms.queue);
      if (job.cold) addHist(this.hist.cold, ms.cold);
      addHist(this.hist.compute, ms.compute);
      addHist(p.hist.compute, ms.compute);
      addHist(this.hist.total, ms.total);
      addHist(p.hist.total, ms.total);
      addHist(this.hist.resultTurn, ms.resultTurn);
    }
    const record = {
      id: job.id,
      program: job.program,
      instance: job.instance,
      thread: job.thread,
      outcome,
      fault: job.fault,
      cancelledBy: job.cancelledBy,
      phase: outcome === "cancelled" ? job.phase : null,
      cold: job.cold,
      firstJobOnInstance: job.firstJobOnInstance,
      inputBytes: job.inputBytes,
      outputBytes: job.outputBytes,
      deadlineMs: job.deadlineMs,
      t: { ...t },
      ms,
    };
    this.recent.push(record);
    if (this.userTiming) this.measureJob(record);
    const event = { kind: "job-end", id: job.id, program: job.program, outcome, at, record };
    if (this.payloads && job.output !== null) event.output = job.output;
    this.emit(event);
  }

  // -- Instance transitions -----------------------------------------------

  // The pool created an instance (`thread`: "worker" or "page"); returns
  // its sequence number, unique over the monitor's life.
  instanceSpawned(thread) {
    this.seq += 1;
    const seq = this.seq;
    if (!this.live()) return seq;
    const at = this.tick();
    this.insts.set(seq, {
      seq,
      thread,
      ready: false,
      job: null,
      postAt: 0,
      off: 0,
      spawnAt: at,
      scriptAt: null,
      readyAt: null,
      instantiateMs: null,
      jobs: 0,
      busyMs: 0,
      memBytes: null,
      peakMemBytes: null,
      liveAllocs: null,
      liveBytes: null,
    });
    this.spawns += 1;
    this.move("instances", 1);
    this.move("spawning", 1);
    this.emit({ kind: "instance-spawn", instance: seq, thread, at });
    return seq;
  }

  // The instance is instantiated. `ready` is { origin, instStart, instEnd,
  // memBytes } in the instance's clock (`origin` its performance.timeOrigin).
  instanceReady(seq, ready) {
    const inst = this.insts.get(seq);
    if (inst === undefined || inst.ready || !this.live()) return;
    const at = this.tick();
    inst.ready = true;
    inst.off = typeof ready.origin === "number" ? ready.origin - this.origin : 0;
    inst.scriptAt = inst.thread === "worker" ? inst.off : null;
    inst.readyAt = at;
    inst.instantiateMs = ready.instEnd - ready.instStart;
    this.memory(inst, [ready.memBytes, null, null]);
    this.move("spawning", -1);
    if (inst.job !== null) {
      const job = this.jobs.get(inst.job);
      if (job !== undefined && job.phase === "starting") job.phase = "running";
    }
    if (this.userTiming) this.measure(`roc:worker ${seq} spawn`, inst.spawnAt, at, { instance: seq, instantiateMs: inst.instantiateMs }, `worker ${seq}`);
    this.emit({ kind: "instance-ready", instance: seq, at, scriptAt: inst.scriptAt, instantiateMs: inst.instantiateMs, memBytes: inst.memBytes });
  }

  // The pool discarded the instance. `cause` is cancel, deadline, fault,
  // executor or shutdown; during the runtime's teardown it is the
  // teardown's cause. `fault` is { class, message } or null.
  instanceEnded(seq, cause, fault = null) {
    const inst = this.insts.get(seq);
    if (inst === undefined || !this.live()) return;
    this.endInstance(inst, this.ending ?? (cause === "shutdown" ? "unmount" : cause), fault);
  }

  endInstance(inst, cause, fault) {
    const at = this.tick();
    if (inst.job !== null) {
      const job = this.jobs.get(inst.job);
      if (job !== undefined) this.waste(job, at);
      this.release(inst, at);
    }
    if (!inst.ready) this.move("spawning", -1);
    this.insts.delete(inst.seq);
    this.move("instances", -1);
    this.ended[cause] += 1;
    const record = { ...this.instRecord(inst), state: "ended", endedAt: at, endedBy: cause, fault };
    this.retired.push(record);
    this.emit({ kind: "instance-end", instance: inst.seq, at, cause, fault, jobs: inst.jobs, busyMs: inst.busyMs, memBytes: inst.memBytes });
  }

  memory(inst, [memBytes, liveAllocs, liveBytes]) {
    if (typeof memBytes === "number") {
      inst.memBytes = memBytes;
      if (inst.peakMemBytes === null || memBytes > inst.peakMemBytes) inst.peakMemBytes = memBytes;
    }
    if (typeof liveAllocs === "number") inst.liveAllocs = liveAllocs;
    if (typeof liveBytes === "number") inst.liveBytes = liveBytes;
  }

  instRecord(i) {
    return {
      seq: i.seq,
      thread: i.thread,
      state: !i.ready ? "spawning" : i.job !== null ? "busy" : "idle",
      spawnAt: i.spawnAt,
      scriptAt: i.scriptAt,
      readyAt: i.readyAt,
      instantiateMs: i.instantiateMs,
      jobs: i.jobs,
      busyMs: i.busyMs,
      memBytes: i.memBytes,
      peakMemBytes: i.peakMemBytes,
      liveAllocs: i.liveAllocs,
      liveBytes: i.liveBytes,
      endedAt: null,
      endedBy: null,
      fault: null,
    };
  }

  // -- User Timing ----------------------------------------------------------

  measureJob(r) {
    const t = r.t;
    const lane = r.instance === null ? "jobs" : `worker ${r.instance}`;
    this.measure(`roc:work ${r.program}`, t.issue, t.end, { id: r.id, instance: r.instance, outcome: r.outcome, inputBytes: r.inputBytes, outputBytes: r.outputBytes }, "jobs");
    if (t.submit !== null && t.post !== null) this.measure("roc:work.queue", t.submit, t.post, { id: r.id }, "jobs");
    if (r.cold && t.begin !== null) this.measure("roc:work.cold", t.post, t.begin, { id: r.id, instance: r.instance }, lane);
    if (t.post !== null && t.reply !== null) this.measure("roc:work.run", t.post, t.reply, { id: r.id, instance: r.instance }, lane);
    if (t.reply !== null && t.turnEnd !== null) this.measure("roc:work.result", t.reply, t.turnEnd, { id: r.id }, "jobs");
  }

  measure(name, start, end, detail, track) {
    if (this.timeline >= MONITOR_LIMITS.timeline) {
      for (const n of this.timelineNames) this.perf.clearMeasures(n);
      this.timelineNames.clear();
      this.timeline = 0;
    }
    try {
      this.perf.measure(name, { start, end, detail: { ...detail, devtools: { dataType: "track-entry", track, trackGroup: "roc workers", color: "primary" } } });
      this.timeline += 1;
      this.timelineNames.add(name);
    } catch (_) {
      // A timeline that refuses an entry loses only that entry.
    }
  }
}

// The bounded pool that runs work jobs (see "Work" above). It knows nothing
// about ids, results or the engine: `submit` takes a payload
// (`name:str input:rest`) and a callback that receives exactly one outcome,
// `{ output }` or `{ lost, message }`, unless the job is cancelled first.
class WorkPool {
  constructor({ module, url, max, inline, Worker: W }) {
    this.module = module;
    this.url = url;
    this.max = Math.max(1, max);
    this.inline = inline;
    this.W = W;
    this.slots = [];
    this.queue = [];
    this.created = 0;
    this.terminated = 0;
    this.instance = null;
    this.running = false;
    this.closed = false;
  }

  // Returns the job's cancel function.
  submit(payload, done) {
    const job = { payload, done, slot: null, settled: false, timer: null };
    if (!this.module || (!this.inline && typeof this.W !== "function")) {
      const message = this.module ? "this browser has no Worker" : "the runtime was mounted without its compiled module";
      job.timer = setTimeout(() => this.settle(job, { lost: LOST_UNAVAILABLE, message }), 0);
      return () => this.cancel(job);
    }
    this.queue.push(job);
    this.pump();
    return () => this.cancel(job);
  }

  settle(job, outcome) {
    if (job.settled || this.closed) return;
    job.settled = true;
    job.done(outcome);
  }

  cancel(job) {
    if (job.settled) return;
    job.settled = true;
    if (job.timer !== null) clearTimeout(job.timer);
    const q = this.queue.indexOf(job);
    if (q >= 0) this.queue.splice(q, 1);
    if (job.slot !== null) this.discard(job.slot);
    this.pump();
  }

  pump() {
    if (this.closed) return;
    if (this.inline) {
      if (this.queue.length > 0 && !this.running) this.runInline();
      return;
    }
    while (this.queue.length > 0) {
      let slot = this.slots.find((s) => s.job === null);
      if (!slot) {
        if (this.slots.length >= this.max) return;
        slot = this.spawn();
        if (slot === null) return;
      }
      const job = this.queue.shift();
      slot.job = job;
      job.slot = slot;
      slot.worker.postMessage({ type: "job", payload: job.payload.buffer }, [job.payload.buffer]);
    }
  }

  spawn() {
    let worker;
    try {
      worker = new this.W(this.url, { type: "module" });
    } catch (e) {
      // The script cannot even be started: every queued job is lost.
      for (const job of this.queue.splice(0)) this.settle(job, { lost: LOST_EXECUTOR, message: `worker could not start: ${e}` });
      return null;
    }
    const slot = { worker, job: null };
    this.created += 1;
    worker.onmessage = (event) => this.answer(slot, event.data);
    worker.onerror = (event) => {
      if (event && typeof event.preventDefault === "function") event.preventDefault();
      this.lose(slot, LOST_EXECUTOR, `worker script failed: ${event && event.message ? event.message : "error"}`);
    };
    worker.onmessageerror = () => this.lose(slot, LOST_EXECUTOR, "worker message could not be read");
    worker.postMessage({ type: "init", module: this.module, version: PROTOCOL_VERSION });
    this.slots.push(slot);
    return slot;
  }

  answer(slot, m) {
    const job = slot.job;
    if (job === null || !this.slots.includes(slot)) return;
    if (m.type === "done") {
      slot.job = null;
      job.slot = null;
      this.settle(job, { output: new Uint8Array(m.output) });
      this.pump();
    } else {
      this.lose(slot, m.code >= 1 && m.code <= 5 ? m.code : LOST_EXECUTOR, m.message);
    }
  }

  // The worker can no longer be trusted: discard it and lose its job.
  lose(slot, lost, message) {
    const job = slot.job;
    this.discard(slot);
    if (job !== null) {
      job.slot = null;
      this.settle(job, { lost, message });
    }
    this.pump();
  }

  discard(slot) {
    const i = this.slots.indexOf(slot);
    if (i < 0) return;
    this.slots.splice(i, 1);
    slot.worker.terminate();
    this.terminated += 1;
    if (slot.job !== null) slot.job.slot = null;
    slot.job = null;
  }

  // Inline mode: a second instance of the module on this thread, one job at
  // a time, each in a task of its own.
  async runInline() {
    this.running = true;
    try {
      while (!this.closed && this.queue.length > 0) {
        await new Promise((r) => setTimeout(r, 0));
        const job = this.queue.shift();
        if (job === undefined || job.settled || this.closed) continue;
        let x = null;
        try {
          if (this.instance === null) {
            this.instance = await WebAssembly.instantiate(this.module, { env: {} });
            this.created += 1;
          }
          if (job.settled || this.closed) continue;
          x = this.instance.exports;
          const ptr = x.payload_reserve(job.payload.length);
          if (job.payload.length > 0) new Uint8Array(x.memory.buffer, ptr, job.payload.length).set(job.payload);
          x.work();
          const output = new Uint8Array(x.memory.buffer, x.cmd_ptr(), x.cmd_len()).slice();
          this.settle(job, { output });
        } catch (e) {
          let code = 0;
          let message = String(e && e.message ? e.message : e);
          try {
            code = x ? x.fault() : 0;
            if (code !== 0) message = new TextDecoder().decode(new Uint8Array(x.memory.buffer, x.err_ptr(), x.err_len()));
          } catch (_) {
            code = 0;
          }
          // A faulted instance is never called again.
          this.instance = null;
          this.terminated += 1;
          this.settle(job, { lost: code >= 1 && code <= 5 ? code : LOST_EXECUTOR, message });
        }
      }
    } finally {
      this.running = false;
    }
  }

  stats() {
    return { workers: this.slots.length, busy: this.slots.filter((s) => s.job !== null).length, queued: this.queue.length, created: this.created, terminated: this.terminated };
  }

  // Containment and unmount: every worker stops and no outcome is delivered.
  shutdown() {
    this.closed = true;
    for (const job of this.queue.splice(0)) job.settled = true;
    for (const slot of [...this.slots]) {
      if (slot.job !== null) slot.job.settled = true;
      this.discard(slot);
    }
    this.instance = null;
  }
}

function httpResult(status, body, headers = []) {
  const parts = [new Uint8Array([RES_HTTP, status & 0xff, (status >>> 8) & 0xff]), u32(headers.length)];
  for (const [k, v] of headers) parts.push(encStr(k), encStr(v));
  parts.push(utf8enc.encode(body));
  return concat(parts);
}

export class RocEngineRuntime {
  constructor(exports, root, options = {}) {
    this.x = exports;
    this.root = root;
    this.doc = options.document ?? globalThis.document;
    this.statics = [];
    this.sites = [];
    this.templates = [];
    this.listening = new Map();
    this.internal = [];
    this.onEvent = (event) => this.handle(event);
    this.timing = options.timing ?? null;
    this.busy = false;
    this.queue = [];
    this.poisoned = null;
    this.refused = 0;
    this.onFault = options.onFault ?? null;
    this.module = options.module ?? null;
    this.manual = options.manualEffects ?? false;
    // Intervals tick only through tick(id) (spec replays control time).
    this.manualIntervals = options.manualIntervals ?? false;
    // Armed HTTP timeout timers (for tests: must return to 0).
    this.timers = 0;
    this.fxOut = [];
    // id -> { kind, req, cancel } for every effect this runtime holds.
    this.live = new Map();
    // Manual mode: awaited non-subscription requests in issue order.
    this.issued = [];
    this.win = options.window ?? globalThis.window;
    // HTTP requests go through options.fetch when one is given (an embedding
    // page's scripted backend; it may answer synchronously), else the
    // global fetch.
    this.fetch = options.fetch ?? null;
    // Work (see "Work" above): the pool is made on the first job.
    this.pool = null;
    this.workerUrl = options.workerUrl ?? new URL("./worker.mjs", import.meta.url);
    this.workerMode = options.workers ?? "worker";
    if (this.workerMode !== "worker" && this.workerMode !== "inline") throw new Error(`workers: ${JSON.stringify(this.workerMode)} is not "worker" or "inline"`);
    const nav = this.win ? this.win.navigator : globalThis.navigator;
    this.maxWorkers = options.maxWorkers ?? Math.min((nav && nav.hardwareConcurrency) || 4, 8);
    this.onWorkerFault = options.onWorkerFault ?? null;
    this.storage = options.storage ?? (() => {
      try {
        return this.win.localStorage;
      } catch (_) {
        return null;
      }
    })();
  }

  // Boot: check the protocol version, read the app's declared storage keys,
  // stage the URL, their values and the online, visibility and storage
  // flags, then
  // mount. A module that speaks another protocol is refused before anything
  // runs: the runtime throws and never applies a command it cannot read.
  mount() {
    const version = typeof this.x.protocol_version === "function" ? this.x.protocol_version() : 0;
    if (version !== PROTOCOL_VERSION) {
      throw new Error(`roc engine protocol ${version} is not the protocol ${PROTOCOL_VERSION} this runtime implements`);
    }
    this.guard(() => this.mountInner());
    this.drainQueue();
  }

  mountInner() {
    this.controlListeners();
    this.listen("click");
    const x = this.x;
    x.boot_keys();
    const u8 = new Uint8Array(x.memory.buffer, x.cmd_ptr(), x.cmd_len());
    const dv = new DataView(u8.buffer, u8.byteOffset, u8.byteLength);
    const keys = [];
    let at = 4;
    for (let i = dv.getUint32(0, true); i > 0; i -= 1) {
      const n = dv.getUint32(at, true);
      keys.push(readStr(u8, at + 4, n));
      at += 4 + n;
    }
    // Storage is unavailable when there is none or any read throws; then
    // the app boots with no stored values rather than some of them.
    let storageOk = !!this.storage && typeof this.storage.getItem === "function";
    const pairs = [];
    for (const k of keys) {
      if (!storageOk) break;
      try {
        const v = this.storage.getItem(k);
        if (v !== null) pairs.push([k, v]);
      } catch (_) {
        storageOk = false;
      }
    }
    if (!storageOk) pairs.length = 0;
    const loc = this.win ? this.win.location : null;
    const url = loc ? loc.pathname + loc.search + loc.hash : "";
    const parts = [encStr(url), u32(pairs.length)];
    for (const [k, v] of pairs) parts.push(encStr(k), encStr(v));
    parts.push(new Uint8Array([this.isOnline() ? 1 : 0, this.isVisible() ? 1 : 0, storageOk ? 1 : 0]));
    this.stage(concat(parts));
    this.busy = true;
    try {
      x.init();
      this.apply();
    } finally {
      this.busy = false;
    }
  }

  // ---------------------------------------------------------------------
  // Containment (design.md, "Memory management and allocation failure",
  // "Browser execution and external failure"). Any trap or executor failure
  // poisons this runtime: the diagnostic is read from the instance's
  // reserved storage (fresh memory view), listeners and asynchronous work
  // are detached, staged commands and queued events are dropped, the last
  // committed DOM stays as fallback, and every later call is refused
  // without re-entering Wasm. recover() mounts a fresh instance.

  guard(fn) {
    if (this.poisoned) {
      this.refused += 1;
      return null;
    }
    try {
      return fn();
    } catch (e) {
      this.contain(e);
      return null;
    }
  }

  // `klass` names a fault the runtime itself classifies (the ingress bound);
  // otherwise the instance's fault class decides, and a trap the instance
  // did not classify is an executor failure.
  contain(error, klass = null) {
    if (this.poisoned) return;
    const CLASSES = ["executor", "contract", "resource_limit", "out_of_memory", "app_crash", "expect_failed"];
    let code = 0;
    let message = String(error && error.message ? error.message : error);
    if (klass !== null) {
      code = CLASSES.indexOf(klass);
    } else {
      try {
        code = this.x.fault();
        if (code !== 0) message = new TextDecoder().decode(new Uint8Array(this.x.memory.buffer, this.x.err_ptr(), this.x.err_len()));
      } catch (_) {
        code = 0;
      }
    }
    this.poisoned = { class: CLASSES[code] ?? "unknown", code, message, trap: String(error) };
    for (const [type, fn] of this.listening) this.root.removeEventListener(type, fn);
    this.listening.clear();
    for (const [type, fn] of this.internal) this.root.removeEventListener(type, fn, true);
    this.internal = [];
    for (const e of this.live.values()) {
      try {
        e.cancel();
      } catch (_) {
        // teardown is best effort and never re-enters Wasm
      }
    }
    this.live.clear();
    this.stopWorkers();
    this.queue = [];
    this.fxOut = [];
    console.error(`roc engine fault [${this.poisoned.class}]: ${message}`);
    if (this.onFault) this.onFault(this.poisoned);
  }

  // A fresh instance from the same module; the poisoned one is abandoned.
  async recover() {
    if (!this.module) throw new Error("recover() needs the compiled module (mountRocEngineApp keeps it)");
    const instance = await WebAssembly.instantiate(this.module, { env: {} });
    this.x = instance.exports;
    this.root.textContent = "";
    this.statics = [];
    this.sites = [];
    this.templates = [];
    this.live = new Map();
    this.issued = [];
    this.queue = [];
    this.fxOut = [];
    this.busy = false;
    this.poisoned = null;
    this.mount();
    return this;
  }

  unmount() {
    for (const id of [...this.live.keys()]) this.cancel(id);
    this.stopWorkers();
    for (const [type, fn] of this.listening) this.root.removeEventListener(type, fn);
    this.listening.clear();
    for (const [type, fn] of this.internal) this.root.removeEventListener(type, fn, true);
    this.internal = [];
    this.x.drop();
    this.root.textContent = "";
    this.statics = [];
    this.sites = [];
    this.templates = [];
  }

  // Controlled-input bookkeeping: composition flags, deferred values applied
  // on blur, and input echoes that make a deferred value moot. Runs before
  // (capture) and independently of the app's own handlers.
  controlListeners() {
    const on = (type, fn) => {
      this.root.addEventListener(type, fn, true);
      this.internal.push([type, fn]);
    };
    on("compositionstart", (e) => {
      e.target.__composing = true;
    });
    on("compositionend", (e) => {
      e.target.__composing = false;
    });
    on("input", (e) => {
      const t = e.target;
      if (t.__deferred !== undefined && t.__deferred === t.value) t.__deferred = undefined;
    });
    on("focusout", (e) => {
      const t = e.target;
      t.__composing = false;
      if (t.__deferred !== undefined) {
        const v = t.__deferred;
        t.__deferred = undefined;
        if (t.value !== v) t.value = v;
      }
    });
  }

  // One delegated listener per event type, added the first time a LISTEN
  // command or template hole names that type.
  // App "focus"/"blur" handlers listen to the bubbling focusin/focusout.
  listen(type) {
    const dom = DOM_EVENT[type] ?? type;
    if (this.listening.has(dom)) return;
    this.listening.set(dom, this.onEvent);
    this.root.addEventListener(dom, this.onEvent);
  }

  // The nearest handler for this event type walking up from the target
  // (bubbling), then the nearest node carrying an engine id.
  handle(event) {
    const type = APP_EVENT[event.type] ?? event.type;
    // Forms are app-managed: a submit never navigates (design.md,
    // "Controlled inputs").
    if (event.type === "submit") event.preventDefault();
    let node = event.target;
    // Handler numbers are stored as -1 - h when the handler asks for
    // preventDefault.
    let handler = null;
    while (node && node !== this.root) {
      if (handler === null && node.__h !== undefined) {
        const h = node.__h[type];
        if (h !== undefined) handler = h;
      }
      if (node.__rn !== undefined && handler !== null) {
        if (handler < 0) {
          event.preventDefault();
          handler = -1 - handler;
        }
        this.dispatch(node.__rn, handler, payloadOf(event), node);
        return;
      }
      node = node.parentNode;
    }
  }

  // Events raised while a batch is being applied (or while Wasm runs) are
  // queued and delivered in order after it; they never re-enter.
  // `el` (DOM events only): a queued event is dropped if its element left
  // the DOM or its node id was recycled meanwhile (ids are reused).
  dispatch(node, handler, payload, el) {
    if (this.poisoned) {
      this.refused += 1;
      return;
    }
    if (this.busy) {
      if (this.queue.length >= MAX_QUEUED) {
        this.contain(new Error(`resource_limit: more than ${MAX_QUEUED} events queued behind one batch (an event feedback loop)`), "resource_limit");
        return;
      }
      this.queue.push([node, handler, payload, el]);
      return;
    }
    this.busy = true;
    try {
      this.guard(() => this.deliver(node, handler, payload));
    } finally {
      this.busy = false;
    }
    this.drainQueue();
  }

  drainQueue() {
    while (!this.busy && !this.poisoned && this.queue.length > 0) {
      const [n, h, p, el] = this.queue.shift();
      if (el !== undefined && (!el.isConnected || el.__rn !== n)) continue;
      this.busy = true;
      try {
        this.guard(() => this.deliver(n, h, p));
      } finally {
        this.busy = false;
      }
    }
  }

  stage(payload) {
    if (payload === "" || payload.length === 0) {
      this.x.payload_reserve(0);
      return;
    }
    const bytes = typeof payload === "string" ? utf8enc.encode(payload) : payload;
    const ptr = this.x.payload_reserve(bytes.length);
    new Uint8Array(this.x.memory.buffer, ptr, bytes.length).set(bytes);
  }

  deliver(node, handler, payload) {
    if (globalThis.__trace) console.log("event", node, handler, JSON.stringify(payload));
    const t = this.timing;
    this.stage(payload);
    if (t === null) {
      this.x.event(node, handler);
      this.apply();
      return;
    }
    const t0 = t.clock();
    this.x.event(node, handler);
    const t1 = t.clock();
    const bytes = this.apply();
    const t2 = t.clock();
    t.record(t1 - t0, t2 - t1, bytes);
  }

  // One dense node id space (rows included); rows also carry their site
  // (el.__site) and are tracked per site so CLEAR can forget them.
  lookup(node) {
    return node === 0 ? this.root : this.statics[node];
  }

  place(el, parent, before) {
    if (before === 0) this.lookup(parent).appendChild(el);
    else {
      const b = this.lookup(before);
      b.parentNode.insertBefore(el, b);
    }
  }

  parseTemplate(u8, dv, start, len) {
    let at = start;
    const doc = this.doc;
    const str = () => {
      const n = dv.getUint32(at, true);
      at += 4;
      const s = readStr(u8, at, n);
      at += n;
      return s;
    };
    const node = (parent) => {
      const kind = u8[at++];
      if (kind === 2) return doc.createTextNode(str());
      const el = createIn(doc, str(), parent);
      const attrs = u8[at++];
      for (let i = 0; i < attrs; i += 1) {
        const name = str();
        setAttr(el, name, str());
      }
      const children = u8[at++];
      for (let i = 0; i < children; i += 1) el.appendChild(node(el));
      return el;
    };
    // Templates are parsed as HTML; a row template first placed under an SVG
    // parent is re-created in the SVG namespace once (see INST).
    const root = node(null);
    const holes = [];
    const count = u8[at++];
    for (let i = 0; i < count; i += 1) {
      const kind = u8[at++];
      const depth = u8[at++];
      const path = Array.from(u8.subarray(at, at + depth));
      at += depth;
      const hole = { kind, path, name: null, handler: 0 };
      if (kind === HOLE_ATTR) hole.name = str();
      else if (kind === HOLE_CLICK) {
        hole.handler = u8[at++];
        hole.name = str();
        this.listen(hole.name.split(":")[0]);
      }
      holes.push(hole);
    }
    if (at !== start + len) throw new Error("template length mismatch");
    return { root, holes };
  }

  // Returns the number of command bytes applied. Effect commands found in
  // the batch run after the whole batch has been applied.
  apply() {
    const n = this.applyBatch();
    if (this.fxOut.length > 0) {
      const out = this.fxOut;
      this.fxOut = [];
      for (const fx of out) this.perform(fx);
    }
    return n;
  }

  applyBatch() {
    const x = this.x;
    const len = x.cmd_len();
    if (len === 0) return 0;
    const buffer = x.memory.buffer;
    const ptr = x.cmd_ptr();
    const u8 = new Uint8Array(buffer, ptr, len);
    const dv = new DataView(buffer, ptr, len);
    const doc = this.doc;
    let at = 0;
    while (at < len) {
      const op = u8[at];
      at += 1;
      switch (op) {
        case OP_INST: {
          const node = dv.getUint32(at, true);
          const parent = dv.getUint32(at + 4, true);
          const before = dv.getUint32(at + 8, true);
          const site = dv.getUint32(at + 12, true);
          const tpl = this.templates[site];
          at += 16;
          if (!tpl.svg && tpl.root.namespaceURI !== SVG_NS) {
            const p = before === 0 ? this.lookup(parent) : this.lookup(before).parentNode;
            if (p.namespaceURI === SVG_NS && p.tagName !== "foreignObject") {
              tpl.root = toSvg(doc, tpl.root);
              tpl.svg = true;
            }
          }
          const el = tpl.root.cloneNode(true);
          el.__rn = node;
          const holes = tpl.holes;
          // Hole targets are resolved once, here: a nested site inserting
          // content into the row later shifts sibling indices.
          const targets = new Array(holes.length);
          for (let i = 0; i < holes.length; i += 1) targets[i] = walk(el, holes[i].path);
          el.__ht = targets;
          for (let i = 0; i < holes.length; i += 1) {
            const hole = holes[i];
            const target = targets[i];
            if (hole.kind === HOLE_TEXT) {
              const n = dv.getUint32(at, true);
              target.nodeValue = readStr(u8, at + 4, n);
              at += 4 + n;
            } else if (hole.kind === HOLE_ATTR) {
              const n = dv.getUint32(at, true);
              setAttr(target, hole.name, readStr(u8, at + 4, n));
              at += 4 + n;
            } else if (hole.kind === HOLE_CLICK) {
              if (target.__h === undefined) target.__h = {};
              const [type, policy] = hole.name.split(":");
              target.__h[type] = policy === "prevent" ? -1 - hole.handler : hole.handler;
            } else {
              this.statics[dv.getUint32(at, true)] = target;
              at += 4;
            }
          }
          this.place(el, parent, before);
          if (el.tagName === "OPTION") settleSelect(el.parentNode);
          el.__site = site;
          this.statics[node] = el;
          this.sites[site].add(node);
          break;
        }
        case OP_TEXT:
        case OP_HATTR: {
          const node = dv.getUint32(at, true);
          const row = this.lookup(node);
          const hole = this.templates[row.__site].holes[u8[at + 4]];
          const n = dv.getUint32(at + 5, true);
          const target = row.__ht[u8[at + 4]];
          const v = readStr(u8, at + 9, n);
          if (op === OP_TEXT) target.nodeValue = v;
          else setAttr(target, hole.name, v);
          at += 9 + n;
          break;
        }
        case OP_MOVE: {
          const el = this.lookup(dv.getUint32(at, true));
          const before = dv.getUint32(at + 4, true);
          el.parentNode.insertBefore(el, before === 0 ? null : this.lookup(before));
          at += 8;
          break;
        }
        case OP_REMOVE: {
          const node = dv.getUint32(at, true);
          const el = this.lookup(node);
          el.parentNode.removeChild(el);
          if (el.__site !== undefined) this.sites[el.__site].delete(node);
          this.statics[node] = undefined;
          at += 4;
          break;
        }
        case OP_CLEAR: {
          const parent = this.lookup(dv.getUint32(at, true));
          const site = dv.getUint32(at + 4, true);
          for (const n of this.sites[site]) this.statics[n] = undefined;
          this.sites[site] = new Set();
          parent.textContent = "";
          at += 8;
          break;
        }
        case OP_TEMPLATE: {
          const tpl = dv.getUint32(at, true);
          const n = dv.getUint32(at + 4, true);
          this.templates[tpl] = this.parseTemplate(u8, dv, at + 8, n);
          this.sites[tpl] = new Set();
          at += 8 + n;
          break;
        }
        case OP_ELEM:
        case OP_TEXTNODE: {
          const node = dv.getUint32(at, true);
          const parent = dv.getUint32(at + 4, true);
          const before = dv.getUint32(at + 8, true);
          const n = dv.getUint32(at + 12, true);
          const s = readStr(u8, at + 16, n);
          at += 16 + n;
          const parentEl = before === 0 ? this.lookup(parent) : this.lookup(before).parentNode;
          const el = op === OP_ELEM ? createIn(doc, s, parentEl) : doc.createTextNode(s);
          this.place(el, parent, before);
          if (op === OP_ELEM && el.tagName === "OPTION") settleSelect(el.parentNode);
          this.statics[node] = el;
          break;
        }
        case OP_ATTR: {
          const el = this.lookup(dv.getUint32(at, true));
          const n = dv.getUint32(at + 4, true);
          const name = readStr(u8, at + 8, n);
          at += 8 + n;
          const m = dv.getUint32(at, true);
          setAttr(el, name, readStr(u8, at + 4, m));
          at += 4 + m;
          break;
        }
        case OP_LISTEN: {
          const node = dv.getUint32(at, true);
          const el = this.statics[node];
          const n = dv.getUint32(at + 8, true);
          const type = readStr(u8, at + 12, n);
          el.__rn = node;
          if (el.__h === undefined) el.__h = {};
          const [base, policy] = type.split(":");
          const h = dv.getUint32(at + 4, true);
          el.__h[base] = policy === "prevent" ? -1 - h : h;
          this.listen(base);
          at += 12 + n;
          break;
        }
        case OP_SETTEXT: {
          const el = this.lookup(dv.getUint32(at, true));
          const n = dv.getUint32(at + 4, true);
          el.nodeValue = readStr(u8, at + 8, n);
          at += 8 + n;
          break;
        }
        case OP_FX: {
          const id = dv.getUint32(at, true);
          const kind = u8[at + 4];
          at += 5;
          const str = () => {
            const n = dv.getUint32(at, true);
            const v = readStr(u8, at + 4, n);
            at += 4 + n;
            return v;
          };
          if (kind === 1) {
            const method = str();
            const url = str();
            const headers = [];
            let n = dv.getUint32(at, true);
            at += 4;
            for (; n > 0; n -= 1) headers.push([str(), str()]);
            const body = str();
            const timeout = dv.getUint32(at, true);
            at += 4;
            this.fxOut.push({ op: "http", id, method, url, headers, body, timeout });
          } else if (kind === 2) {
            this.fxOut.push({ op: "get", id, key: str() });
          } else if (kind === 3 || kind === 4) {
            this.fxOut.push({ op: kind === 3 ? "timer" : "interval", id, ms: dv.getUint32(at, true) });
            at += 4;
          } else if (kind === 5) {
            this.fxOut.push({ op: "popstate", id });
          } else if (kind === 6) {
            this.fxOut.push({ op: "online", id });
          } else if (kind === 7) {
            this.fxOut.push({ op: "visibility", id });
          } else if (kind === 8) {
            const program = str();
            const n = dv.getUint32(at, true);
            // Copied out: linear memory may move before the job is posted.
            const input = u8.slice(at + 4, at + 4 + n);
            const deadline = dv.getUint32(at + 4 + n, true);
            at += 8 + n;
            this.fxOut.push({ op: "work", id, program, input, deadline });
          } else throw new Error(`unknown effect kind ${kind}`);
          break;
        }
        case OP_CANCEL:
          this.fxOut.push({ op: "cancel", id: dv.getUint32(at, true) });
          at += 4;
          break;
        case OP_NAV: {
          const mode = u8[at];
          const n = dv.getUint32(at + 1, true);
          this.fxOut.push({ op: mode === 1 ? "push" : "replace", url: readStr(u8, at + 5, n) });
          at += 5 + n;
          break;
        }
        case OP_STORE: {
          const mode = u8[at];
          const n = dv.getUint32(at + 1, true);
          const key = readStr(u8, at + 5, n);
          at += 5 + n;
          if (mode === 1) {
            const m = dv.getUint32(at, true);
            this.fxOut.push({ op: "set", key, value: readStr(u8, at + 4, m) });
            at += 4 + m;
          } else this.fxOut.push({ op: "remove", key });
          break;
        }
        case OP_FOCUS: {
          this.fxOut.push({ op: "focus", mode: u8[at], node: dv.getUint32(at + 1, true) });
          at += 5;
          break;
        }
        case OP_TITLE: {
          const n = dv.getUint32(at, true);
          this.fxOut.push({ op: "title", text: readStr(u8, at + 4, n) });
          at += 4 + n;
          break;
        }
        default:
          throw new Error(`unknown engine command ${op} at byte ${at - 1}`);
      }
    }
    return len;
  }

  // ---------------------------------------------------------------------
  // Effects.

  result(id, bytes) {
    this.dispatch(FX_NODE, id, bytes);
  }

  perform(fx) {
    const w = this.win;
    switch (fx.op) {
      case "push":
        w.history.pushState(null, "", fx.url);
        return;
      case "replace":
        w.history.replaceState(null, "", fx.url);
        return;
      case "title":
        w.document.title = fx.text;
        return;
      case "focus": {
        // After the batch: the element exists. Focus events this raises are
        // queued (busy) and delivered as their own turns.
        const el = this.lookup(fx.node);
        if (!el) return;
        if (fx.mode === 2) el.blur();
        else {
          el.focus();
          if (fx.mode === 3 && typeof el.select === "function") el.select();
        }
        return;
      }
      case "set":
      case "remove":
        try {
          if (fx.op === "set") this.storage.setItem(fx.key, fx.value);
          else this.storage.removeItem(fx.key);
        } catch (e) {
          // A storage write failure is a host diagnostic, not an app result.
          console.warn(`storage ${fx.op} ${fx.key} failed: ${e}`);
        }
        return;
      case "cancel":
        this.cancel(fx.id);
        return;
      case "popstate": {
        const fn = () => {
          const l = w.location;
          this.result(fx.id, concat([new Uint8Array([RES_LOCATION]), utf8enc.encode(l.pathname + l.search + l.hash)]));
        };
        w.addEventListener("popstate", fn);
        this.live.set(fx.id, { kind: "sub", cancel: () => w.removeEventListener("popstate", fn) });
        return;
      }
      case "online": {
        const fn = () => this.result(fx.id, new Uint8Array([RES_ONLINE, this.isOnline() ? 1 : 0]));
        w.addEventListener("online", fn);
        w.addEventListener("offline", fn);
        this.live.set(fx.id, {
          kind: "sub",
          req: fx,
          cancel: () => {
            w.removeEventListener("online", fn);
            w.removeEventListener("offline", fn);
          },
        });
        return;
      }
      case "visibility": {
        const doc = this.doc;
        const fn = () => this.result(fx.id, new Uint8Array([RES_VISIBLE, this.isVisible() ? 1 : 0]));
        doc.addEventListener("visibilitychange", fn);
        this.live.set(fx.id, { kind: "sub", req: fx, cancel: () => doc.removeEventListener("visibilitychange", fn) });
        return;
      }
      case "interval": {
        if (this.manual || this.manualIntervals) {
          // Manual mode: ticks only through tick(id).
          this.live.set(fx.id, { kind: "sub", req: fx, cancel: () => {} });
          return;
        }
        const h = setInterval(() => this.result(fx.id, new Uint8Array([RES_FIRED])), fx.ms);
        this.live.set(fx.id, { kind: "sub", req: fx, cancel: () => clearInterval(h) });
        return;
      }
      case "get": {
        // One turn later, never inside the current call.
        const h = setTimeout(() => {
          this.live.delete(fx.id);
          let v = null;
          try {
            v = this.storage ? this.storage.getItem(fx.key) : null;
          } catch (_) {
            v = null;
          }
          this.result(fx.id, v === null ? new Uint8Array([RES_MISSING]) : concat([new Uint8Array([RES_VALUE]), utf8enc.encode(v)]));
        }, 0);
        this.live.set(fx.id, { kind: "get", cancel: () => clearTimeout(h) });
        return;
      }
      case "work":
        if (this.manual) {
          this.live.set(fx.id, { kind: "work", req: fx, cancel: () => {} });
          this.issued.push(fx.id);
          return;
        }
        this.startWork(fx, null);
        return;
      case "timer":
      case "http": {
        if (this.manual) {
          this.live.set(fx.id, { kind: fx.op, req: fx, cancel: () => {} });
          this.issued.push(fx.id);
          return;
        }
        if (fx.op === "timer") {
          const h = setTimeout(() => {
            this.live.delete(fx.id);
            this.result(fx.id, new Uint8Array([RES_FIRED]));
          }, fx.ms);
          this.live.set(fx.id, { kind: "timer", cancel: () => clearTimeout(h) });
          return;
        }
        // One abort controller and at most one timeout timer per admitted
        // request (bounded by the engine's in-flight cap); the timer is
        // cleared on completion, failure, timeout or cancel.
        const ctl = new AbortController();
        let timer = null;
        const done = () => {
          if (timer === null) return;
          clearTimeout(timer);
          timer = null;
          this.timers -= 1;
        };
        if (fx.timeout > 0) {
          this.timers += 1;
          timer = setTimeout(() => {
            if (!this.live.has(fx.id)) return;
            this.live.delete(fx.id);
            done();
            ctl.abort();
            this.result(fx.id, new Uint8Array([RES_TIMEOUT]));
          }, fx.timeout);
        }
        this.live.set(fx.id, {
          kind: "http",
          req: fx,
          cancel: () => {
            done();
            ctl.abort();
          },
        });
        const init = { method: fx.method, headers: fx.headers, signal: ctl.signal };
        if (fx.method !== "GET" && fx.method !== "HEAD" && fx.body !== "") init.body = fx.body;
        const send = this.fetch ?? globalThis.fetch;
        new Promise((resolve) => resolve(send(fx.url, init)))
          .then(async (r) => {
            const body = await r.text();
            if (!this.live.has(fx.id)) return;
            this.live.delete(fx.id);
            done();
            this.result(fx.id, httpResult(r.status, body, [...r.headers]));
          })
          .catch((e) => {
            if (!this.live.has(fx.id)) return; // cancelled or timed out
            this.live.delete(fx.id);
            done();
            this.result(fx.id, concat([new Uint8Array([RES_NETWORK]), utf8enc.encode(String(e))]));
          });
        return;
      }
      default:
        throw new Error(`unknown effect ${fx.op}`);
    }
  }

  // Hand job `fx` to the pool. Its one result (output, WorkLost or, at the
  // deadline, Timeout) is delivered as a turn unless CANCEL forgets it
  // first; `settled`, when given, is called once either way.
  startWork(fx, settled) {
    let timer = null;
    let stop = null;
    let open = true;
    const close = () => {
      if (!open) return false;
      open = false;
      if (timer !== null) {
        clearTimeout(timer);
        timer = null;
        this.timers -= 1;
      }
      if (settled) settled();
      return true;
    };
    const entry = {
      kind: "work",
      req: fx,
      running: true,
      cancel: () => {
        if (stop) stop();
        close();
      },
    };
    this.live.set(fx.id, entry);
    const finish = (bytes) => {
      if (this.live.get(fx.id) !== entry) return;
      this.live.delete(fx.id);
      open = false;
      if (timer !== null) {
        clearTimeout(timer);
        timer = null;
        this.timers -= 1;
      }
      this.result(fx.id, bytes);
      if (settled) settled();
    };
    if (fx.deadline > 0) {
      this.timers += 1;
      timer = setTimeout(() => {
        timer = null;
        this.timers -= 1;
        if (stop) stop();
        finish(new Uint8Array([RES_TIMEOUT]));
      }, fx.deadline);
    }
    stop = this.workPool().submit(concat([encStr(fx.program), fx.input]), (outcome) => {
      if (outcome.output !== undefined) {
        finish(concat([new Uint8Array([RES_WORK]), outcome.output]));
        return;
      }
      const klass = LOST_CLASSES[outcome.lost] ?? "executor";
      console.error(`roc worker fault [${klass}] in program "${fx.program}": ${outcome.message}`);
      if (this.onWorkerFault) this.onWorkerFault({ id: fx.id, program: fx.program, class: klass, message: outcome.message });
      finish(new Uint8Array([RES_WORK_LOST, outcome.lost]));
    });
  }

  workPool() {
    if (this.pool === null) {
      const W = (this.win && this.win.Worker) ?? globalThis.Worker;
      this.pool = new WorkPool({ module: this.module, url: this.workerUrl, max: this.maxWorkers, inline: this.workerMode === "inline", Worker: W });
    }
    return this.pool;
  }

  // Terminate every worker (containment, unmount); a later job starts a
  // fresh pool.
  stopWorkers() {
    if (this.pool !== null) this.pool.shutdown();
    this.pool = null;
  }

  // The worker pool's size and history, for tests and measurements.
  workerStats() {
    return this.pool === null ? { workers: 0, busy: 0, queued: 0, created: 0, terminated: 0 } : this.pool.stats();
  }

  cancel(id) {
    const e = this.live.get(id);
    if (e === undefined) return;
    this.live.delete(id);
    e.cancel();
  }

  // Manual mode: awaited requests still pending, in issue order.
  pendingEffects() {
    return this.issued.filter((id) => this.live.has(id) && !this.live.get(id).running).map((id) => this.live.get(id).req ?? { id });
  }

  // Manual mode: answer pending request `id` with an HTTP response
  // ({ status, body }), a network failure ({ network: message }) or a timer
  // tick ({}), or run a pending work job. Returns false when `id` is not
  // pending (cancelled/answered).
  // A pending work job takes no answer: it really runs, and the returned
  // promise resolves (true) once its result turn has been delivered, or once
  // it was cancelled instead.
  runEffect(id, answer = {}) {
    if (this.poisoned || !this.live.has(id)) return false;
    const e = this.live.get(id);
    if (e.running) return false;
    if (e.kind === "work") {
      this.live.delete(id);
      return new Promise((resolve) => this.startWork(e.req, () => resolve(true)));
    }
    this.live.delete(id);
    if (answer.timeout) this.result(id, new Uint8Array([RES_TIMEOUT]));
    else if (answer.network !== undefined) this.result(id, concat([new Uint8Array([RES_NETWORK]), utf8enc.encode(answer.network)]));
    else if (answer.status !== undefined) this.result(id, httpResult(answer.status, answer.body ?? "", answer.headers ?? []));
    else this.result(id, new Uint8Array([RES_FIRED]));
    return true;
  }

  // Manual mode: one tick of a live interval subscription.
  tick(id) {
    const e = this.live.get(id);
    if (e === undefined || e.kind !== "sub") return false;
    this.result(id, new Uint8Array([RES_FIRED]));
    return true;
  }

  // Deliver a result for an arbitrary id, bypassing this runtime's own
  // bookkeeping (stale-result tests: the engine must drop and count it).
  injectResult(id, status, body) {
    this.result(id, httpResult(status, body));
  }

  liveRows(site = 1) {
    return (this.sites[site] ?? new Set()).size;
  }

  isOnline() {
    const nav = this.win ? this.win.navigator : null;
    return nav ? nav.onLine !== false : true;
  }

  isVisible() {
    return !this.doc || this.doc.visibilityState !== "hidden";
  }

  // Live interval subscriptions with period `ms`, in issue order.
  intervals(ms) {
    const out = [];
    for (const [id, e] of this.live) if (e.kind === "sub" && e.req && e.req.op === "interval" && e.req.ms === ms) out.push(id);
    return out;
  }

  // The engine's work record after the last call (design.md, Appendix B):
  // { counters: [BigInt...], cleanups: Map(name -> BigInt) }.
  workRecord() {
    const x = this.x;
    const len = x.work_len();
    const out = { counters: [], cleanups: new Map() };
    if (len === 0) return out;
    const dv = new DataView(x.memory.buffer, x.work_ptr(), len);
    const u8 = new Uint8Array(x.memory.buffer, x.work_ptr(), len);
    let at = 4;
    for (let i = dv.getUint32(0, true); i > 0; i -= 1) {
      out.counters.push(dv.getBigUint64(at, true));
      at += 8;
    }
    let n = dv.getUint32(at, true);
    at += 4;
    for (; n > 0; n -= 1) {
      const k = dv.getUint32(at, true);
      const name = readStr(u8, at + 4, k);
      at += 4 + k;
      out.cleanups.set(name, dv.getBigUint64(at, true));
      at += 8;
    }
    return out;
  }
}

export async function mountRocEngineApp({ wasmUrl, root, ...options }) {
  const response = await fetch(wasmUrl);
  if (!response.ok) throw new Error(`failed to fetch ${wasmUrl}: ${response.status}`);
  const module = await WebAssembly.compile(await response.arrayBuffer());
  const instance = await WebAssembly.instantiate(module, { env: {} });
  const runtime = new RocEngineRuntime(instance.exports, root, { ...options, module });
  runtime.mount();
  return runtime;
}
