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
// Work (FX kind 8): a job of a task of the app's catalogue runs in a Web
// Worker that instantiates this same compiled module (`worker.mjs`,
// beside this file or at options.workerUrl). The pool holds at most
// options.maxWorkers workers (default min(hardwareConcurrency, 8)), one job
// each at a time; idle workers are reused and jobs beyond the pool wait in a
// FIFO queue that the engine's in-flight cap bounds. CANCEL removes a
// queued job and terminates a running job's worker (replaced lazily),
// unless the task says `Finish`: that job runs on with its answer dropped,
// until its deadline (ten minutes when it has none), which then terminates
// its worker. A deadline does the same to a job not cancelled and answers
// `Timeout`. A worker whose instance
// faults is discarded and its job answered `WorkLost(class)`; the
// diagnostic goes to console.error and options.onWorkerFault, never into
// the result. Without a Worker constructor every job is `WorkLost
// (unavailable)`. options.workers === "inline" runs jobs on this thread in a
// second instance of the module instead, one at a time (a deadline then
// only stops a job that has not started). The hosted effects a job may
// call (reading a file, building one) exist only in a worker, so a job
// that reaches one there is answered `WorkLost(unavailable)`, and the
// inline instance it left mid-call is replaced for the next job, as a
// faulted worker is; a job that reaches none answers as in a worker.
// Poisoning or unmounting this
// runtime terminates every worker. In manual mode a job waits in `pending`
// until runEffect(id) runs it, loseEffect(id, class) answers it lost or
// expireEffect(id) expires its deadline, which never fires on its own.
// options.manualWork holds work jobs the same way while every other effect
// runs on its own.
//
// Monitor: `runtime.monitor` (options.monitor) observes jobs, worker
// instances and turns: a pull snapshot, push events and optional User
// Timing entries, all bounded (see "The monitor" below). The pool and this
// runtime report to it after they act; it decides nothing.
//
// Handler event names may carry suffixes: "click:prevent" listens to
// "click" and calls preventDefault when it dispatches (in-app links, forms);
// ":files" makes the payload the event's files (a file input's `change`, a
// `drop`, a `paste`) instead of text. A "drop" handler with ":files" also
// prevents `dragover`'s default on its element, so the browser lets the drop
// happen there instead of opening the file.
//
// Files (design.md, "Files"): the runtime holds each file the app was given
// as the browser's own `File`, under the token of the handle the host minted
// for it (`files_stage`). The app's handles live on Roc's reference count;
// after every call whose batch the runtime applied and whose effects it
// performed, `files_released` lists the handles Roc let go, and the runtime
// lets go of their files. Poisoning or unmounting lets go of all of them.
// A work request names the files its input holds (FX kind 8): the runtime
// resolves them while the batch's released handles still name their files
// and posts the whole files with the job, by reference; the worker mints a
// handle for each in its instance, and the job reads the ranges it needs
// through effects. Nothing is read before a job runs. The files of a job's
// answer (result tag 10) come back the same way and become the page's
// handles; when the page has no slots for all of them the job is answered
// WorkLost(resource_limit).
//
// Operations on a file the app holds (FX kinds 11 and up) are performed here,
// on the browser's own `File`, which each request resolves when the batch is
// applied and holds until it is answered. A page read (kind 11) reads the
// file's range into a buffer of its own and copies it once into the
// instance's memory as the result (tag 16 bytes, 17 text, which the engine
// checks is UTF-8); a range over the request's max_bytes, or over
// options.maxFileBytes whatever the request asks, is FileFailed(TooLarge)
// unread. A digest (kind 13) reads the range into a
// buffer of its own and digests it with WebCrypto (tag 18): a range over
// options.maxFileBytes is TooLarge, and a browser without WebCrypto (a page
// not in a secure context) answers FileFailed(Unavailable). A file URL (kind
// 14) is an object URL of the range (tag 19), made once per range of a
// handle and revoked when the handle is released, at most
// MAX_URLS_PER_FILE ranges per handle (beyond them TooLarge). Every answer
// is a turn of its own after the batch that asked; CANCEL forgets the
// request and its answer is dropped. In manual mode they wait in `pending`
// until runEffect(id) performs them. An upload (kind 12) is an HTTP request
// whose body is the range, which the browser streams from the file; it is
// performed, held and answered as an HTTP request (kind 1) is.
// Ports (design.md, "Request kinds"): services the page's own JavaScript
// supplies, passed as options.ports, one entry per port the app declares:
// { command(value, { port }) }, { call(value, { signal, port }) },
// { subscribe(arg, { emit, close, signal, port }) } returning an optional
// unsubscribe function, or { push: true } for a subscription fed by
// runtime.emitPort(name, value). The engine lists the app's declarations
// after its storage keys; the runtime refuses to mount (it throws) when a
// declared port has no handler of its shape or a handler names a port the
// app does not declare. A command (opcode 19 PORT) is performed after the
// batch like NAV; a call (FX kind 9) is answered once (result tag 14 or
// 15), aborted on CANCEL or at its timeout (Timeout); a subscription (FX
// kind 10) delivers each emitted message as its own turn, never
// synchronously, with at most one message per subscription in the ingress
// queue: `Latest` keeps the newest undelivered message, `Every(n)` keeps n
// and `emit` returns false beyond them. close() ends it with Closed,
// close(error) with Threw. Messages are PortJson text with `{"$bytes":N}`
// and `{"$file":N}` markers, revived into Uint8Arrays and Files for the
// handler; an answer is serialised strictly (null, booleans, finite
// numbers, strings, BigInt as decimal text, arrays, plain objects,
// Uint8Array/ArrayBuffer as bytes, File/Blob as a file handle, Date as its
// JSON text). An answer that is not such data, a throw or a rejection
// answers the request PortFailed(Threw); an answer larger than
// options.maxPortBytes (default 4 MiB, at most 64 MiB) PortFailed
// (TooLarge). A command handler's or an unsubscribe function's failure goes
// to console.error and options.onPortFault. Nothing a handler does poisons
// the instance. Poisoning and unmounting abort every call's signal and
// unsubscribe every subscription. In manual mode handlers are optional and
// never called: calls wait for answerPort(), subscriptions for
// messagePort(), and commands are logged in portLog.
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
const OP_PORT = 19;
const OP_SAVE = 20;

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
const RES_FILE_FAILED = 13;
const RES_FILE_BYTES = 16;
const RES_FILE_TEXT = 17;
const RES_DIGEST = 18;
const RES_FILE_URL = 19;

// Result tag 11's class byte for a resource limit.
const LOST_RESOURCE_LIMIT = 2;

// Result tag 13's reasons.
const FILE_UNREADABLE = 1;
const FILE_TOO_LARGE = 2;
const FILE_UNAVAILABLE = 3;

// The most ranges of one file handle that have an object URL at once.
const MAX_URLS_PER_FILE = 16;

// The longest deadline a job may have (the engine caps `deadline_ms` at
// this), and the bound on a cancelled job that finishes and has none.
const MAX_DEADLINE_MS = 600000;
const RES_PORT_REPLY = 14;
const RES_PORT_FAILED = 15;
const RES_FETCHED = 21;

// The default and largest bound on one port answer or message, JSON text
// and bytes together (options.maxPortBytes).
export const DEFAULT_PORT_BYTES = 4 * 1024 * 1024;
export const MAX_PORT_BYTES = 64 * 1024 * 1024;


// Result tag 11's class byte: an instance's fault code (1-5) is its class.
const LOST_UNAVAILABLE = 6;
const LOST_EXECUTOR = 7;
const LOST_CLASSES = ["", "contract", "resource_limit", "out_of_memory", "app_crash", "expect_failed", "unavailable", "executor"];

const HOLE_TEXT = 1;
const HOLE_ATTR = 2;
const HOLE_CLICK = 3;
const HOLE_BIND = 4;


export async function instantiateEngineBytes(bytes) {
  const module = await WebAssembly.compile(bytes);
  const instance = await WebAssembly.instantiate(module, pageImports(module));
  return { module, instance };
}

// Thrown by an effect stub of an instance that is not a worker's: a job
// running inline reached a hosted effect only a worker can perform.
class EffectUnavailable extends Error {}

// The imports of an instance that is not a worker's (design.md,
// "Workers"): the page's own instance and the inline instance. A module
// imports exactly the hosted effects its tasks call (`env.js_*`), and only a
// worker instance can perform them (`worker.mjs`). Elsewhere each is a stub
// that throws, naming it. The page's host never reaches one: page code is
// pure, so it cannot call an effect, and the host refuses an effect outside
// a job with a classified contract fault before calling its import. The
// inline instance does reach one when a job running there calls an effect:
// the stub's throw unwinds that instance's call, and the pool answers the
// job WorkLost(unavailable) and replaces the instance (see "Work").
export function pageImports(module) {
  const env = {};
  for (const imp of WebAssembly.Module.imports(module)) {
    if (imp.module !== "env" || imp.kind !== "function") continue;
    env[imp.name] = () => {
      throw new EffectUnavailable(`${imp.name} is a worker effect; it is performed only in a worker instance, and this job runs on the page's thread`);
    };
  }
  return { env };
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

// What a handler declared: its number and its suffixes (see "Handler event
// names" above).
function handlerEntry(h, policies) {
  return { h, prevent: policies.includes("prevent"), files: policies.includes("files") };
}

// The files a `:files` event carries.
function filesOf(event) {
  const list = event.type === "drop" ? event.dataTransfer && event.dataTransfer.files : event.type === "paste" ? event.clipboardData && event.clipboardData.files : event.target.files;
  return list ? Array.from(list) : [];
}

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

// A u64 little-endian (sizes stay below 2^53).
function u64le(v) {
  const b = new Uint8Array(8);
  const dv = new DataView(b.buffer);
  dv.setUint32(0, v % 0x100000000, true);
  dv.setUint32(4, Math.floor(v / 0x100000000), true);
  return b;
}

// The u64 at `8 * i + at` of a view, as a Number (tokens, sizes and offsets
// stay below 2^53).
function tokenAt(dv, i, at = 0) {
  return dv.getUint32(at + 8 * i, true) + dv.getUint32(at + 8 * i + 4, true) * 0x100000000;
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
// instances kept (oldest overwritten, counted in retiredDropped). tasks:
// per-task aggregates (the catalogue's bound; any further name is
// aggregated under "*"). subscribers: a further subscribe throws. timeline:
// roc entries held in the performance timeline; reaching it clears them
// (observers and DevTools traces have already seen them).
export const MONITOR_LIMITS = Object.freeze({ history: 1024, retired: 16, tasks: 64, subscribers: 16, timeline: 1024 });

// The engine's effect counters in the work record (design.md, Appendix B),
// present when the record carries at least `ENGINE_FX_FIRST + 8` counters.
const ENGINE_FX_FIRST = 32;
const ENGINE_FX_NAMES = ["issued", "delivered", "stale", "refused", "cancelled", "reparented", "skipped", "live"];

// Why an instance let go of its prepared state (see stateEvicted).
const EVICT_CAUSES = ["replaced", "released"];

const END_CAUSES = ["cancel", "deadline", "fault", "executor", "unmount", "contained", "retired"];

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
    // Per-port counters, owned by the runtime and copied into snapshots.
    this.portStats = env.ports ?? (() => ({}));
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

  // Zero the aggregates (counts, peaks, integrals, histograms, per-task
  // figures and the job history) and start a new measurement window at
  // `snapshot().since`. Live jobs and instances are still tracked; peaks
  // restart from the current gauges.
  reset() {
    this.tick();
    this.since = this.lastAt;
    this.count = { issued: 0, done: 0, lost: 0, timeout: 0, cancelled: 0, unavailable: 0, lateReplies: 0, wastedMs: 0, inputBytes: 0, outputBytes: 0, prepared: 0, reused: 0, prepareMs: 0 };
    this.evictions = Object.fromEntries(EVICT_CAUSES.map((c) => [c, 0]));
    this.spawns = 0;
    this.ended = Object.fromEntries(END_CAUSES.map((c) => [c, 0]));
    this.peak = { instances: this.gauge.instances, busy: this.gauge.busy, queued: this.gauge.queued };
    this.integral = { busyMs: 0, aliveMs: 0, queuedMs: 0 };
    this.hist = { queue: newHist(), cold: newHist(), compute: newHist(), total: newHist(), resultTurn: newHist(), prepare: newHist() };
    this.tasks = new Map();
    this.recent.clear();
    this.retired.clear();
  }

  // Plain serialisable data (no BigInt, no bytes) describing the pool, its
  // jobs and instances since the last reset; see the worker-monitoring
  // documentation for every field. Cost: proportional to the history,
  // the retired instances and the tasks held; nothing is computed until
  // it is called.
  snapshot() {
    this.tick();
    const tasks = {};
    for (const [name, p] of this.tasks) {
      tasks[name] = { ...p, hist: { queue: copyHist(p.hist.queue), compute: copyHist(p.hist.compute), total: copyHist(p.hist.total) } };
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
        evicted: { ...this.evictions },
        live: [...this.insts.values()].map((i) => this.instRecord(i)),
        retired: this.retired.list(),
        retiredDropped: this.retired.dropped,
      },
      hist: Object.fromEntries(Object.entries(this.hist).map(([k, h]) => [k, copyHist(h)])),
      tasks,
      recent: this.recent.list(),
      recentDropped: this.recent.dropped,
      page,
      engine,
      ports: this.portStats(),
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

  perTask(name) {
    let p = this.tasks.get(name);
    if (p === undefined) {
      if (name !== "*" && this.tasks.size >= MONITOR_LIMITS.tasks) return this.perTask("*");
      p = { jobs: 0, done: 0, lost: 0, timeout: 0, cancelled: 0, unavailable: 0, inputBytes: 0, outputBytes: 0, hist: { queue: newHist(), compute: newHist(), total: newHist() } };
      this.tasks.set(name, p);
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
  jobIssued(id, task, input, deadlineMs, held) {
    if (!this.live()) return;
    const at = this.tick();
    const job = {
      id,
      task,
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
    const p = this.perTask(task);
    p.jobs += 1;
    p.inputBytes += input.length;
    const event = { kind: "job-issue", id, task, inputBytes: input.length, deadlineMs, at, held: !!held };
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
  // `mode` is "work", or for a preparation's task "prepare" (the instance
  // prepares the state of preparation `prep` first) or "ask" (it reuses the
  // state it holds).
  jobPosted(id, seq, mode = "work", prep = null) {
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
    job.prepared = mode === "prepare" ? "prepare" : mode === "ask" ? "reuse" : null;
    if (mode === "prepare") inst.held = prep;
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
    // A preparation's task: how long preparing took (null when it reused).
    if (reply && typeof reply.prepareMs === "number") job.prepareMs = reply.prepareMs;
    if (reply && reply.held === false) inst.held = null;
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

  // The job was cancelled (CANCEL, or the runtime's teardown). `finishing`:
  // a job whose task says `on_cancel: Finish` runs on to completion, or to
  // its deadline, so its instance stays busy until instanceFinished (or
  // instanceEnded with cause `deadline`).
  jobCancelled(id, finishing = false) {
    const job = this.jobs.get(id);
    if (job === undefined || !this.live()) return;
    job.finishing = finishing;
    this.cancelJob(job);
  }

  // A cancelled job that was finishing completed; its answer was dropped.
  instanceFinished(seq, mem) {
    const inst = this.insts.get(seq);
    if (inst === undefined || !this.live()) return;
    const at = this.tick();
    if (Array.isArray(mem)) this.memory(inst, mem);
    if (inst.job !== null) {
      inst.job = null;
      inst.busyMs += at - inst.postAt;
      this.move("busy", -1);
    }
    inst.jobs += 1;
  }

  // New memory figures for an instance (after it let go of its state).
  instanceMemory(seq, mem) {
    const inst = this.insts.get(seq);
    if (inst === undefined || !this.live() || !Array.isArray(mem)) return;
    this.memory(inst, mem);
  }

  // The instance let go of its prepared state: `cause` is replaced (it
  // prepared another) or released (the file it was prepared from was released).
  stateEvicted(seq, cause) {
    const inst = this.insts.get(seq);
    if (inst === undefined || !this.live()) return;
    const at = this.tick();
    const prep = inst.held;
    inst.held = null;
    this.evictions[cause] += 1;
    this.emit({ kind: "state-evict", instance: seq, prep, cause, at });
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
    if ((job.phase === "running" || job.phase === "starting") && job.t.reply === null && !job.finishing) {
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
      prepare: job.prepareMs ?? null,
    };
    const outcome = job.outcome;
    this.count[outcome] += 1;
    if (job.outputBytes !== null) this.count.outputBytes += job.outputBytes;
    const p = this.perTask(job.task);
    p[outcome] += 1;
    if (job.outputBytes !== null) p.outputBytes += job.outputBytes;
    if (job.prepared === "prepare" && outcome !== "cancelled") this.count.prepared += 1;
    if (job.prepared === "reuse" && outcome !== "cancelled") this.count.reused += 1;
    if (typeof job.prepareMs === "number") {
      this.count.prepareMs += job.prepareMs;
      addHist(this.hist.prepare, job.prepareMs);
    }
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
      task: job.task,
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
      prepared: job.prepared ?? null,
      prepareMs: job.prepareMs ?? null,
      finished: !!job.finishing,
      deadlineMs: job.deadlineMs,
      t: { ...t },
      ms,
    };
    this.recent.push(record);
    if (this.userTiming) this.measureJob(record);
    const event = { kind: "job-end", id: job.id, task: job.task, outcome, at, record };
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
      held: null,
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
    this.memory(inst, [ready.memBytes, ready.liveAllocs ?? null, ready.liveBytes ?? null]);
    this.move("spawning", -1);
    if (inst.job !== null) {
      const job = this.jobs.get(inst.job);
      if (job !== undefined && job.phase === "starting") job.phase = "running";
    }
    if (this.userTiming) this.measure(`roc:worker ${seq} spawn`, inst.spawnAt, at, { instance: seq, instantiateMs: inst.instantiateMs }, `worker ${seq}`);
    this.emit({ kind: "instance-ready", instance: seq, at, scriptAt: inst.scriptAt, instantiateMs: inst.instantiateMs, memBytes: inst.memBytes, liveAllocs: inst.liveAllocs });
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
      held: i.held,
      endedAt: null,
      endedBy: null,
      fault: null,
    };
  }

  // -- User Timing ----------------------------------------------------------

  measureJob(r) {
    const t = r.t;
    const lane = r.instance === null ? "jobs" : `worker ${r.instance}`;
    this.measure(`roc:work ${r.task}`, t.issue, t.end, { id: r.id, instance: r.instance, outcome: r.outcome, inputBytes: r.inputBytes, outputBytes: r.outputBytes }, "jobs");
    if (t.submit !== null && t.post !== null) this.measure("roc:work.queue", t.submit, t.post, { id: r.id }, "jobs");
    if (r.cold && t.begin !== null) this.measure("roc:work.cold", t.post, t.begin, { id: r.id, instance: r.instance }, lane);
    if (t.post !== null && t.reply !== null) this.measure("roc:work.run", t.post, t.reply, { id: r.id, instance: r.instance }, lane);
    if (t.reply !== null && t.turnEnd !== null) this.measure("roc:work.result", t.reply, t.turnEnd, { id: r.id }, "jobs");
    if (r.prepareMs !== null && t.call !== null) this.measure("roc:work.prepare", t.call - r.prepareMs, t.call, { id: r.id, instance: r.instance }, lane);
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
// (`name:str input:rest`), the browser objects the job's files are, and a
// callback that receives exactly one outcome, `{ output, objects }` or
// `{ lost, message }`, unless the job is cancelled first. It reports each
// transition to the monitor once it has acted: the job's id and task are
// only for that report.
//
// Prepared state (design.md, "Prepared state"): a worker may hold one
// prepared state, under the key it was prepared for (the preparation's
// name, its input's exact bytes and the handles and ranges of its files). A
// job of a preparation's task whose key a worker holds runs there, waiting
// behind it if it is busy; any other prepares on a free worker, preferring
// one that holds nothing, then a new one, then the least recently used
// holder. A worker that is lost, stopped or retired takes its state with
// it, and the next job prepares again. Placement never changes an answer:
// a job's answer is what preparing afresh would give.
class WorkPool {
  constructor({ module, url, max, inline, Worker: W, monitor, maxBytes = Infinity, live = () => true }) {
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
    this.inlineSeq = 0;
    // Inline mode: the key of the state the page-thread instance holds, and
    // what its handles name, by token, as a worker script holds them.
    this.inlineKey = null;
    this.inlineHeld = new Map();
    this.running = false;
    this.closed = false;
    this.pumpQueued = false;
    this.monitor = monitor;
    // A worker whose linear memory exceeds this after a job is retired.
    this.maxBytes = maxBytes;
    // Whether the runtime still holds a file token (a state prepared from a
    // released file is let go).
    this.live = live;
    // Use order, for choosing which holder to evict.
    this.clock = 0;
    // The preparations already reported as too large to keep (at most one
    // entry per catalogue name, so at most 64).
    this.oversized = new Set();
  }

  // A worker holding a prepared state grew past `maxBytes`, so it is
  // retired and the state goes with it: every later question prepares it
  // again. Say so on the console, once per preparation. Only reported;
  // nothing is decided from it.
  reportOversized(name, bytes) {
    if (this.oversized.has(name)) return;
    this.oversized.add(name);
    const mib = (n) => (n / 1048576).toFixed(1);
    console.warn(`roc worker: the state prepared by "${name}" left its worker at ${mib(bytes)} MiB, past maxWorkerBytes (${mib(this.maxBytes)} MiB), so the worker is retired after each job and the state is prepared again for every question; raise maxWorkerBytes or keep less in the state`);
  }

  // Returns the job's stop function: `stop("cancel")` for CANCEL,
  // `stop("deadline")` when its deadline expired. `objects` are the job's
  // own files; `prepared`, for a preparation's task, is { key, prepare,
  // prepareObjects }: `payload` is then the task's (`task:str input:rest`)
  // and `prepare` the preparation's (`prep:str init:rest`). `finish` says
  // that a cancelled running job completes (its answer dropped) instead of
  // ending its worker; `deadline` (ms from now, 0 for none) still bounds it
  // then; `maxOutput` bounds what it appends to builders.
  submit(payload, done, { id, task, objects = [], prepared = null, finish = false, deadline = 0, maxOutput = 0 }) {
    const limit = deadline > 0 ? Math.min(deadline, MAX_DEADLINE_MS) : MAX_DEADLINE_MS;
    const job = { payload, done, slot: null, settled: false, timer: null, id, task, objects, prepared, finish, finishing: false, endBy: Date.now() + limit, maxOutput };
    if (!this.module || (!this.inline && typeof this.W !== "function")) {
      const message = this.module ? "this browser has no Worker" : "the runtime was mounted without its compiled module";
      job.timer = setTimeout(() => this.settle(job, { lost: LOST_UNAVAILABLE, message }), 0);
      return (cause) => this.cancel(job, cause);
    }
    this.queue.push(job);
    this.pump();
    return (cause) => this.cancel(job, cause);
  }

  settle(job, outcome) {
    if (job.settled || this.closed) return;
    job.settled = true;
    job.done(outcome);
  }

  // A cancelled running job whose task says `Finish` completes and keeps
  // its worker, and any state it holds; its answer is dropped. It is still
  // bounded: if it has not completed by its deadline (ten minutes after it
  // was performed when it has none), its worker is terminated as a
  // timed-out job's is, so a job that never ends cannot hold a worker for
  // good. Anything else running is stopped by terminating its worker. A
  // deadline always stops.
  cancel(job, cause = "cancel") {
    if (job.settled) return;
    job.settled = true;
    if (job.timer !== null) clearTimeout(job.timer);
    job.timer = null;
    const q = this.queue.indexOf(job);
    if (q >= 0) this.queue.splice(q, 1);
    if (job.slot !== null) {
      if (cause === "cancel" && job.finish) {
        job.finishing = true;
        job.timer = setTimeout(() => this.overran(job), Math.max(0, job.endBy - Date.now()));
      } else this.discard(job.slot, cause);
    }
    if (cause === "cancel") this.monitor.jobCancelled(job.id, job.finishing);
    this.pumpSoon();
  }

  // A finishing job reached its deadline: end its worker and give the
  // worker's place to the queue.
  overran(job) {
    job.timer = null;
    if (!job.finishing || job.slot === null || this.closed) return;
    this.discard(job.slot, "deadline");
    this.pump();
  }

  // Pump once the current task's other stops have been applied. The engine
  // cancels a whole batch of jobs in one go (a site disposed, a `latest`
  // moving on); pumping inside each cancel would hand the next queued job
  // to a freed slot, or spawn a worker for it, only for the same batch to
  // cancel that job a moment later and terminate the worker it was given.
  // A queued job waits at most one microtask longer for a free worker.
  pumpSoon() {
    if (this.pumpQueued) return;
    this.pumpQueued = true;
    queueMicrotask(() => {
      this.pumpQueued = false;
      this.pump();
    });
  }

  // The worker holding `key`'s state, or null.
  holder(key) {
    for (const s of this.slots) if (s.key !== null && sameKey(s.key, key)) return s;
    return null;
  }

  // A worker for a job that no worker holds the state of: an idle one that
  // holds nothing, else a new one while the pool has room, else the idle
  // holder used least recently. Null when every worker is busy.
  free() {
    let lru = null;
    for (const s of this.slots) {
      if (s.job !== null) continue;
      if (s.key === null) return s;
      if (lru === null || s.used < lru.used) lru = s;
    }
    if (this.slots.length < this.max) return this.spawn();
    return lru;
  }

  pump() {
    if (this.closed) return;
    if (this.inline) {
      if (this.queue.length > 0 && !this.running) this.runInline();
      return;
    }
    // First the jobs whose state a worker holds: each runs there, or waits
    // behind it, so a busy pool never prepares a state again that it
    // already holds.
    for (let i = 0; i < this.queue.length; ) {
      const job = this.queue[i];
      const holder = job.prepared === null ? null : this.holder(job.prepared.key);
      if (holder !== null && holder.job === null) {
        this.queue.splice(i, 1);
        this.post(holder, job, "ask");
      } else i += 1;
    }
    // Then the rest in order, each on a free worker.
    for (let i = 0; i < this.queue.length; ) {
      const job = this.queue[i];
      if (job.prepared !== null && this.holder(job.prepared.key) !== null) {
        i += 1;
        continue;
      }
      const slot = this.free();
      if (slot === null) return;
      // A worker that could not be started has lost every queued job.
      if (this.queue[i] !== job) return;
      this.queue.splice(i, 1);
      this.post(slot, job, job.prepared === null ? "work" : "prepare");
    }
  }

  post(slot, job, mode) {
    slot.job = job;
    job.slot = slot;
    this.clock += 1;
    slot.used = this.clock;
    // The browser's Blobs travel by reference: posting one copies no bytes.
    // The job's files go whole; it reads the ranges it needs (design.md,
    // "Workers").
    const m = { type: "job", mode, payload: job.payload.buffer, objects: job.objects, maxOutputBytes: job.maxOutput };
    const transfer = [job.payload.buffer];
    if (mode === "prepare") {
      m.prepare = job.prepared.prepare.buffer;
      m.prepareObjects = job.prepared.prepareObjects;
      transfer.push(m.prepare);
      if (slot.key !== null) this.monitor.stateEvicted(slot.seq, "replaced");
      slot.key = job.prepared.key;
    }
    if (this.monitor.userTiming) m.task = job.task;
    slot.worker.postMessage(m, transfer);
    this.monitor.jobPosted(job.id, slot.seq, mode, job.prepared === null ? null : job.prepared.key.name);
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
    const slot = { worker, job: null, seq: this.monitor.instanceSpawned("worker"), key: null, used: 0 };
    this.created += 1;
    worker.onmessage = (event) => this.answer(slot, event.data);
    worker.onerror = (event) => {
      if (event && typeof event.preventDefault === "function") event.preventDefault();
      this.lose(slot, LOST_EXECUTOR, `worker script failed: ${event && event.message ? event.message : "error"}`);
    };
    worker.onmessageerror = () => this.lose(slot, LOST_EXECUTOR, "worker message could not be read");
    worker.postMessage({ type: "init", module: this.module, version: PROTOCOL_VERSION, userTiming: this.monitor.userTiming });
    this.slots.push(slot);
    return slot;
  }

  // Let go of `slot`'s state: it is idle, so the message runs before any
  // job posted after it.
  evict(slot, cause) {
    if (slot.key === null) return;
    slot.key = null;
    slot.worker.postMessage({ type: "forget" });
    this.monitor.stateEvicted(slot.seq, cause);
  }

  // The runtime let go of these file tokens: no state prepared from one of
  // them may outlive it. A busy holder is checked when its job replies.
  released(tokens) {
    if (this.inline) {
      if (this.inlineKey !== null && !this.running && tokens.some((t) => keyNames(this.inlineKey, t))) this.forgetInline("released");
      return;
    }
    for (const slot of [...this.slots]) {
      if (slot.key !== null && slot.job === null && tokens.some((t) => keyNames(slot.key, t))) this.evict(slot, "released");
    }
  }

  // After a job: a state keyed on a file the runtime no longer holds is let
  // go, and a worker grown past `maxBytes` is retired.
  afterJob(slot, mem) {
    if (slot.key !== null && !keyLive(slot.key, this.live)) this.evict(slot, "released");
    if (Array.isArray(mem) && mem[0] > this.maxBytes) {
      if (slot.key !== null) this.reportOversized(slot.key.name, mem[0]);
      this.discard(slot, "retired");
    }
  }

  answer(slot, m) {
    if (m.type === "ready") {
      if (this.slots.includes(slot)) this.monitor.instanceReady(slot.seq, m);
      return;
    }
    if (m.type === "forgot") {
      if (this.slots.includes(slot)) this.monitor.instanceMemory(slot.seq, m.mem);
      return;
    }
    const job = slot.job;
    if (job === null || !this.slots.includes(slot)) {
      this.monitor.lateReply();
      return;
    }
    if (m.type === "done") {
      slot.job = null;
      job.slot = null;
      if (job.timer !== null) clearTimeout(job.timer);
      job.timer = null;
      if (!m.held) slot.key = null;
      if (job.finishing) this.monitor.instanceFinished(slot.seq, m.mem ?? null);
      else {
        this.monitor.jobReplied(job.id, slot.seq, { t: m.t, mem: m.mem, outputBytes: m.output.byteLength, prepareMs: m.prepareMs, held: m.held });
        this.settle(job, { output: new Uint8Array(m.output), objects: m.objects ?? [] });
      }
      this.afterJob(slot, m.mem);
      this.pump();
    } else {
      this.lose(slot, m.code >= 1 && m.code <= 5 ? m.code : LOST_EXECUTOR, m.message);
    }
  }

  // The worker can no longer be trusted: discard it and lose its job.
  lose(slot, lost, message) {
    const job = slot.job;
    this.discard(slot, lost === LOST_EXECUTOR ? "executor" : "fault", { class: LOST_CLASSES[lost], message });
    if (job !== null) {
      job.slot = null;
      this.settle(job, { lost, message });
    }
    this.pump();
  }

  // `cause`: cancel, deadline, fault, executor, retired or shutdown (for
  // the monitor). The worker's state, if any, goes with it.
  discard(slot, cause, fault = null) {
    const i = this.slots.indexOf(slot);
    if (i < 0) return;
    this.slots.splice(i, 1);
    slot.worker.terminate();
    this.terminated += 1;
    if (slot.job !== null) {
      slot.job.slot = null;
      if (slot.job.finishing && slot.job.timer !== null) clearTimeout(slot.job.timer);
    }
    slot.job = null;
    slot.key = null;
    this.monitor.instanceEnded(slot.seq, cause, fault);
  }

  forgetInline(cause) {
    if (this.instance !== null) {
      this.instance.exports.forget();
      this.drainInline(this.instance.exports);
    }
    this.inlineKey = null;
    this.monitor.stateEvicted(this.inlineSeq, cause);
  }

  // Inline mode: mint a handle for each object in the page-thread
  // instance, as a worker script does.
  stageInline(x, objects) {
    const n = x.files_stage(objects.length);
    if (n < objects.length) {
      x.files_stage(0);
      throw { lost: LOST_RESOURCE_LIMIT, message: `resource_limit: a job was sent ${objects.length} files and its instance has room for ${n}` };
    }
    const tokens = new DataView(x.memory.buffer, x.files_tokens(), 8 * n);
    for (let i = 0; i < n; i += 1) this.inlineHeld.set(tokenAt(tokens, i), objects[i]);
  }

  // Inline mode: let go of what the instance's host released.
  drainInline(x) {
    const n = x.files_released();
    if (n === 0) return;
    const dv = new DataView(x.memory.buffer, x.files_tokens(), 8 * n);
    for (let i = 0; i < n; i += 1) this.inlineHeld.delete(tokenAt(dv, i));
  }

  // Inline mode: a second instance of the module on this thread, one job at
  // a time, each in a task of its own. It keeps a prepared state as a
  // worker does. A job that reaches a hosted effect is answered
  // unavailable, and the instance it left mid-call is replaced.
  async runInline() {
    this.running = true;
    try {
      while (!this.closed && this.queue.length > 0) {
        await new Promise((r) => setTimeout(r, 0));
        const job = this.queue.shift();
        if (job === undefined || job.settled || this.closed) continue;
        const mon = this.monitor;
        const p = job.prepared;
        const mode = p === null ? "work" : this.inlineKey !== null && sameKey(this.inlineKey, p.key) ? "ask" : "prepare";
        let x = null;
        try {
          if (this.instance === null) {
            this.inlineSeq = mon.instanceSpawned("page");
            mon.jobPosted(job.id, this.inlineSeq, mode, p === null ? null : p.key.name);
            const instStart = mon.now();
            this.instance = await WebAssembly.instantiate(this.module, pageImports(this.module));
            this.inlineHeld.clear();
            this.created += 1;
            if (this.closed) continue;
            mon.instanceReady(this.inlineSeq, { origin: mon.origin, instStart, instEnd: mon.now(), memBytes: this.instance.exports.memory.buffer.byteLength });
          } else mon.jobPosted(job.id, this.inlineSeq, mode, p === null ? null : p.key.name);
          if (job.settled || this.closed) continue;
          x = this.instance.exports;
          const begin = mon.now();
          let prepareMs = null;
          if (mode === "prepare") {
            if (this.inlineKey !== null) mon.stateEvicted(this.inlineSeq, "replaced");
            x.forget();
            this.drainInline(x);
            this.inlineKey = null;
            this.stageInline(x, p.prepareObjects);
            const ptr = x.payload_reserve(p.prepare.length);
            if (p.prepare.length > 0) new Uint8Array(x.memory.buffer, ptr, p.prepare.length).set(p.prepare);
            const t = mon.now();
            x.prepare();
            prepareMs = mon.now() - t;
            this.inlineKey = p.key;
            this.drainInline(x);
          }
          this.stageInline(x, job.objects);
          const ptr = x.payload_reserve(job.payload.length);
          if (job.payload.length > 0) new Uint8Array(x.memory.buffer, ptr, job.payload.length).set(job.payload);
          const call = mon.now();
          if (mode === "work") x.work();
          else x.ask();
          const ret = mon.now();
          const answer = new Uint8Array(x.memory.buffer, x.cmd_ptr(), x.cmd_len());
          const dv = new DataView(answer.buffer, answer.byteOffset, answer.byteLength);
          const count = dv.getUint32(0, true);
          const objects = [];
          for (let i = 0; i < count; i += 1) {
            const o = this.inlineHeld.get(tokenAt(dv, i, 4));
            if (o === undefined) throw new Error("a job's answer names a handle that is not a file");
            objects.push({ blob: o, name: o.name ?? "", type: o.type ?? "" });
          }
          const output = answer.slice(4 + 8 * count);
          this.drainInline(x);
          const sent = mon.now();
          const mem = [x.memory.buffer.byteLength, Number(x.metric(4)), Number(x.metric(5))];
          if (mon.userTiming) mon.measure(`roc:work.compute ${job.task}`, call, ret, { id: job.id }, `worker ${this.inlineSeq}`);
          mon.jobReplied(job.id, this.inlineSeq, { t: [begin, begin, call, ret, sent], mem, outputBytes: output.length, prepareMs, held: this.inlineKey !== null });
          this.settle(job, { output, objects });
          if (this.inlineKey !== null && !keyLive(this.inlineKey, this.live)) this.forgetInline("released");
          if (mem[0] > this.maxBytes) {
            if (this.inlineKey !== null) this.reportOversized(this.inlineKey.name, mem[0]);
            this.instance = null;
            this.inlineKey = null;
            this.terminated += 1;
            mon.instanceEnded(this.inlineSeq, "retired");
          }
        } catch (e) {
          let lost;
          let message = String(e && e.message ? e.message : e);
          if (e instanceof EffectUnavailable) lost = LOST_UNAVAILABLE;
          else if (e && typeof e.lost === "number") lost = e.lost;
          else {
            let code = 0;
            try {
              code = x ? x.fault() : 0;
              if (code !== 0) message = new TextDecoder().decode(new Uint8Array(x.memory.buffer, x.err_ptr(), x.err_len()));
            } catch (_) {
              code = 0;
            }
            lost = code >= 1 && code <= 5 ? code : LOST_EXECUTOR;
          }
          // An instance a call left mid-way, faulted or not, is never called
          // again: the next job gets a fresh one.
          this.instance = null;
          this.inlineKey = null;
          this.inlineHeld.clear();
          this.terminated += 1;
          mon.instanceEnded(this.inlineSeq, lost === LOST_EXECUTOR ? "executor" : "fault", { class: LOST_CLASSES[lost], message });
          this.settle(job, { lost, message });
        }
      }
    } finally {
      this.running = false;
    }
  }

  // Containment and unmount: every worker stops and no outcome is delivered.
  shutdown() {
    this.closed = true;
    for (const job of this.queue.splice(0)) job.settled = true;
    for (const slot of [...this.slots]) {
      if (slot.job !== null) slot.job.settled = true;
      this.discard(slot, "shutdown");
    }
    if (this.instance !== null) this.monitor.instanceEnded(this.inlineSeq, "shutdown");
    this.instance = null;
    this.inlineKey = null;
    this.inlineHeld.clear();
  }
}

// Whether two prepared-state keys are the same: one preparation, the same
// input bytes and the same file handles and ranges. Compared exactly; the
// cost is the input's length.
function sameKey(a, b) {
  if (a === b) return true;
  if (a.name !== b.name || a.init.length !== b.init.length || a.ranges.length !== b.ranges.length) return false;
  for (let i = 0; i < a.ranges.length; i += 1) if (a.ranges[i] !== b.ranges[i]) return false;
  for (let i = 0; i < a.init.length; i += 1) if (a.init[i] !== b.init[i]) return false;
  return true;
}

// Whether a key's files include the handle `token`.
function keyNames(key, token) {
  for (let i = 0; i < key.ranges.length; i += 3) if (key.ranges[i] === token) return true;
  return false;
}

// Whether every file a key names is still held by the runtime.
function keyLive(key, live) {
  for (let i = 0; i < key.ranges.length; i += 3) if (!live(key.ranges[i])) return false;
  return true;
}

// The name a fetched body's file gets: the last segment of the URL's path,
// without its query or fragment, or "download" when that is empty (the
// native spec runner names it the same way).
function urlFileName(url) {
  const last = url.split("?")[0].split("#")[0].split("/").pop();
  return last === "" || last === undefined ? "download" : last;
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
    this.busy = false;
    this.queue = [];
    this.poisoned = null;
    this.refused = 0;
    this.onFault = options.onFault ?? null;
    this.module = options.module ?? null;
    this.manual = options.manualEffects ?? false;
    // Intervals tick only through tick(id) (spec replays control time).
    this.manualIntervals = options.manualIntervals ?? false;
    // Work jobs wait for runEffect(id) while every other effect runs on its
    // own (soak walks hold workers so results arrive in issue order).
    this.manualWork = options.manualWork ?? false;
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
    // token -> File for every file the app holds a handle on (see "Files").
    this.files = new Map();
    // token -> Map(range -> object URL) for the URLs made for a handle's
    // ranges, revoked when the handle is released.
    this.urls = new Map();
    // Work (see "Work" above): the pool is made on the first job.
    this.pool = null;
    this.workerUrl = options.workerUrl ?? new URL("./worker.mjs", import.meta.url);
    this.workerMode = options.workers ?? "worker";
    if (this.workerMode !== "worker" && this.workerMode !== "inline") throw new Error(`workers: ${JSON.stringify(this.workerMode)} is not "worker" or "inline"`);
    const nav = this.win ? this.win.navigator : globalThis.navigator;
    this.maxWorkers = options.maxWorkers ?? Math.min((nav && nav.hardwareConcurrency) || 4, 8);
    this.onWorkerFault = options.onWorkerFault ?? null;
    // The most bytes one read into the page takes whatever its max_bytes
    // asks, one digest reads and one fetched body holds; a request over it
    // is answered FileFailed(TooLarge) without reading. A job's reads in a
    // worker are not bounded by it.
    this.maxFileBytes = options.maxFileBytes ?? 256 * 1024 * 1024;
    // A worker whose linear memory has grown past this many bytes is retired
    // after its job (memory never shrinks, and a prepared state may keep
    // it): the next job that needs a worker starts a fresh one.
    this.maxWorkerBytes = options.maxWorkerBytes ?? 128 * 1024 * 1024;
    // The most bytes one task's job may append to its builders (design.md,
    // "Tasks"): a builder's parts are held in memory, and the browser does
    // not page a large in-memory Blob to disk. An append beyond it is
    // refused with TooLarge, which the job sees.
    this.maxOutputBytes = options.maxOutputBytes ?? 256 * 1024 * 1024;
    if (!Number.isInteger(this.maxOutputBytes) || this.maxOutputBytes < 0) throw new Error(`maxOutputBytes: ${this.maxOutputBytes} is not a whole number of bytes`);
    // Manual mode: the files the app saved (`SAVE`), in order, as
    // { name, blob }, for a spec to read.
    this.saveLog = [];
    // Ports (see "Ports" above): the page's handlers, the app's declared
    // ports (read at mount), push subscriptions by port, the command log of
    // manual mode, and per-port counters for the monitor.
    this.ports = options.ports ?? null;
    this.maxPortBytes = options.maxPortBytes ?? DEFAULT_PORT_BYTES;
    if (!Number.isInteger(this.maxPortBytes) || this.maxPortBytes < 1 || this.maxPortBytes > MAX_PORT_BYTES) {
      throw new Error(`maxPortBytes: ${this.maxPortBytes} is not a whole number of bytes from 1 to ${MAX_PORT_BYTES}`);
    }
    this.onPortFault = options.onPortFault ?? null;
    this.portDecls = new Map();
    this.pushSubs = new Map();
    this.portLog = [];
    this.portCounts = new Map();
    this.ending = null;
    // Observation of jobs, workers and turns (options.monitor; see "The
    // monitor" above). It never changes what this runtime does.
    this.monitor = new WorkMonitor(options.monitor ?? {}, {
      page: () => this.pageStats(),
      mode: () => this.workMode(),
      ports: () => this.portStats(),
      maxWorkers: this.maxWorkers,
    });
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
    // The app's port declarations, checked against options.ports before
    // anything mounts: a mismatch throws, and nothing runs.
    const boot = this.guard(() => readBootKeys(this.x));
    if (this.poisoned) return;
    this.bootKeys = boot.keys;
    this.portDecls = new Map(boot.decls.map((d) => [d.name, d]));
    checkPortHandlers(boot.decls, this.ports, this.manual);
    this.monitor.runtimeMounted();
    this.guard(() => this.mountInner());
    this.drainQueue();
  }

  mountInner() {
    this.controlListeners();
    this.listen("click");
    const x = this.x;
    // Read before mount with the port table (see mount()).
    const keys = this.bootKeys;
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
    this.monitor.runtimeEnding("contained");
    this.ending = "poisoned";
    for (const e of this.live.values()) {
      try {
        e.cancel();
      } catch (_) {
        // teardown is best effort and never re-enters Wasm
      }
    }
    this.live.clear();
    this.pushSubs.clear();
    this.stopWorkers();
    this.files.clear();
    this.revokeUrls();
    this.queue = [];
    this.fxOut = [];
    this.monitor.runtimeEnded("poisoned", this.poisoned);
    console.error(`roc engine fault [${this.poisoned.class}]: ${message}`);
    if (this.onFault) this.onFault(this.poisoned);
  }

  // A fresh instance from the same module; the poisoned one is abandoned.
  async recover() {
    if (!this.module) throw new Error("recover() needs the compiled module (mountRocEngineApp keeps it)");
    const instance = await WebAssembly.instantiate(this.module, pageImports(this.module));
    this.x = instance.exports;
    this.root.textContent = "";
    this.statics = [];
    this.sites = [];
    this.templates = [];
    this.live = new Map();
    this.files = new Map();
    this.revokeUrls();
    this.issued = [];
    this.queue = [];
    this.fxOut = [];
    this.busy = false;
    this.poisoned = null;
    this.ending = null;
    this.pushSubs = new Map();
    this.portLog = [];
    this.saveLog = [];
    this.mount();
    return this;
  }

  unmount() {
    this.monitor.runtimeEnding("unmount");
    this.ending = "unmounted";
    for (const id of [...this.live.keys()]) this.cancel(id);
    this.pushSubs.clear();
    this.stopWorkers();
    this.monitor.runtimeEnded("unmounted");
    for (const [type, fn] of this.listening) this.root.removeEventListener(type, fn);
    this.listening.clear();
    for (const [type, fn] of this.internal) this.root.removeEventListener(type, fn, true);
    this.internal = [];
    this.x.drop();
    this.files.clear();
    this.revokeUrls();
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
    if (dom === "drop" && !this.listening.has("dragover")) {
      // A drop target that takes files lets the drop happen (see "Handler
      // event names" above); dragover reaches no app handler.
      const over = (event) => {
        for (let node = event.target; node && node !== this.root; node = node.parentNode) {
          const h = node.__h && node.__h.drop;
          if (h !== undefined) {
            if (h.files) event.preventDefault();
            return;
          }
        }
      };
      this.listening.set("dragover", over);
      this.root.addEventListener("dragover", over);
    }
  }

  // The nearest handler for this event type walking up from the target
  // (bubbling), then the nearest node carrying an engine id.
  handle(event) {
    const type = APP_EVENT[event.type] ?? event.type;
    // Forms are app-managed: a submit never navigates (design.md,
    // "Controlled inputs").
    if (event.type === "submit") event.preventDefault();
    let node = event.target;
    let handler = null;
    while (node && node !== this.root) {
      if (handler === null && node.__h !== undefined) {
        const h = node.__h[type];
        if (h !== undefined) handler = h;
      }
      if (node.__rn !== undefined && handler !== null) {
        if (handler.prevent) event.preventDefault();
        if (handler.files) {
          // The browser empties a drop's or a paste's file list after the
          // event, so the files are captured now.
          const files = filesOf(event);
          if (files.length > 0) this.dispatch(node.__rn, handler.h, { files }, node);
        } else this.dispatch(node.__rn, handler.h, payloadOf(event), node);
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

  // One engine call for an event: a `:files` event stages its handles and
  // file record (design.md, Appendix B), anything else its text.
  call(node, handler, payload) {
    if (payload !== null && typeof payload === "object" && payload.parts !== undefined) {
      this.callPort(node, handler, payload);
      return;
    }
    if (payload === null || typeof payload !== "object" || payload.files === undefined) {
      this.stage(payload);
      this.x.event(node, handler);
      return;
    }
    const files = payload.files;
    const minted = this.x.files_stage(files.length);
    const tokens = new DataView(this.x.memory.buffer, this.x.files_tokens(), 8 * minted);
    const parts = [u32(minted), u32(files.length - minted)];
    for (let i = 0; i < minted; i += 1) {
      const f = files[i];
      this.files.set(tokenAt(tokens, i), f);
      parts.push(u64le(f.size), encStr(f.name), encStr(f.type));
    }
    this.stage(concat(parts));
    this.x.event_files(node, handler);
  }

  // Let go of the files whose handles Roc released during the last call:
  // after its batch was applied and its effects performed, so a request in
  // the batch that named one has already taken its file.
  releaseFiles() {
    const n = this.x.files_released();
    if (n === 0) return;
    const tokens = new DataView(this.x.memory.buffer, this.x.files_tokens(), 8 * n);
    const released = [];
    for (let i = 0; i < n; i += 1) {
      const token = tokenAt(tokens, i);
      this.files.delete(token);
      const urls = this.urls.get(token);
      if (urls !== undefined) {
        this.urls.delete(token);
        for (const url of urls.values()) this.urlApi().revokeObjectURL(url);
      }
      released.push(token);
    }
    // No prepared state outlives the file it was prepared from.
    if (this.pool !== null) this.pool.released(released);
  }

  // Revoke every object URL made for a file (poisoning, recovery, unmount).
  revokeUrls() {
    for (const urls of this.urls.values()) for (const url of urls.values()) this.urlApi().revokeObjectURL(url);
    this.urls.clear();
  }

  urlApi() {
    return (this.win && this.win.URL) ?? globalThis.URL;
  }

  stage(payload) {
    if (payload.parts !== undefined) {
      // A result built from parts (a tag and a file's bytes) is copied into
      // the staged list part by part, so the bytes are copied once.
      const total = payload.parts.reduce((n, p) => n + p.length, 0);
      const ptr = this.x.payload_reserve(total);
      const mem = new Uint8Array(this.x.memory.buffer, ptr, total);
      let at = 0;
      for (const p of payload.parts) {
        mem.set(p, at);
        at += p.length;
      }
      return;
    }
    if (payload === "" || payload.length === 0) {
      this.x.payload_reserve(0);
      return;
    }
    const bytes = typeof payload === "string" ? utf8enc.encode(payload) : payload;
    const ptr = this.x.payload_reserve(bytes.length);
    new Uint8Array(this.x.memory.buffer, ptr, bytes.length).set(bytes);
  }

  // One turn. It is timed (staging, `event`, then the batch applied and its
  // effects performed) only when the monitor wants it: a job's result turn,
  // or every turn while a subscriber asked for `turn` events.
  deliver(node, handler, payload) {
    if (globalThis.__trace) console.log("event", node, handler, JSON.stringify(payload));
    const m = this.monitor;
    if (!m.timesTurn(node, handler)) {
      this.call(node, handler, payload);
      this.apply();
      return;
    }
    const t0 = m.now();
    this.call(node, handler, payload);
    const t1 = m.now();
    const bytes = this.apply();
    const t2 = m.now();
    m.turn(node, handler, t0, t1, t2, bytes);
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
    this.releaseFiles();
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
              const [type, ...policies] = hole.name.split(":");
              target.__h[type] = handlerEntry(hole.handler, policies);
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
          const [base, ...policies] = type.split(":");
          const h = dv.getUint32(at + 4, true);
          el.__h[base] = handlerEntry(h, policies);
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
            const task = str();
            const n = dv.getUint32(at, true);
            // Copied out: linear memory may move before the job is posted.
            const input = u8.slice(at + 4, at + 4 + n);
            at += 4 + n;
            // The files the job names, resolved now, while the handles the
            // batch released still name their files (see "Files").
            // Its files cross whole, as handles the worker mints, and the job
            // reads their ranges itself; nothing is read before it runs.
            const refs = dv.getUint32(at, true);
            at += 4;
            const files = [];
            const ranges = [];
            for (let i = 0; i < refs; i += 1) {
              const token = tokenAt(dv, 0, at);
              const start = tokenAt(dv, 0, at + 8);
              const len = tokenAt(dv, 0, at + 16);
              const file = this.files.get(token);
              if (file === undefined) throw new Error(`a work request names file handle ${token}, which this runtime does not hold`);
              files.push(file);
              ranges.push(token, start, len);
              at += 24;
            }
            const deadline = dv.getUint32(at, true);
            const cancel = u8[at + 4];
            const flag = u8[at + 5];
            at += 6;
            if (cancel !== 1 && cancel !== 2) throw new Error(`work request cancel policy ${cancel} is not 1 or 2`);
            // A preparation's task (design.md, "Prepared state"): which
            // preparation answers it, and where its input lies in `input`.
            let prep = null;
            if (flag === 1) {
              const name = str();
              const initLen = dv.getUint32(at, true);
              const initFiles = dv.getUint32(at + 4, true);
              at += 8;
              if (initLen > input.length || initFiles > refs) throw new Error(`malformed preparation operands for worker task ${task}`);
              prep = { name, initLen, initFiles, ranges: ranges.slice(0, 3 * initFiles) };
            } else if (flag !== 0) throw new Error(`work request flag ${flag} is not 0 or 1`);
            this.fxOut.push({ op: "work", id, task, input, files, deadline, finish: cancel === 2, prep });
          } else if (kind === 11) {
            const mode = u8[at];
            if (mode !== 1 && mode !== 2) throw new Error(`unknown file read mode ${mode}`);
            const maxBytes = tokenAt(dv, 0, at + 25);
            this.fxOut.push({ op: "read", id, mode, maxBytes, ...this.fileRef(dv, at + 1) });
            at += 33;
          } else if (kind === 12) {
            const method = str();
            const url = str();
            const headers = [];
            let n = dv.getUint32(at, true);
            at += 4;
            for (; n > 0; n -= 1) headers.push([str(), str()]);
            const ref = this.fileRef(dv, at);
            const timeout = dv.getUint32(at + 24, true);
            at += 28;
            this.fxOut.push({ op: "upload", id, method, url, headers, ...ref, timeout });
          } else if (kind === 13) {
            const algorithm = u8[at];
            if (algorithm !== 1) throw new Error(`unknown digest algorithm ${algorithm}`);
            this.fxOut.push({ op: "digest", id, algorithm, ...this.fileRef(dv, at + 1) });
            at += 25;
          } else if (kind === 14) {
            this.fxOut.push({ op: "url", id, ...this.fileRef(dv, at) });
            at += 24;
          } else if (kind === 9) {
            const port = str();
            const m = this.readPortMessage(u8, dv, at);
            at = m.at;
            const timeout = dv.getUint32(at, true);
            at += 4;
            this.fxOut.push({ op: "portcall", id, port, msg: m.msg, timeout });
          } else if (kind === 10) {
            const port = str();
            const m = this.readPortMessage(u8, dv, at);
            at = m.at;
            this.fxOut.push({ op: "portsub", id, port, msg: m.msg });
          } else if (kind === 15) {
            const method = str();
            const url = str();
            const headers = [];
            let n = dv.getUint32(at, true);
            at += 4;
            for (; n > 0; n -= 1) headers.push([str(), str()]);
            const timeout = dv.getUint32(at, true);
            at += 4;
            this.fxOut.push({ op: "fetch", id, method, url, headers, body: "", timeout });
          } else throw new Error(`unknown effect kind ${kind}`);
          break;
        }
        case OP_SAVE: {
          // Resolved now, while a handle the batch released still names its
          // file; the download is made after the batch.
          const ref = this.fileRef(dv, at);
          const n = dv.getUint32(at + 24, true);
          const name = readStr(u8, at + 28, n);
          at += 28 + n;
          this.fxOut.push({ op: "save", name, blob: ref.blob, type: ref.file.type });
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
        case OP_PORT: {
          const n = dv.getUint32(at, true);
          const port = readStr(u8, at + 4, n);
          const m = this.readPortMessage(u8, dv, at + 4 + n);
          at = m.at;
          this.fxOut.push({ op: "port", port, msg: m.msg });
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

  // A request's file, `token:u64 start:u64 len:u64` at `at`, resolved while
  // the batch's released handles still name their files (see "Files"): the
  // browser's `File`, the range, and the range as a Blob of the file's type.
  // The request holds them, so the file outlives its handle until the
  // request is answered.
  fileRef(dv, at) {
    const token = tokenAt(dv, 0, at);
    const start = tokenAt(dv, 0, at + 8);
    const len = tokenAt(dv, 0, at + 16);
    const file = this.files.get(token);
    if (file === undefined) throw new Error(`a request names file handle ${token}, which this runtime does not hold`);
    const blob = start === 0 && len === file.size ? file : file.slice(start, start + len, file.type);
    return { token, file, start, len, blob };
  }

  // Perform an operation on a file (`fx.op`: read, digest, url). Its one answer is a
  // turn of its own, delivered unless CANCEL forgets the request first;
  // `settled`, when given, is called once either way.
  startFileOp(fx, settled) {
    const entry = {
      kind: "file",
      req: fx,
      running: true,
      cancel: () => {
        if (settled) settled();
      },
    };
    this.live.set(fx.id, entry);
    const finish = (payload) => {
      if (this.live.get(fx.id) !== entry) return;
      this.live.delete(fx.id);
      this.result(fx.id, payload);
      if (settled) settled();
    };
    this.fileAnswer(fx).then(finish, () => finish(new Uint8Array([RES_FILE_FAILED, FILE_UNREADABLE])));
  }

  // The result payload of an operation on a file. A file the browser can no
  // longer read (the user's file changed or went away) is FileFailed
  // (Unreadable).
  async fileAnswer(fx) {
    const failed = (reason) => new Uint8Array([RES_FILE_FAILED, reason]);
    if (fx.op === "read") {
      if (fx.len > fx.maxBytes || fx.len > this.maxFileBytes) return failed(FILE_TOO_LARGE);
      const buf = await fx.blob.arrayBuffer();
      if (buf.byteLength !== fx.len) return failed(FILE_UNREADABLE);
      return { parts: [new Uint8Array([fx.mode === 1 ? RES_FILE_BYTES : RES_FILE_TEXT]), new Uint8Array(buf)] };
    }
    if (fx.op === "digest") {
      if (fx.len > this.maxFileBytes) return failed(FILE_TOO_LARGE);
      const c = (this.win && this.win.crypto) ?? globalThis.crypto;
      if (!c || !c.subtle || typeof c.subtle.digest !== "function") return failed(FILE_UNAVAILABLE);
      const buf = await fx.blob.arrayBuffer();
      if (buf.byteLength !== fx.len) return failed(FILE_UNREADABLE);
      const digest = await c.subtle.digest("SHA-256", buf);
      return { parts: [new Uint8Array([RES_DIGEST]), new Uint8Array(digest)] };
    }
    if (fx.op === "url") {
      // One URL per range of a handle, kept until the handle is released.
      // A handle released while this request waited has no URL to give.
      if (!this.files.has(fx.token)) return failed(FILE_UNREADABLE);
      let urls = this.urls.get(fx.token);
      if (urls === undefined) {
        urls = new Map();
        this.urls.set(fx.token, urls);
      }
      const key = `${fx.start}+${fx.len}`;
      let url = urls.get(key);
      if (url === undefined) {
        if (urls.size >= MAX_URLS_PER_FILE) return failed(FILE_TOO_LARGE);
        url = this.urlApi().createObjectURL(fx.blob);
        urls.set(key, url);
      }
      return concat([new Uint8Array([RES_FILE_URL]), utf8enc.encode(url)]);
    }
    throw new Error(`unknown file operation ${fx.op}`);
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
      case "work": {
        const held = this.manual || this.manualWork;
        this.monitor.jobIssued(fx.id, fx.task, fx.input, fx.deadline, held);
        if (held) {
          this.live.set(fx.id, { kind: "work", req: fx, cancel: () => this.monitor.jobCancelled(fx.id) });
          this.issued.push(fx.id);
          return;
        }
        this.startWork(fx, null);
        return;
      }
      case "read":
      case "digest":
      case "url": {
        if (this.manual) {
          this.live.set(fx.id, { kind: "file", req: fx, cancel: () => {} });
          this.issued.push(fx.id);
          return;
        }
        this.startFileOp(fx, null);
        return;
      }
      case "timer":
      case "upload":
      case "http": {
        if (this.manual) {
          this.live.set(fx.id, { kind: fx.op === "timer" ? "timer" : "http", req: fx, cancel: () => {} });
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
        // An upload's body is its file's range, which the browser streams
        // from the file; the request holds the file until it is answered.
        if (fx.op === "upload") init.body = fx.blob;
        else if (fx.method !== "GET" && fx.method !== "HEAD" && fx.body !== "") init.body = fx.body;
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
      case "save":
        this.performSave(fx);
        return;
      case "fetch": {
        if (this.manual) {
          this.live.set(fx.id, { kind: "fetch", req: fx, cancel: () => {} });
          this.issued.push(fx.id);
          return;
        }
        this.startFetch(fx);
        return;
      }
      case "port":
        this.performPortCommand(fx);
        return;
      case "portcall":
        this.performPortCall(fx);
        return;
      case "portsub":
        this.performPortSub(fx);
        return;
      default:
        throw new Error(`unknown effect ${fx.op}`);
    }
  }

  // ---------------------------------------------------------------------
  // Saving and fetching files (design.md, "Tasks").

  // `SAVE`: a download of the file's range under `fx.name`, made with an
  // object URL and a link with a `download` attribute, clicked, then
  // revoked a moment later (the browser has taken the Blob by then). In
  // manual mode it is logged in `saveLog` instead, for a spec to read. A
  // save the batch issued in a click's turn runs inside that click's
  // listener, so the browser sees the user's gesture; one issued later may
  // be held back by the browser, which this runtime does not hide.
  performSave(fx) {
    if (this.manual) {
      this.saveLog.push({ name: fx.name, blob: fx.blob });
      return;
    }
    const doc = this.doc;
    const urls = this.urlApi();
    const url = urls.createObjectURL(fx.blob.type === fx.type ? fx.blob : new Blob([fx.blob], { type: fx.type }));
    const a = doc.createElement("a");
    a.href = url;
    a.download = fx.name;
    a.style.display = "none";
    doc.body.appendChild(a);
    try {
      a.click();
    } finally {
      a.remove();
      setTimeout(() => urls.revokeObjectURL(url), 1000);
    }
  }

  // FX kind 15: an HTTP request whose body becomes a file the page holds
  // (result tag 21), never entering linear memory: the body is the
  // browser's `Blob`, which a large response keeps on disk. A body over
  // options.maxFileBytes is FileFailed(TooLarge); a failure or a timeout is
  // answered as an HTTP request's. Held, cancelled and timed out as an HTTP
  // request is.
  startFetch(fx) {
    const ctl = new AbortController();
    let timer = null;
    const done = () => {
      if (timer === null) return;
      clearTimeout(timer);
      timer = null;
      this.timers -= 1;
    };
    const entry = {
      kind: "fetch",
      req: fx,
      running: true,
      cancel: () => {
        done();
        ctl.abort();
      },
    };
    this.live.set(fx.id, entry);
    const settle = (payload) => {
      if (this.live.get(fx.id) !== entry) return;
      this.live.delete(fx.id);
      done();
      this.result(fx.id, payload);
    };
    if (fx.timeout > 0) {
      this.timers += 1;
      timer = setTimeout(() => {
        timer = null;
        this.timers -= 1;
        if (this.live.get(fx.id) !== entry) return;
        this.live.delete(fx.id);
        ctl.abort();
        this.result(fx.id, new Uint8Array([RES_TIMEOUT]));
      }, fx.timeout);
    }
    const send = this.fetch ?? globalThis.fetch;
    new Promise((resolve) => resolve(send(fx.url, { method: fx.method, headers: fx.headers, signal: ctl.signal })))
      .then(async (r) => {
        const blob = await r.blob();
        if (this.live.get(fx.id) !== entry) return;
        settle(this.fetchedPayload(fx.url, r.status, [...r.headers], blob));
      })
      .catch((e) => settle(concat([new Uint8Array([RES_NETWORK]), utf8enc.encode(String(e))])));
  }

  // A fetched body as result tag 21 with its file, or FileFailed(TooLarge).
  fetchedPayload(url, status, headers, blob) {
    if (blob.size > this.maxFileBytes) return new Uint8Array([RES_FILE_FAILED, FILE_TOO_LARGE]);
    const type = (headers.find(([k]) => k.toLowerCase() === "content-type") ?? [null, blob.type])[1];
    const file = new File([blob], urlFileName(url), { type });
    const parts = [new Uint8Array([RES_FETCHED, status & 0xff, (status >>> 8) & 0xff]), u32(headers.length)];
    for (const [k, v] of headers) parts.push(encStr(k), encStr(v));
    return { parts, files: [file], overflow: new Uint8Array([RES_FILE_FAILED, FILE_TOO_LARGE]) };
  }

  // ---------------------------------------------------------------------
  // Ports (see "Ports" above).

  // A port message at `at` in a batch: `json:str nblobs:u32 (len:u32
  // bytes)* nfiles:u32 (token:u64 start:u64 len:u64)*`. The blobs are
  // copied out of linear memory (it may move before the handler runs) and
  // the files resolved now, while the handles the batch released still name
  // their files.
  readPortMessage(u8, dv, at0) {
    let at = at0;
    const n = dv.getUint32(at, true);
    const json = readStr(u8, at + 4, n);
    at += 4 + n;
    const blobs = [];
    const nblobs = dv.getUint32(at, true);
    at += 4;
    for (let i = 0; i < nblobs; i += 1) {
      const len = dv.getUint32(at, true);
      blobs.push(u8.slice(at + 4, at + 4 + len));
      at += 4 + len;
    }
    const files = [];
    const nfiles = dv.getUint32(at, true);
    at += 4;
    for (let i = 0; i < nfiles; i += 1) {
      const token = tokenAt(dv, 0, at);
      const start = tokenAt(dv, 0, at + 8);
      const len = tokenAt(dv, 0, at + 16);
      const file = this.files.get(token);
      if (file === undefined) throw new Error(`a port message names file handle ${token}, which this runtime does not hold`);
      files.push(start === 0 && len === file.size ? file : new File([file.slice(start, start + len)], file.name ?? "", { type: file.type }));
      at += 24;
    }
    return { msg: { json, blobs, files }, at };
  }

  portHandler(port) {
    return this.ports ? this.ports[port] : undefined;
  }

  // The monitor's per-port record: the counts since mount, and what is
  // outstanding now: calls awaiting an answer (`inFlight`), live
  // subscriptions, and messages emitted but not yet delivered (`backlog`).
  // Read only when a snapshot is taken; linear in the requests in flight,
  // which the in-flight bound caps.
  portStats() {
    const stats = Object.fromEntries([...this.portCounts].map(([name, c]) => [name, { ...c, inFlight: 0, subscriptions: 0, backlog: 0 }]));
    for (const e of this.live.values()) {
      if (e.kind !== "portcall" && e.kind !== "portsub") continue;
      const s = stats[e.req.port];
      if (s === undefined) continue;
      if (e.kind === "portcall") s.inFlight += 1;
      else {
        s.subscriptions += 1;
        s.backlog += e.backlog ? e.backlog() : 0;
      }
    }
    return stats;
  }

  portCount(port, key, n = 1) {
    let c = this.portCounts.get(port);
    if (c === undefined) {
      c = { sent: 0, calls: 0, answered: 0, threw: 0, timedOut: 0, cancelled: 0, subscribed: 0, messages: 0, coalesced: 0, refusedEmits: 0, tooLarge: 0, closed: 0, faults: 0 };
      this.portCounts.set(port, c);
    }
    c[key] += n;
  }

  // A failure the app cannot be told of: a command handler's, or an
  // unsubscribe function's. Reported, never delivered, never poisoning.
  portFault(port, kind, error) {
    const message = String(error && error.message !== undefined ? error.message : error);
    this.portCount(port, "faults");
    console.error(`roc port fault [${kind}] "${port}": ${message}`);
    if (this.onPortFault) {
      try {
        this.onPortFault({ port, kind, message });
      } catch (_) {
        // an observer that throws changes nothing
      }
    }
  }

  abortReason() {
    return new DOMException(this.ending ?? "cancelled", "AbortError");
  }

  performPortCommand(fx) {
    this.portCount(fx.port, "sent");
    if (this.manual) {
      this.portLog.push({ port: fx.port, json: fx.msg.json });
      return;
    }
    const h = this.portHandler(fx.port);
    try {
      const r = h.command(portValue(fx.msg), { port: fx.port });
      if (r !== null && typeof r === "object" && typeof r.then === "function") r.then(undefined, (e) => this.portFault(fx.port, "command", e));
    } catch (e) {
      this.portFault(fx.port, "command", e);
    }
  }

  // An answer as the payload of its result turn, or the failure it is.
  portAnswer(port, value) {
    let data;
    try {
      data = portData(value);
    } catch (e) {
      if (!(e instanceof PortDataError)) throw e;
      this.portCount(port, "threw");
      return portFailed(1, `the answer is not JSON data: ${e.message}`);
    }
    const payload = portReplyPayload(data);
    if (payload.size > this.maxPortBytes) {
      this.portCount(port, "tooLarge");
      return portFailed(2);
    }
    return payload;
  }

  performPortCall(fx) {
    this.portCount(fx.port, "calls");
    if (this.manual) {
      this.live.set(fx.id, { kind: "portcall", req: fx, cancel: () => this.portCount(fx.port, "cancelled") });
      this.issued.push(fx.id);
      return;
    }
    const ctl = new AbortController();
    let timer = null;
    const clear = () => {
      if (timer === null) return;
      clearTimeout(timer);
      timer = null;
      this.timers -= 1;
    };
    const entry = {
      kind: "portcall",
      req: fx,
      cancel: () => {
        clear();
        this.portCount(fx.port, "cancelled");
        ctl.abort(this.abortReason());
      },
    };
    this.live.set(fx.id, entry);
    const settle = (payload) => {
      if (this.live.get(fx.id) !== entry) return; // cancelled or timed out
      this.live.delete(fx.id);
      clear();
      this.result(fx.id, payload);
    };
    if (fx.timeout > 0) {
      this.timers += 1;
      timer = setTimeout(() => {
        timer = null;
        this.timers -= 1;
        if (this.live.get(fx.id) !== entry) return;
        this.live.delete(fx.id);
        this.portCount(fx.port, "timedOut");
        ctl.abort(new DOMException("timed out", "TimeoutError"));
        this.result(fx.id, { parts: [new Uint8Array([RES_TIMEOUT])], files: [] });
      }, fx.timeout);
    }
    const threw = (e) => {
      this.portCount(fx.port, "threw");
      return portFailed(1, String(e && e.message !== undefined ? e.message : e));
    };
    let r;
    try {
      r = this.portHandler(fx.port).call(portValue(fx.msg), { signal: ctl.signal, port: fx.port });
    } catch (e) {
      // Delivered as its own turn, never inside this batch.
      Promise.resolve().then(() => settle(threw(e)));
      return;
    }
    Promise.resolve(r).then(
      (v) => {
        if (this.live.get(fx.id) !== entry) return;
        const payload = this.portAnswer(fx.port, v);
        if (payload.parts[0][0] === RES_PORT_REPLY) this.portCount(fx.port, "answered");
        settle(payload);
      },
      (e) => settle(threw(e)),
    );
  }

  performPortSub(fx) {
    this.portCount(fx.port, "subscribed");
    if (this.manual) {
      this.live.set(fx.id, { kind: "portsub", req: fx, cancel: () => this.portCount(fx.port, "cancelled") });
      return;
    }
    const decl = this.portDecls.get(fx.port);
    const ctl = new AbortController();
    const sub = { id: fx.id, port: fx.port, latest: decl.delivery === 2, bound: decl.bound, queue: [], waiting: false, ended: false, unsubscribe: null, entry: null };
    sub.entry = {
      kind: "portsub",
      req: fx,
      backlog: () => sub.queue.length,
      cancel: () => {
        sub.ended = true;
        sub.queue = [];
        this.portCount(fx.port, "cancelled");
        this.dropPushSub(sub);
        ctl.abort(this.abortReason());
        if (sub.unsubscribe) {
          try {
            sub.unsubscribe();
          } catch (e) {
            this.portFault(fx.port, "unsubscribe", e);
          }
        }
      },
    };
    this.live.set(fx.id, sub.entry);
    const h = this.portHandler(fx.port);
    if (h.push) {
      if (!this.pushSubs.has(fx.port)) this.pushSubs.set(fx.port, new Set());
      this.pushSubs.get(fx.port).add(sub);
      return;
    }
    const ctx = { emit: (v) => this.portEmit(sub, v), close: (error) => this.portClose(sub, error, error !== undefined), signal: ctl.signal, port: fx.port };
    try {
      const u = h.subscribe(portValue(fx.msg), ctx);
      if (typeof u === "function") sub.unsubscribe = u;
    } catch (e) {
      this.portClose(sub, e, true);
    }
  }

  dropPushSub(sub) {
    const set = this.pushSubs.get(sub.port);
    if (set !== undefined) set.delete(sub);
  }

  // One message from the JavaScript: kept as the subscription's delivery
  // policy says and delivered as its own turn. A value that is not JSON
  // data is the emitter's error, thrown back to it.
  portEmit(sub, value) {
    if (sub.ended || this.live.get(sub.id) !== sub.entry) return false;
    let payload;
    try {
      payload = portReplyPayload(portData(value));
    } catch (e) {
      if (e instanceof PortDataError) throw new TypeError(`port "${sub.port}": emit was given something that is not JSON data: ${e.message}`);
      throw e;
    }
    if (payload.size > this.maxPortBytes) {
      this.portCount(sub.port, "tooLarge");
      payload = portFailed(2);
    }
    if (sub.latest) {
      if (sub.queue.length > 0) {
        sub.queue[0] = { payload, terminal: false };
        this.portCount(sub.port, "coalesced");
      } else sub.queue.push({ payload, terminal: false });
    } else {
      if (sub.queue.length >= sub.bound) {
        this.portCount(sub.port, "refusedEmits");
        return false;
      }
      sub.queue.push({ payload, terminal: false });
    }
    this.portPump(sub);
    return true;
  }

  // The JavaScript ends the subscription, after its buffered messages.
  portClose(sub, error, threw) {
    if (sub.ended || this.live.get(sub.id) !== sub.entry) return;
    sub.ended = true;
    this.portCount(sub.port, threw ? "threw" : "closed");
    const payload = threw ? portFailed(1, String(error && error.message !== undefined ? error.message : error)) : portFailed(3);
    sub.queue.push({ payload, terminal: true });
    this.portPump(sub);
  }

  // Deliver the subscription's next message as its own turn, never inside
  // the caller; the next waits until this one has reached the engine.
  portPump(sub) {
    if (sub.waiting || sub.queue.length === 0) return;
    sub.waiting = true;
    queueMicrotask(() => {
      if (this.live.get(sub.id) !== sub.entry || this.poisoned) return;
      const { payload, terminal } = sub.queue.shift();
      if (terminal) {
        this.live.delete(sub.id);
        this.dropPushSub(sub);
      } else if (payload.parts[0][0] === RES_PORT_REPLY) this.portCount(sub.port, "messages");
      this.result(sub.id, {
        ...payload,
        after: () => {
          sub.waiting = false;
          this.portPump(sub);
        },
      });
    });
  }

  // A result turn staged from parts straight into linear memory (one copy
  // of any bytes), with the files it carries minted as handles first: a
  // port's reply (tag 14), a job's answer (tag 10) or a fetched body (tag
  // 21). Each file's `size name type` follows `parts`, then `tail` (a
  // job's output). When the heap has no slots for all of them the result
  // is `overflow` (a port's TooLarge, a job lost to a resource limit, or
  // FileFailed(TooLarge)), `overflowed` is told how many files there were
  // and how many slots, so a lost job is reported like any other, and the
  // handles minted for it are released at once. Ownership: the runtime
  // holds each file under its new token from here, until the engine
  // releases the handle; the staged bytes belong to the host until the
  // call moves them into Roc.
  callPort(node, handler, payload) {
    const x = this.x;
    try {
      // Results of operations on files are staged from parts too, without
      // files of their own.
      const files = payload.files ?? [];
      const tail = payload.tail ?? [];
      if (files.length === 0) {
        this.stageParts(payload.parts.concat(tail));
        x.event(node, handler);
        return;
      }
      const minted = x.files_stage(files.length);
      if (minted < files.length) {
        x.files_stage(0);
        if (payload.overflowed) payload.overflowed(files.length, minted);
        this.stageParts([payload.overflow ?? new Uint8Array([RES_PORT_FAILED, 2])]);
        x.event(node, handler);
        return;
      }
      const tokens = new DataView(x.memory.buffer, x.files_tokens(), 8 * minted);
      const parts = payload.parts.slice();
      for (let i = 0; i < minted; i += 1) {
        const f = files[i];
        this.files.set(tokenAt(tokens, i), f);
        parts.push(u64le(f.size), encStr(f.name ?? ""), encStr(f.type ?? ""));
      }
      this.stageParts(parts.concat(tail));
      x.event_files(node, handler);
    } finally {
      if (payload.after) payload.after();
    }
  }

  stageParts(parts) {
    let total = 0;
    for (const p of parts) total += p.length;
    const ptr = this.x.payload_reserve(total);
    if (total === 0) return;
    const view = new Uint8Array(this.x.memory.buffer, ptr, total);
    let at = 0;
    for (const p of parts) {
      view.set(p, at);
      at += p.length;
    }
  }

  // A message from the page's own JavaScript to every live subscription on
  // `port`, a `push` port: returns how many took it.
  emitPort(port, value) {
    if (this.poisoned) throw new Error(`roc engine is poisoned; port "${port}" takes no messages`);
    const d = this.portDecls.get(port);
    const h = this.portHandler(port);
    if (d === undefined || d.kind !== 3 || !h || !h.push) throw new Error(`emitPort: port "${port}" is not a subscription port with a push handler`);
    let n = 0;
    for (const sub of [...(this.pushSubs.get(port) ?? [])]) if (this.portEmit(sub, value)) n += 1;
    return n;
  }

  // Manual mode: answer pending call `id` with JSON text (verbatim, so a
  // spec can answer malformed text), a throw, TooLarge or, for a call with
  // a timeout, Timeout. Returns false when `id` is not a pending call.
  answerPort(id, answer) {
    const e = this.live.get(id);
    if (this.poisoned || e === undefined || e.kind !== "portcall") return false;
    if (answer.timeout && !(e.req.timeout > 0)) return false;
    this.live.delete(id);
    this.result(id, manualPortPayload(answer));
    return true;
  }

  // Manual mode: deliver `answer` (as for answerPort, or { closed: true })
  // to every live subscription on `port`, or only those whose argument text
  // is `arg`. Returns how many received it.
  messagePort(port, answer, arg) {
    if (this.poisoned) return 0;
    let n = 0;
    for (const [id, e] of [...this.live]) {
      if (e.kind !== "portsub" || e.req.port !== port || (arg !== undefined && e.req.msg.json !== arg)) continue;
      if (answer.closed || answer.threw !== undefined) this.live.delete(id);
      this.result(id, manualPortPayload(answer));
      n += 1;
    }
    return n;
  }

  // Live subscriptions on `port`.
  portSubscriptions(port) {
    let n = 0;
    for (const e of this.live.values()) if (e.kind === "portsub" && e.req.port === port) n += 1;
    return n;
  }

  // Hand job `fx` to the pool. Its one result (output, WorkLost or, at the
  // deadline, Timeout) is delivered as a turn unless CANCEL forgets it
  // first; `settled`, when given, is called once either way. The deadline
  // runs from here: when the request is performed, or in manual mode when
  // runEffect runs it.
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
        if (stop) stop("cancel");
        close();
      },
    };
    this.live.set(fx.id, entry);
    this.monitor.jobSubmitted(fx.id);
    // `outcome` (done, lost, timeout or unavailable) and the rest are for
    // the monitor only.
    const finish = (bytes, outcome, klass = null, output = null) => {
      if (this.live.get(fx.id) !== entry) return;
      this.live.delete(fx.id);
      this.monitor.jobAnswered(fx.id, outcome, klass, output);
      open = false;
      if (timer !== null) {
        clearTimeout(timer);
        timer = null;
        this.timers -= 1;
      }
      this.result(fx.id, bytes);
      if (settled) settled();
    };
    // In manual mode a spec's time is manual too: a deadline never fires on
    // its own, and expireEffect(id) expires it instead.
    if (fx.deadline > 0 && !this.manual && !this.manualWork) {
      this.timers += 1;
      timer = setTimeout(() => {
        timer = null;
        this.timers -= 1;
        if (stop) stop("deadline");
        finish(new Uint8Array([RES_TIMEOUT]), "timeout");
      }, fx.deadline);
    }
    // A preparation's task carries both ways to run it: preparing from the
    // preparation's input, or asking a worker that already holds the state
    // for exactly that input (`key`). The pool picks one; the answer is the
    // same either way.
    let prepared = null;
    let payload;
    if (fx.prep !== null) {
      const p = fx.prep;
      const init = fx.input.subarray(0, p.initLen);
      prepared = {
        key: { name: p.name, init, ranges: p.ranges },
        prepare: concat([encStr(p.name), init]),
        prepareObjects: fx.files.slice(0, p.initFiles),
      };
      payload = concat([encStr(fx.task), fx.input.subarray(p.initLen)]);
    } else payload = concat([encStr(fx.task), fx.input]);
    const objects = fx.prep !== null ? fx.files.slice(fx.prep.initFiles) : fx.files;
    const done = (outcome) => {
      if (outcome.output !== undefined) {
        // A job's answer (result tag 10): the files it holds become the
        // page's handles when the turn is delivered, each the worker's Blob
        // (posted by reference) as a File of its name and type. When the
        // page has no room for them the job is lost to a resource limit.
        const files = outcome.objects.map((o) => new File([o.blob], o.name, { type: o.type }));
        finish({ parts: [new Uint8Array([RES_WORK]), u32(files.length)], files, tail: [outcome.output], overflow: new Uint8Array([RES_WORK_LOST, LOST_RESOURCE_LIMIT]), overflowed: (n, room) => this.reportLost(fx, LOST_RESOURCE_LIMIT, `resource_limit: the job answered with ${n} files and the page has room for ${room}`) }, "done", null, outcome.output);
        return;
      }
      const klass = this.reportLost(fx, outcome.lost, outcome.message);
      finish(new Uint8Array([RES_WORK_LOST, outcome.lost]), outcome.lost === LOST_UNAVAILABLE ? "unavailable" : "lost", klass);
    };
    // In manual mode the deadline is not on the clock, so a finishing job
    // there is bounded by the cap alone.
    const deadline = this.manual || this.manualWork ? 0 : fx.deadline;
    stop = this.workPool().submit(payload, done, { id: fx.id, task: fx.task, objects, prepared, finish: fx.finish, deadline, maxOutput: this.maxOutputBytes });
  }

  // Report a lost job and return its class name. The `roc worker fault
  // [CLASS]` prefix is stable: the browser spec runner tells these reports
  // from page errors by it.
  reportLost(fx, code, message) {
    const klass = LOST_CLASSES[code] ?? "executor";
    console.error(`roc worker fault [${klass}] in task "${fx.task}": ${message}`);
    if (this.onWorkerFault) this.onWorkerFault({ id: fx.id, task: fx.task, class: klass, message });
    return klass;
  }

  workPool() {
    if (this.pool === null) {
      const W = (this.win && this.win.Worker) ?? globalThis.Worker;
      this.pool = new WorkPool({ module: this.module, url: this.workerUrl, max: this.maxWorkers, inline: this.workerMode === "inline", Worker: W, monitor: this.monitor, maxBytes: this.maxWorkerBytes, live: (token) => this.files.has(token) });
    }
    return this.pool;
  }

  // Terminate every worker (containment, unmount); a later job starts a
  // fresh pool.
  stopWorkers() {
    if (this.pool !== null) this.pool.shutdown();
    this.pool = null;
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
    if (e.running || e.kind === "portcall") return false;
    if (e.kind === "work") {
      this.live.delete(id);
      return new Promise((resolve) => this.startWork(e.req, () => resolve(true)));
    }
    // An operation on a file is really performed; the promise resolves once
    // its result turn has been delivered, or once it was cancelled instead.
    if (e.kind === "file") {
      this.live.delete(id);
      return new Promise((resolve) => this.startFileOp(e.req, () => resolve(true)));
    }
    // A fetch answered with a response: its body becomes the file, as a
    // real response's Blob does.
    if (e.kind === "fetch" && answer.status !== undefined) {
      this.live.delete(id);
      this.result(id, this.fetchedPayload(e.req.url, answer.status, answer.headers ?? [], new Blob([answer.body ?? ""])));
      return true;
    }
    this.live.delete(id);
    if (answer.timeout) this.result(id, new Uint8Array([RES_TIMEOUT]));
    else if (answer.network !== undefined) this.result(id, concat([new Uint8Array([RES_NETWORK]), utf8enc.encode(answer.network)]));
    else if (answer.status !== undefined) this.result(id, httpResult(answer.status, answer.body ?? "", answer.headers ?? []));
    else this.result(id, new Uint8Array([RES_FIRED]));
    return true;
  }

  // Manual mode: answer pending work job `id` as lost with fault class
  // `klass` ("contract" ... "executor", the names of LOST_CLASSES) without
  // running it, reported as a real loss is. Returns false when `id` is not a
  // pending job or `klass` is not a class.
  loseEffect(id, klass) {
    const e = this.live.get(id);
    const code = LOST_CLASSES.indexOf(klass);
    if (this.poisoned || e === undefined || e.kind !== "work" || e.running || code < 1) return false;
    this.live.delete(id);
    const reported = this.reportLost(e.req, code, "lost by the spec");
    this.monitor.jobAnswered(id, code === LOST_UNAVAILABLE ? "unavailable" : "lost", reported, null);
    this.result(id, new Uint8Array([RES_WORK_LOST, code]));
    return true;
  }

  // Manual mode: expire the deadline of pending work job `id`, which answers
  // it `Timeout` as a real expiry does (a pending job has no worker to stop).
  // Returns false when `id` is not a pending job or has no deadline.
  expireEffect(id) {
    const e = this.live.get(id);
    if (this.poisoned || e === undefined || e.kind !== "work" || e.running || !(e.req.deadline > 0)) return false;
    this.live.delete(id);
    this.monitor.jobAnswered(id, "timeout", null, null);
    this.result(id, new Uint8Array([RES_TIMEOUT]));
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

  // The page instance's figures for a monitor snapshot: linear memory, the
  // host's live allocations and bytes (metric 4, 5) and the work record's
  // counters.
  pageStats() {
    const x = this.x;
    return { memBytes: x.memory.buffer.byteLength, liveAllocs: Number(x.metric(4)), liveBytes: Number(x.metric(5)), counters: this.workRecord().counters };
  }

  // How work runs here: "inline", "workers", or "unavailable" (no Worker
  // constructor, or no compiled module to give one).
  workMode() {
    if (this.workerMode === "inline") return "inline";
    const W = (this.win && this.win.Worker) ?? globalThis.Worker;
    return this.module && typeof W === "function" ? "workers" : "unavailable";
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

// ---------------------------------------------------------------------
// Port data (see "Ports" above).

// The app's declared storage keys and, after them, its port declarations
// (design.md, Appendix B): { keys, decls }.
function readBootKeys(x) {
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
  const decls = [];
  let n = dv.getUint32(at, true);
  at += 4;
  for (; n > 0; n -= 1) {
    const len = dv.getUint32(at, true);
    const name = readStr(u8, at + 4, len);
    at += 4 + len;
    decls.push({ name, kind: u8[at], delivery: u8[at + 1], bound: dv.getUint32(at + 2, true) });
    at += 6;
  }
  return { keys, decls };
}

const PORT_SHAPES = ["", "command", "call", "subscription"];
const PORT_HANDLERS = ["command", "call", "subscribe", "push"];

// Every declared port has a handler of its shape and every handler names a
// declared port, or the page is refused before it mounts. In manual mode
// (specs) handlers are optional, and only those given are checked.
export function checkPortHandlers(decls, ports, manual) {
  if (ports === null || ports === undefined) {
    if (manual || decls.length === 0) return;
    throw new Error(`the app declares ${decls.length} port${decls.length === 1 ? "" : "s"} (${decls.map((d) => `"${d.name}"`).join(", ")}), but options.ports is not given`);
  }
  if (typeof ports !== "object") throw new Error("options.ports must be an object of port handlers by port name");
  const byName = new Map(decls.map((d) => [d.name, d]));
  for (const name of Object.keys(ports)) {
    const d = byName.get(name);
    if (d === undefined) throw new Error(`options.ports has a handler for port "${name}", which the app does not declare in with_ports`);
    const entry = ports[name];
    const has = entry !== null && typeof entry === "object" ? PORT_HANDLERS.filter((k) => (k === "push" ? entry.push === true : typeof entry[k] === "function")) : [];
    if (has.length !== 1) throw new Error(`options.ports["${name}"] must have exactly one of command, call, subscribe (functions) or push: true`);
    const want = d.kind === 1 ? ["command"] : d.kind === 2 ? ["call"] : ["subscribe", "push"];
    if (!want.includes(has[0])) throw new Error(`port "${name}" is declared by the app as a ${PORT_SHAPES[d.kind]}, but options.ports["${name}"] is a ${has[0]} handler`);
  }
  if (manual) return;
  for (const d of decls) {
    if (ports[d.name] === undefined) throw new Error(`port "${d.name}" is declared by the app as a ${PORT_SHAPES[d.kind]}, but options.ports has no ${d.kind === 3 ? "subscribe or push" : PORT_SHAPES[d.kind]} handler for it`);
  }
}

// A value that is not JSON data, found while serialising an answer.
class PortDataError extends Error {}

function describeValue(v) {
  if (typeof v !== "object") return `a ${typeof v}`;
  const c = Object.getPrototypeOf(v)?.constructor;
  return `a ${c && c.name ? c.name : "object"}`;
}

// Serialise a handler's answer strictly: { json, blobs, files }. Anything
// JSON.stringify would silently change or drop (NaN, a Map, a function, a
// cycle) is a PortDataError naming where it is.
export function portData(value) {
  const blobs = [];
  const files = [];
  const open = new Set();
  const at = (path) => (path === "" ? "the top" : path);
  const enc = (v, path, depth) => {
    if (v === null || v === undefined) return "null";
    switch (typeof v) {
      case "boolean":
        return v ? "true" : "false";
      case "number":
        if (!Number.isFinite(v)) throw new PortDataError(`${v} at ${at(path)}`);
        return JSON.stringify(v);
      case "string":
        return JSON.stringify(v);
      case "bigint":
        return `"${v}"`;
      case "object":
        break;
      default:
        throw new PortDataError(`${describeValue(v)} at ${at(path)}`);
    }
    if (depth >= 512) throw new PortDataError(`containers nested more than 512 deep at ${at(path)}`);
    if (v instanceof Uint8Array) {
      blobs.push(v);
      return `{"$bytes":${blobs.length - 1}}`;
    }
    if (v instanceof ArrayBuffer) {
      blobs.push(new Uint8Array(v));
      return `{"$bytes":${blobs.length - 1}}`;
    }
    if (ArrayBuffer.isView(v)) {
      blobs.push(new Uint8Array(v.buffer, v.byteOffset, v.byteLength));
      return `{"$bytes":${blobs.length - 1}}`;
    }
    if (typeof Blob !== "undefined" && v instanceof Blob) {
      files.push(v);
      return `{"$file":${files.length - 1}}`;
    }
    if (v instanceof Date) return JSON.stringify(v.toJSON());
    if (open.has(v)) throw new PortDataError(`a cycle at ${at(path)}`);
    open.add(v);
    let out;
    if (Array.isArray(v)) {
      out = `[${v.map((x, i) => enc(x, `${path}[${i}]`, depth + 1)).join(",")}]`;
    } else {
      const proto = Object.getPrototypeOf(v);
      if (proto !== Object.prototype && proto !== null) throw new PortDataError(`${describeValue(v)} at ${at(path)}`);
      const fields = [];
      for (const k of Object.keys(v)) {
        if (v[k] === undefined) continue;
        fields.push(`${JSON.stringify(k.startsWith("$") ? `$${k}` : k)}:${enc(v[k], `${path}.${k}`, depth + 1)}`);
      }
      out = `{${fields.join(",")}}`;
    }
    open.delete(v);
    return out;
  };
  return { json: enc(value, "", 0), blobs, files };
}

// A message as the handler sees it: the JSON with every bytes marker a
// Uint8Array, every file marker the File, and dictionary keys unescaped.
export function portValue({ json, blobs, files }) {
  const revive = (v) => {
    if (Array.isArray(v)) return v.map(revive);
    if (v === null || typeof v !== "object") return v;
    const keys = Object.keys(v);
    if (keys.length === 1 && keys[0] === "$bytes") return blobs[v.$bytes];
    if (keys.length === 1 && keys[0] === "$file") return files[v.$file];
    const out = {};
    for (const k of keys) Object.defineProperty(out, k.startsWith("$") ? k.slice(1) : k, { value: revive(v[k]), enumerable: true, writable: true, configurable: true });
    return out;
  };
  return revive(JSON.parse(json));
}

// Result tag 14 for `{ json, blobs, files }`: its parts (the file records
// are added when the handles are minted) and its size against the bound.
function portReplyPayload({ json, blobs, files }) {
  const text = utf8enc.encode(json);
  const parts = [new Uint8Array([RES_PORT_REPLY]), u32(text.length), text, u32(blobs.length)];
  let size = text.length;
  for (const b of blobs) {
    parts.push(u32(b.length), b);
    size += b.length;
  }
  parts.push(u32(files.length));
  return { parts, files, size };
}

// Result tag 15: 1 threw (with text), 2 too large, 3 closed.
function portFailed(klass, text = "") {
  const parts = [new Uint8Array([RES_PORT_FAILED, klass])];
  if (klass === 1) parts.push(utf8enc.encode(text));
  return { parts, files: [] };
}

// A spec's answer: JSON text verbatim, a throw, TooLarge, Timeout or
// Closed.
function manualPortPayload(answer) {
  if (answer.timeout) return { parts: [new Uint8Array([RES_TIMEOUT])], files: [] };
  if (answer.tooLarge) return portFailed(2);
  if (answer.closed) return portFailed(3);
  if (answer.threw !== undefined) return portFailed(1, answer.threw);
  const p = portReplyPayload({ json: answer.json, blobs: [], files: [] });
  return { parts: p.parts, files: [] };
}

export async function mountRocEngineApp({ wasmUrl, root, ...options }) {
  const response = await fetch(wasmUrl);
  if (!response.ok) throw new Error(`failed to fetch ${wasmUrl}: ${response.status}`);
  const module = await WebAssembly.compile(await response.arrayBuffer());
  const instance = await WebAssembly.instantiate(module, pageImports(module));
  const runtime = new RocEngineRuntime(instance.exports, root, { ...options, module });
  runtime.mount();
  return runtime;
}
