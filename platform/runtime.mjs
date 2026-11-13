import { checkedI64, i64Bytes, i32Bytes, checkedLanguages, browserLanguages, checkedSeed, browserSeed, checkedZone, probeTimeZone } from "./environment.mjs";

// Browser runtime of the web platform. The engine, which is Roc code
// (platform/Core.roc, behind the authoring API in platform/Engine.roc),
// decides everything; this file applies its command bytes to the DOM and
// routes DOM events back as (node id, handler number, payload bytes).
// Commands are read straight out of Wasm linear memory after each call; views
// are re-created per apply (a call may grow memory).
//
// Encoding: design.md, Appendix B, protocol version PROTOCOL_VERSION. A module
// whose `protocol_version()` differs is refused at mount.
//
// Text-kind event payloads (UTF-8, staged with `payload_reserve` and moved
// into Roc by `event`): click/submit "", input: the target's value, change: "true"/"false"
// for a checkbox or radio, else the target's value. Keys use their typed binary payload.
// A `submit` event that reaches the mount root is always default-prevented:
// forms are app-managed and never navigate the page.
//
// Boot bytes carry the URL, the declared storage values, whether the browser
// is online and the page visible, each declared media query's match, and
// whether local storage is available at all (it is not when reaching or
// reading it throws). Scoped environment subscriptions report later changes.
//
// Ingress: declared reports wait for the frame, with one replaceable entry
// per source. Occurrences pin earlier reports and drain them synchronously.
// At MAX_QUEUED entries an idle runtime drains early; exceeding that bound
// while synchronously busy poisons with `resource_limit`. A waiting view
// transition instead applies its held batch and drains. A drain delivers at most
// MAX_QUEUED turns before idle, bounding a one-event-per-turn feedback loop.
//
// Effects (see "Effects" in Engine.roc): the engine emits FX requests with
// ids, CANCEL, NAV, STORAGE and TITLE commands. They are collected while a
// batch is applied and performed after its DOM changes. A marked transition
// performs commands naming no node before waiting for its update callback;
// node commands and shown properties wait until its DOM changes are applied.
// The page instance cannot be called or staged while that batch is waiting.
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
// until its timeout (ten minutes when it has none), which then terminates
// its worker. A timeout does the same to a job not cancelled and answers
// `Timeout`. A worker whose instance
// faults is discarded and its job answered `WorkLost(class)`; the
// diagnostic goes to console.error and options.onWorkerFault, never into
// the result. Without a Worker constructor every job is `WorkLost
// (unavailable)`. options.workers === "inline" runs jobs on this thread in a
// second instance of the module instead, one at a time (a timeout then
// only stops a job that has not started). The hosted effects a job may
// call (reading a file, building one) exist only in a worker, so a job
// that reaches one there is answered `WorkLost(unavailable)`, and the
// inline instance it left mid-call is replaced for the next job, as a
// faulted worker is; a job that reaches none answers as in a worker.
// Poisoning or unmounting this
// runtime terminates every worker. In manual mode a job waits in `pending`
// until runEffect(id) runs it, loseEffect(id, class) answers it lost or
// expireEffect(id) expires its timeout, which never fires on its own.
// options.manualWork holds work jobs the same way while every other effect
// runs on its own.
//
// Monitor: `runtime.monitor` (options.monitor) observes jobs, worker
// instances and turns: a pull snapshot, push events and optional User
// Timing entries, all bounded (see "The monitor" below). The pool and this
// runtime report to it after they act; it decides nothing.
//
// Each handler declaration carries a payload kind and static policy bits.
// The closed kind table builds typed input and layout facts; event names are
// bare names, including custom names containing colons. Policies prevent the default or
// stop bubbling above the mount. The files kind's drop rule also prevents
// dragover's default so the browser permits the drop.
// Size and seen declarations start shared browser observers instead of DOM
// listeners. Registrations belong to their node (a row root for a template
// descendant), and RELEASE unobserves only that owner's registrations.
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
// in declaration sections; the runtime refuses to mount (it throws) when a
// declared port has no handler of its shape or a handler names a port the
// app does not declare. A command (opcode 19 PORT) is performed after the
// batch like NAV; a call (FX kind 9) is answered once (result tag 14 or
// 15), aborted on CANCEL or at its timeout (Timeout); a subscription (FX
// kind 10) declares its delivery: `Latest` reports the newest waiting value
// at the frame; `Every(n)` keeps n and `emit` returns false beyond them.
// Every queues at most one message per subscription in ingress while the
// next waits for its turn. close() ends it with Closed,
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
// Attributes carry explicit presence; a present empty string stays present.
// Element properties have their own commands and a closed table. Attribute
// text is never interpreted as absence, including empty or false text.

// The wire protocol version this runtime implements (design.md, Appendix B).
export const PROTOCOL_VERSION = 18;

// The most events queued behind a running batch (see "Ingress" above).
export const MAX_QUEUED = 4096;

// A visible page whose browser supplies no frames must still make progress.
export const FRAME_WAIT_MS = 100;

// The engine's work counters start at this `metric` index (design.md,
// Appendix B); `workRecord()` decodes the whole record.
export const WORK_METRIC_BASE = 16;


const TRANSITION_WAIT_MS = 1000;

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

// The longest timeout a job may have (the engine caps `timeout_ms` at
// this), and the bound on a cancelled job that finishes and has none.
const MAX_TIMEOUT_MS = 600000;
const RES_PORT_ANSWER = 14;
const RES_PORT_FAILED = 15;
const RES_FETCHED = 21;
const RES_MATCHES = 22;
const RES_COPIED = 23;
const RES_CLIPBOARD_FAILED = 24;
const RES_STORAGE_FAILED = 25;
const RES_PROGRESS = 26;

// The default and largest bound on one port answer or message, JSON text
// and bytes together (options.maxPortBytes).
export const DEFAULT_PORT_BYTES = 4 * 1024 * 1024;
export const MAX_PORT_BYTES = 64 * 1024 * 1024;


// Result tag 11's class byte: an instance's fault code (1-5) is its class.
const LOST_UNAVAILABLE = 6;
const LOST_EXECUTOR = 7;

const HOLE_TEXT = 1;
const HOLE_ATTR = 2;
const HOLE_CLICK = 3;
const HOLE_BIND = 4;
const HOLE_REF = 5;
const HOLE_PROP = 6;



export async function instantiateEngineBytes(bytes) {
  const module = await WebAssembly.compile(bytes);
  const instance = await WebAssembly.instantiate(module, pageImports(module));
  return { module, instance };
}

// Thrown by an effect stub of an instance that is not a worker's: a job
// running inline reached a hosted effect only a worker can perform.
class EffectUnavailable extends Error {}

// The imports of an instance that is not a worker's (design.md,
// "Workers"): the page's own instance and the inline instance. Every module
// imports the platform's hosted effects (`env.js_*`), which the platform
// hands the engine with each job whether or not its tasks call them, and only a
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

// Wire strings are length-delimited data; a leading U+FEFF is not a file BOM.
const utf8 = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });

// Reject incomplete or invalid text before the ASCII fast path can fabricate
// characters from missing bytes or a decoder can replace invalid UTF-8.
function readStr(u8, at, n) {
  if (!Number.isInteger(at) || !Number.isInteger(n) || at < 0 || n < 0 || at > u8.length || n > u8.length - at) throw new Error("truncated command string");
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

// Preflight retains only the declared template shape, never DOM nodes. Both
// shape reading and construction use templateNode's one wire grammar.
function walkShape(root, path, protocol) {
  let node = root;
  for (let i = 0; i < path.length; i += 2) {
    const container = protocol.CONTAINERS[path[i]];
    if (!container) throw new Error(`unknown hole container ${path[i]}`);
    const children = container === CONTAINER_APPLIERS.TEMPLATE_CONTENT ? node.content : node.children;
    if (!children) throw new Error("template path requires the declared container");
    node = children[path[i + 1]];
    if (!node) throw new Error("template path does not address a child");
  }
  return node;
}

function walk(root, path, protocol) {
  let node = root;
  for (let i = 0; i < path.length; i += 2) {
    const container = protocol.CONTAINERS[path[i]];
    if (!container) throw new Error(`unknown hole container ${path[i]}`);
    node = container(node).childNodes[path[i + 1]];
    if (!node) throw new Error("template path does not address a child");
  }
  return node;
}


const HTML_NS = "http://www.w3.org/1999/xhtml";
const SVG_NS = "http://www.w3.org/2000/svg";
const MATHML_NS = "http://www.w3.org/1998/Math/MathML";

// Registry keys bind the module's names to real decoding implementations before
// init. Command layout and DOM validation remain independent from Roc.
const NAMESPACE_READERS = {
  HTML: reader => { reader.namespace = HTML_NS; },
  SVG: reader => { reader.namespace = SVG_NS; },
  MATHML: reader => { reader.namespace = MATHML_NS; },
  NONE: reader => { reader.namespace = null; },
  URI: reader => {
    const value = nameString(reader);
    if (!value) throw new Error("explicit namespace URI is empty");
    reader.namespace = value;
  },
};

function nameString(reader) {
  const size = reader.dv.getUint32(reader.at, true);
  reader.at += 4;
  const text = readStr(reader.u8, reader.at, size);
  reader.at += size;
  return text;
}

function validateExpandedName(name, element) {
  const localPattern = /^(?:[A-Za-z][^\0\t\n\f\r\u0020/>]*|[:_\u0080-\u{10FFFF}][A-Za-z0-9-.:_\u0080-\u{10FFFF}]*)$/u;
  if (!(element ? localPattern.test(name.local) : name.local.length > 0 && !/[\0\t\n\f\r\u0020/=>]/u.test(name.local))) throw new Error("invalid namespace-dependent local name");
  if (name.prefix !== null) {
    if (!name.prefix || /[\0\t\n\f\r\u0020/:>]/u.test(name.prefix)) throw new Error("invalid namespace prefix");
    if (name.namespace === null) throw new Error("namespace prefix without namespace");
    if (name.prefix === "xml" && name.namespace !== "http://www.w3.org/XML/1998/namespace") throw new Error("xml prefix requires XML namespace");
  } else if (name.local.includes(":") && !((element && (name.namespace === HTML_NS || name.namespace === null)) || (!element && name.namespace === null))) {
    throw new Error("unrepresentable unprefixed local name");
  }
  const ordinary = name.prefix === null && ((element && (name.namespace === HTML_NS || name.namespace === null)) || (!element && name.namespace === null));
  const declares = name.prefix === "xmlns" || name.qualified === "xmlns";
  if (!ordinary && (name.namespace === "http://www.w3.org/2000/xmlns/") !== declares) throw new Error("invalid xmlns namespace pairing");
}

function expandedName(reader, element) {
  const code = reader.u8[reader.at++];
  const read = reader.protocol.NAMESPACES[code];
  if (!read) throw new Error(`unknown namespace kind ${code}`);
  read(reader);
  const namespace = reader.namespace;
  const prefix = nameString(reader) || null;
  const local = nameString(reader);
  const name = { namespace, prefix, local, qualified: prefix === null ? local : `${prefix}:${local}` };
  validateExpandedName(name, element);
  return name;
}

// Read the actual wrapper's finite facts without walking ancestors or choosing
// construction semantics. Roc classifies the context; these are not app Boot.
function mountRootBytes(root, protocol) {
  if (!root || root.nodeType !== 1) throw new Error("mount-root must be an Element");
  const namespace = root.namespaceURI;
  const prefix = root.prefix ?? "";
  const local = root.localName;
  for (const value of [namespace ?? "", prefix, local]) {
    if (typeof value !== "string" || !value.isWellFormed()) throw new Error("mount-root facts must be well-formed Unicode");
  }
  let code;
  if (namespace === HTML_NS) code = protocol.NS_HTML;
  else if (namespace === SVG_NS) code = protocol.NS_SVG;
  else if (namespace === MATHML_NS) code = protocol.NS_MATHML;
  else if (namespace === null) code = protocol.NS_NONE;
  else code = protocol.NS_URI;
  const uriLength = code === protocol.NS_URI ? namespace.length + 4 : 0;
  if (9 + prefix.length + local.length + uriLength > 65536) throw new Error("mount-root exceeds 65536 encoded bytes");
  const bytes = concat([new Uint8Array([code]), ...(code === protocol.NS_URI ? [encStr(namespace)] : []), encStr(prefix), encStr(local)]);
  if (bytes.length > 65536) throw new Error("mount-root exceeds 65536 encoded bytes");
  return bytes;
}

function createNamedElement(doc, name) {
  if (name.namespace === null && name.prefix === null && (name.local.includes(":") || name.local === "xmlns")) {
    const source = doc.implementation.createDocument(null, "");
    return doc.importNode(source.createElement(name.local), false);
  }
  const element = name.namespace === HTML_NS && name.prefix === null && (name.local.includes(":") || name.local === "xmlns")
    ? doc.createElement(name.local)
    : doc.createElementNS(name.namespace, name.qualified);
  if (element.namespaceURI !== name.namespace || element.prefix !== name.prefix || element.localName !== name.local) throw new Error("element factory changed expanded identity");
  return element;
}

// Container roles select an already-decided DOM target. HTML template.content
// is distinct from ordinary childNodes, including on the same element interface.
const CONTAINER_APPLIERS = {
  CHILDREN: element => element,
  TEMPLATE_CONTENT(element) {
    if (element.namespaceURI !== HTML_NS || element.localName !== "template" || !element.content) throw new Error("template content requires an HTML template");
    return element.content;
  },
};

function readContainer(reader, element) {
  const code = reader.u8[reader.at++];
  const apply = reader.protocol.CONTAINERS[code];
  if (!apply) throw new Error(`unknown child container ${code}`);
  const target = apply(element);
  if (target !== element) element.__childTarget = target;
  return { code, target };
}

const TEMPLATE_NODE_APPLIERS = {
  ELEMENT(reader) {
    const name = expandedName(reader, true);
    const element = reader.dry
      ? { children: [], content: name.namespace === HTML_NS && name.local === "template" ? [] : null }
      : createNamedElement(reader.doc, name);
    let code, target;
    if (reader.dry) {
      code = reader.u8[reader.at++];
      const container = reader.protocol.CONTAINERS[code];
      if (!container) throw new Error(`unknown child container ${code}`);
      target = container === CONTAINER_APPLIERS.TEMPLATE_CONTENT ? element.content : element.children;
      if (!target) throw new Error("template content requires an HTML template");
    } else ({ code, target } = readContainer(reader, element));
    if (reader.dry ? target === element.content : target !== element) reader.contentOwners.push(reader.path.slice());
    const attributes = reader.u8[reader.at++];
    for (let index = 0; index < attributes; index += 1) {
      const attribute = expandedName(reader, false), value = nameString(reader);
      if (!reader.dry) setAttr(element, attribute, value);
    }
    const children = reader.u8[reader.at++];
    for (let index = 0; index < children; index += 1) {
      reader.path.push(code, index);
      const child = templateNode(reader);
      if (reader.dry) target.push(child); else target.appendChild(child);
      reader.path.length -= 2;
    }
    return element;
  },
  TEXT(reader) { const value = nameString(reader); return reader.dry ? {} : reader.doc.createTextNode(value); },
  COMMENT(reader) { const value = nameString(reader); return reader.dry ? {} : reader.doc.createComment(value); },
};

function templateNode(reader) {
  const kind = reader.u8[reader.at++];
  const apply = reader.protocol.TEMPLATE_NODES[kind];
  if (!apply) throw new Error(`unknown template node kind ${kind}`);
  return apply(reader);
}

// Controlled text values (design.md, "Controlled inputs"): an equal value is
// a no-op (caret and selection stay put); a differing value is deferred while
// the control is focused or composing (IME) and applied on blur, unless a
// later input echo already matched it.
function setValue(el, value) {
  if (el.value === value) {
    el.__deferred = undefined;
    el.__applyValue = false;
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
  if (name.namespace === null && name.prefix === null && (name.local.includes(":") || name.local === "xmlns")) {
    if (el.namespaceURI === HTML_NS && /[A-Z]/u.test(name.local)) {
      const existing = el.getAttributeNodeNS(null, name.local);
      if (existing) existing.value = value;
      else {
        const source = el.ownerDocument.implementation.createDocument(null, "");
        const attribute = source.createAttribute(name.local);
        attribute.value = value;
        el.setAttributeNodeNS(attribute);
      }
    } else el.setAttribute(name.local, value);
  } else el.setAttributeNS(name.namespace, name.qualified, value);
}

// ApplyValue uses the last rendered property even when equality pruning
// emitted no new PROP and the user changed the live value meanwhile.
function applyRenderedValue(el) {
  checkValueControl(el, el.__renderedValueNode);
  if (typeof el.__renderedValue !== "string") throw new Error("ApplyValue requires a rendered value property");
  el.__deferred = undefined;
  if (el.value !== el.__renderedValue) el.value = el.__renderedValue;
}

// A file input's live value is a program contract error, rather than an
// executor defect. Its type can change in the batch, so only application of
// the property can make this check against the current DOM state.
class ContractFault extends Error {}

function checkValueControl(el, node) {
  if (el.tagName === "INPUT" && el.type === "file") throw new ContractFault(`contract: value property on file input at node ${node}`);
}

// Stateless command implementations are the semantic roles supported by this
// runtime. Mount binds metadata codes to these actual functions, not to another
// number table. A reader belongs only to its guarded applyBatch invocation.
function applyHoleCommand(reader) {
  const { dv, u8, op } = reader;
  let at = reader.at;
  const node = dv.getUint32(at, true);
  const row = this.lookup(node);
  const hole = this.templates[row.__site].holes[u8[at + 4]];
  const n = dv.getUint32(at + 5, true);
  const target = row.__ht[u8[at + 4]];
  const v = readStr(u8, at + 9, n);
  if (op === this.protocol.OP_TEXT) target.nodeValue = v;
  else {
    if (hole.kind !== HOLE_PROP) throw new Error("HPROP names a non-property hole");
    setProp(target, hole.prop, v, node, this);
  }
  at += 9 + n;
  return at;
}
function applyNodeCommand(reader) {
  const { dv, doc, op } = reader;
  const node = dv.getUint32(reader.at, true);
  const parent = dv.getUint32(reader.at + 4, true);
  const before = dv.getUint32(reader.at + 8, true);
  reader.at += 12;
  const element = op === this.protocol.OP_ELEM;
  const el = element ? createNamedElement(doc, expandedName(reader, true))
    : op === this.protocol.OP_COMMENT ? doc.createComment(nameString(reader)) : doc.createTextNode(nameString(reader));
  if (element) readContainer(reader, el);
  el.__id = node;
  this.place(el, parent, before);
  if (element && el.namespaceURI === HTML_NS && el.localName === "option") settleSelect(el.parentNode);
  this.statics[node] = el;
  return reader.at;
}

// The pure first-batch pass consumes the same effect operands without
// retaining work. Ordinary application preserves the stream's effect order.
function queueEffect(runtime, reader, effect) {
  if (reader.mode !== "preflight") runtime.fxOut.push(effect);
}

const COMMAND_APPLIERS = {
  INST(reader) {
    const { dv, u8 } = reader;
    let at = reader.at;
    const node = dv.getUint32(at, true);
    const parent = dv.getUint32(at + 4, true);
    const before = dv.getUint32(at + 8, true);
    const site = dv.getUint32(at + 12, true);
    const tpl = this.templates[site];
    at += 16;
    const el = tpl.root.cloneNode(true);
    for (const path of tpl.contentOwners) {
      const owner = walk(el, path, this.protocol);
      owner.__childTarget = CONTAINER_APPLIERS.TEMPLATE_CONTENT(owner);
    }
    el.__rn = node;
    const holes = tpl.holes;
    // Hole targets are resolved once, here: a nested site inserting
    // content into the row later shifts sibling indices.
    const targets = new Array(holes.length);
    for (let i = 0; i < holes.length; i += 1) targets[i] = walk(el, holes[i].path, this.protocol);
    el.__ht = targets;
    el.__aliases = [];
    for (let i = 0; i < holes.length; i += 1) {
      const hole = holes[i];
      const target = targets[i];
      if (hole.kind === HOLE_TEXT) {
        const n = dv.getUint32(at, true);
        target.nodeValue = readStr(u8, at + 4, n);
        at += 4 + n;
      } else if (hole.kind === HOLE_ATTR) {
        at = applyAttribute(this, u8, dv, at, target, hole.name);
      } else if (hole.kind === HOLE_PROP) {
        const n = dv.getUint32(at, true);
        setProp(target, hole.prop, readStr(u8, at + 4, n), node, this);
        at += 4 + n;
      } else if (hole.kind === HOLE_CLICK) {
        checkHandlerElement(target, hole.name, hole.entry, this.protocol);
        if (target.__h === undefined) target.__h = {};
        target.__h[hole.name] = hole.entry;
        this.registerLayout(target, hole.name, hole.entry, el);
      } else if (hole.kind === HOLE_BIND || hole.kind === HOLE_REF) {
        const id = dv.getUint32(at, true);
        this.statics[id] = target;
        el.__aliases.push(id);
        at += 4;
      } else throw new Error(`unknown template hole kind ${hole.kind}`);
    }
    this.place(el, parent, before);
    if (el.tagName === "OPTION") settleSelect(el.parentNode);
    el.__site = site;
    this.statics[node] = el;
    this.sites[site].add(node);
    return at;
  },
  HATTR(reader) {
    const { dv, u8 } = reader;
    let at = reader.at;
    const row = this.lookup(dv.getUint32(at, true));
    const index = u8[at + 4];
    const hole = this.templates[row.__site].holes[index];
    if (hole.kind !== HOLE_ATTR) throw new Error("HATTR names a non-attribute hole");
    at += 5;
    at = applyAttribute(this, u8, dv, at, row.__ht[index], hole.name);
    return at;
  },
  TEXT: applyHoleCommand,
  HPROP: applyHoleCommand,
  MOVE(reader) {
    const { dv } = reader;
    let at = reader.at;
    const el = this.lookup(dv.getUint32(at, true));
    const before = dv.getUint32(at + 4, true);
    el.parentNode.insertBefore(el, before === 0 ? null : this.lookup(before));
    at += 8;
    return at;
  },
  RELEASE(reader) {
    const { dv } = reader;
    let at = reader.at;
    this.releaseNode(this.lookup(dv.getUint32(at, true)));
    at += 4;
    return at;
  },
  REMOVE(reader) {
    const { dv } = reader;
    let at = reader.at;
    const node = dv.getUint32(at, true);
    const el = this.lookup(node);
    this.forgetSubtree(el);
    el.parentNode.removeChild(el);
    this.statics[node] = undefined;
    at += 4;
    return at;
  },
  CLEAR(reader) {
    const { dv } = reader;
    let at = reader.at;
    const parentId = dv.getUint32(at, true);
    const owner = this.lookup(parentId);
    const parent = parentId === 0 ? owner : owner.__childTarget ?? owner;
    const site = dv.getUint32(at + 4, true);
    for (let child = parent.firstChild; child; child = child.nextSibling) this.forgetSubtree(child);
    this.sites[site] = new Set();
    parent.textContent = "";
    at += 8;
    return at;
  },
  TEMPLATE(reader) {
    const { dv, u8, mode, batch, offset } = reader;
    let at = reader.at;
    const tpl = dv.getUint32(at, true);
    const n = dv.getUint32(at + 4, true);
    this.templates[tpl] = mode === "update" ? batch.definitions.get(offset) : this.parseTemplate(u8, dv, at + 8, n);
    this.sites[tpl] = new Set();
    at += 8 + n;
    return at;
  },
  ELEM: applyNodeCommand,
  TEXTNODE: applyNodeCommand,
  COMMENT: applyNodeCommand,
  ATTR(reader) {
    const el = this.lookup(reader.dv.getUint32(reader.at, true));
    reader.at += 4;
    const name = expandedName(reader, false);
    return applyAttribute(this, reader.u8, reader.dv, reader.at, el, name);
  },
  PROP(reader) {
    const { dv, u8 } = reader;
    let at = reader.at;
    const node = dv.getUint32(at, true);
    const prop = u8[at + 4];
    const n = dv.getUint32(at + 5, true);
    setProp(this.lookup(node), prop, readStr(u8, at + 9, n), node, this);
    at += 9 + n;
    return at;
  },
  LISTEN(reader) {
    const { dv, u8 } = reader;
    let at = reader.at;
    const node = dv.getUint32(at, true);
    const el = this.statics[node];
    const n = dv.getUint32(at + 8, true);
    const type = readStr(u8, at + 12, n);
    el.__rn = node;
    if (el.__h === undefined) el.__h = {};
    const h = dv.getUint32(at + 4, true);
    const kind = u8[at + 12 + n];
    const policies = dv.getUint32(at + 13 + n, true);
    const entry = handlerEntry(h, kind, policies, type, this.protocol);
    checkHandlerElement(el, type, entry, this.protocol);
    el.__h[type] = entry;
    if (policies & this.protocol.POLICY_DOCUMENT) this.registerDocumentKey(el, type, entry);
    else if (kind !== this.protocol.KIND_SIZE && kind !== this.protocol.KIND_SEEN) this.listen(type);
    this.registerLayout(el, type, entry, el);
    at += 17 + n;
    return at;
  },
  SETTEXT(reader) {
    const { dv, u8 } = reader;
    let at = reader.at;
    const el = this.lookup(dv.getUint32(at, true));
    const n = dv.getUint32(at + 4, true);
    el.nodeValue = readStr(u8, at + 8, n);
    at += 8 + n;
    return at;
  },
  FX(reader) {
    const { dv, u8 } = reader;
    let at = reader.at;
    const id = dv.getUint32(at, true);
    const kind = u8[at + 4];
    at += 5;
    const str = () => {
      const n = dv.getUint32(at, true);
      const v = readStr(u8, at + 4, n);
      at += 4 + n;
      return v;
    };
    const httpOptions = () => {
      const cacheByte = u8[at++], credentialsByte = u8[at++];
      const cache = this.protocol.HTTP_CACHE[cacheByte];
      const credentials = this.protocol.HTTP_CREDENTIALS[credentialsByte];
      if (!cache || !credentials || (kind === 12 && cacheByte !== 1)) throw new ContractFault("invalid HTTP cache or credentials");
      const progressMs = dv.getUint32(at, true); at += 4;
      if (progressMs !== 0 && progressMs < 16) throw new ContractFault("progress interval must be zero or at least 16 ms");
      return { cache, credentials, progressMs };
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
      queueEffect(this, reader, { op: "http", id, method, url, headers, body, timeout, ...httpOptions() });
    } else if (kind === 2) {
      queueEffect(this, reader, { op: "get", id, key: str() });
    } else if (kind === 3 || kind === 4) {
      queueEffect(this, reader, { op: kind === 3 ? "timer" : "interval", id, ms: dv.getUint32(at, true) });
      at += 4;
    } else if (kind === 5) {
      queueEffect(this, reader, { op: "popstate", id });
    } else if (kind === 6) {
      queueEffect(this, reader, { op: "online", id });
    } else if (kind === 7) {
      queueEffect(this, reader, { op: "visibility", id });
    } else if (kind === 8) {
      const task = str();
      const n = dv.getUint32(at, true);
      // Copied out: linear memory may move before the job is posted.
      if (n > u8.length - at - 4) throw new Error("truncated work input");
      const input = reader.mode === "preflight" ? null : u8.slice(at + 4, at + 4 + n);
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
        const { token, start, len } = fileRange(dv, at);
        const file = reader.mode === "preflight" ? undefined : this.files.get(token);
        if (reader.mode !== "preflight" && file === undefined) throw new Error(`a work request names file handle ${token}, which this runtime does not hold`);
        if (reader.mode !== "preflight") { files.push(file); ranges.push(token, start, len); }
        at += 24;
      }
      const timeout = dv.getUint32(at, true);
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
        if (initLen > n || initFiles > refs) throw new Error(`malformed preparation operands for worker task ${task}`);
        if (reader.mode !== "preflight") prep = { name, initLen, initFiles, ranges: ranges.slice(0, 3 * initFiles) };
      } else if (flag !== 0) throw new Error(`work request flag ${flag} is not 0 or 1`);
      queueEffect(this, reader, { op: "work", id, task, input, files, timeout, finish: cancel === 2, prep });
    } else if (kind === 11) {
      const mode = u8[at];
      if (mode !== 1 && mode !== 2) throw new Error(`unknown file read mode ${mode}`);
      const maxBytes = tokenAt(dv, 0, at + 25);
      queueEffect(this, reader, { op: "read", id, mode, maxBytes, ...this.fileRef(dv, at + 1, reader.mode === "preflight") });
      at += 33;
    } else if (kind === 12) {
      const method = str();
      const url = str();
      const headers = [];
      let n = dv.getUint32(at, true);
      at += 4;
      for (; n > 0; n -= 1) headers.push([str(), str()]);
      const ref = this.fileRef(dv, at, reader.mode === "preflight");
      const timeout = dv.getUint32(at + 24, true);
      at += 28;
      queueEffect(this, reader, { op: "upload", id, method, url, headers, ...ref, timeout, ...httpOptions() });
    } else if (kind === 13) {
      const algorithm = u8[at];
      if (algorithm !== 1) throw new Error(`unknown digest algorithm ${algorithm}`);
      queueEffect(this, reader, { op: "digest", id, algorithm, ...this.fileRef(dv, at + 1, reader.mode === "preflight") });
      at += 25;
    } else if (kind === 14) {
      queueEffect(this, reader, { op: "url", id, ...this.fileRef(dv, at, reader.mode === "preflight") });
      at += 24;
    } else if (kind === 9) {
      const port = str();
      const m = this.readPortMessage(u8, dv, at, reader.mode === "preflight");
      at = m.at;
      const timeout = dv.getUint32(at, true);
      at += 4;
      queueEffect(this, reader, { op: "portcall", id, port, msg: m.msg, timeout });
    } else if (kind === 10) {
      const port = str();
      const m = this.readPortMessage(u8, dv, at, reader.mode === "preflight");
      at = m.at;
      queueEffect(this, reader, { op: "portsub", id, port, msg: m.msg });
    } else if (kind === 15) {
      const method = str();
      const url = str();
      const headers = [];
      let n = dv.getUint32(at, true);
      at += 4;
      for (; n > 0; n -= 1) headers.push([str(), str()]);
      const timeout = dv.getUint32(at, true);
      at += 4;
      queueEffect(this, reader, { op: "fetch", id, method, url, headers, body: "", timeout, ...httpOptions() });
    } else if (kind === 16) {
      queueEffect(this, reader, { op: "media", id, query: str() });
    } else if (kind === 17) {
      queueEffect(this, reader, { op: "sessionget", id, key: str() });
    } else if (kind === 18) {
      queueEffect(this, reader, { op: "storagechanges", id, key: str() });
    } else if (kind === 19) {
      const text = str(), htmlFlag = u8[at++];
      if (htmlFlag !== 0 && htmlFlag !== 1) throw new Error(`invalid clipboard HTML flag ${htmlFlag}`);
      queueEffect(this, reader, { op: "clipboard", id, text, html: htmlFlag ? str() : null });
    } else if (kind === 20) {
      queueEffect(this, reader, { op: "storagefailures", id });
    } else throw new Error(`unknown effect kind ${kind}`);
    return at;
  },
  SAVE(reader) {
    const { dv, u8 } = reader;
    let at = reader.at;
    // Resolved now, while a handle the batch released still names its
    // file; the download is made after the batch.
    const ref = this.fileRef(dv, at, reader.mode === "preflight");
    const n = dv.getUint32(at + 24, true);
    const name = readStr(u8, at + 28, n);
    at += 28 + n;
    queueEffect(this, reader, { op: "save", name, blob: ref.blob, type: ref.file?.type });
    return at;
  },
  CANCEL(reader) {
    const { dv } = reader;
    let at = reader.at;
    queueEffect(this, reader, { op: "cancel", id: dv.getUint32(at, true) });
    at += 4;
    return at;
  },
  NAV(reader) {
    const { dv, u8 } = reader;
    let at = reader.at;
    const mode = u8[at];
    const n = dv.getUint32(at + 1, true);
    queueEffect(this, reader, { op: mode === 1 ? "push" : "replace", url: readStr(u8, at + 5, n) });
    at += 5 + n;
    return at;
  },
  GUARD(reader) {
    const { u8 } = reader;
    let at = reader.at;
    const on = u8[at++];
    if (on !== 0 && on !== 1) throw new Error(`invalid leave guard flag ${on}`);
    queueEffect(this, reader, { op: "guardleave", on: on === 1 });
    return at;
  },
  STORAGE(reader) {
    const { dv, u8 } = reader;
    let at = reader.at;
    const mode = u8[at];
    if (mode < 1 || mode > 4) throw new Error(`unknown storage operation ${mode}`);
    const n = dv.getUint32(at + 1, true);
    const key = readStr(u8, at + 5, n);
    at += 5 + n;
    if (mode === 1 || mode === 3) {
      const m = dv.getUint32(at, true);
      queueEffect(this, reader, { op: "set", session: mode === 3, key, value: readStr(u8, at + 4, m) });
      at += 4 + m;
    } else queueEffect(this, reader, { op: "remove", session: mode === 4, key });
    return at;
  },
  REF(reader) {
    const { dv, u8 } = reader;
    let at = reader.at;
    const mode = u8[at], node = dv.getUint32(at + 1, true);
    if (mode < 1 || mode > 7) throw new Error(`unknown reference operation ${mode}`);
    at += 5;
    const command = { op: "ref", mode, node, element: this.lookup(node) };
    if (mode === 6) {
      const block = u8[at++], inline = u8[at++], behavior = u8[at++];
      if (block > 3 || inline > 3 || behavior > 2 || behavior === undefined) throw new Error("invalid scroll-into-view operands");
      command.options = { block: ["start", "center", "end", "nearest"][block], inline: ["start", "center", "end", "nearest"][inline], behavior: ["auto", "instant", "smooth"][behavior] };
    } else if (mode === 7) {
      const edge = () => {
        const tag = u8[at++];
        if (tag === 0) return { kind: "keep" };
        if (tag === 1) return { kind: "start" };
        if (tag === 2) return { kind: "end" };
        if (tag !== 3) throw new Error(`invalid scroll edge ${tag}`);
        const pixels = dv.getUint32(at, true); at += 4;
        return { kind: "px", pixels };
      };
      const top = edge(), left = edge(), behavior = u8[at++];
      if (behavior > 2 || behavior === undefined) throw new Error("invalid scroll-to behavior");
      command.top = top; command.left = left; command.behavior = ["auto", "instant", "smooth"][behavior];
    }
    queueEffect(this, reader, command);
    return at;
  },
  TITLE(reader) {
    const { dv, u8 } = reader;
    let at = reader.at;
    const n = dv.getUint32(at, true);
    queueEffect(this, reader, { op: "title", text: readStr(u8, at + 4, n) });
    at += 4 + n;
    return at;
  },
  PORT(reader) {
    const { dv, u8 } = reader;
    let at = reader.at;
    const n = dv.getUint32(at, true);
    const port = readStr(u8, at + 4, n);
    const m = this.readPortMessage(u8, dv, at + 4 + n, reader.mode === "preflight");
    at = m.at;
    queueEffect(this, reader, { op: "port", port, msg: m.msg });
    return at;
  },
  TRANSITION(reader) {
    const { mode, len, flags, dv, u8, batch } = reader;
    let at = reader.at;
    if (mode === "update") { reader.marked = true; return len; }
    if (!flags || reader.marked) throw new Error("TRANSITION requires a marked batch and must occur once, last");
    reader.marked = true;
    const count = dv.getUint32(at, true); at += 4;
    const types = [];
    for (let i = 0; i < count; i += 1) { const n = dv.getUint32(at, true); types.push(readStr(u8, at + 4, n)); at += 4 + n; }
    if (at !== len) throw new Error("TRANSITION must be last");
    batch.types = types;
    return at;
  },
};

function applyAttribute(runtime, u8, dv, at, el, name) {
  const present = u8[at++];
  if (present === 0) el.removeAttributeNS(name.namespace, name.local);
  else if (present === 1) {
    const n = dv.getUint32(at, true);
    setAttr(el, name, readStr(u8, at + 4, n));
    at += 4 + n;
  } else throw new Error(`invalid attribute presence ${present}`);
  return at;
}

const PROPERTY_APPLIERS = {
  value: {
    apply(el, value, node) {
      checkValueControl(el, node);
      el.__renderedValueNode = node;
      el.__renderedValue = value;
      setValue(el, value);
      if (el.tagName === "SELECT") el.__v = value;
      el.setAttribute("value", value);
      if (el.tagName === "OPTION") settleSelect(el.parentNode);
    },
  },
  checked: {
    apply(el, value) {
      if (value !== "true" && value !== "false") throw new Error(`invalid checked property value ${JSON.stringify(value)}`);
      el.checked = value === "true";
      if (el.checked) el.setAttribute("checked", "");
      else el.removeAttribute("checked");
    },
  },
  pointer_zone: {
    apply(el, value) { el.__pointerZone = value; },
  },
  keymap_down: {
    apply(el, value) { el.__keymapDown = parseKeymap(value); },
  },
  keymap_up: {
    apply(el, value) { el.__keymapUp = parseKeymap(value); },
  },
  shown: {
    apply(el, value, node, runtime) {
      if (!["hidden", "open", "modal"].includes(value)) throw new Error(`invalid shown property value ${JSON.stringify(value)}`);
      runtime.decideShown(el, 6, value, node);
    },
  },
  popover_shown: {
    apply(el, value, node, runtime) {
      if (value !== "true" && value !== "false") throw new Error(`invalid popover_shown property value ${JSON.stringify(value)}`);
      if (!["auto", "manual"].includes(el.getAttribute("popover"))) throw new Error("popover_shown requires a static auto or manual popover");
      runtime.decideShown(el, 7, value, node);
    },
  },
};

function setProp(el, prop, value, node, runtime) {
  const row = runtime.protocol.PROPS[prop];
  if (!row) throw new Error(`unknown element property ${prop}`);
  if (el.nodeType !== 1) throw new Error(`element property ${row.name} requires an element`);
  if (row.elements && !row.elements.includes(el.tagName)) throw new Error(`element property ${row.name} does not apply to ${el.tagName}`);
  row.apply(el, value, node, runtime);
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

// Policy roles own their actual validation or browser action. Their keys are
// also the complete semantic roles mount requires; bit numbers come from facts.
// Validation order preserves the existing diagnostic priority.
const POLICY_APPLIERS = {
  CAPTURE: {
    validate(kind, type, policies, p) {
      if ((policies & p.POLICY_CAPTURE) && (kind !== p.KIND_POINTER || type !== "pointerdown")) throw new Error("capture policy requires a pointerdown pointer handler");
    },
  },
  PACED: {
    validate(kind, type, policies, p) {
      if ((policies & p.POLICY_PACED) && !((kind === p.KIND_POINTER && type === "pointermove") || [p.KIND_SCROLL, p.KIND_SIZE, p.KIND_SEEN].includes(kind))) throw new Error("paced policy requires pointermove or a layout handler");
      if ([p.KIND_SCROLL, p.KIND_SIZE, p.KIND_SEEN].includes(kind) && !(policies & p.POLICY_PACED)) throw new Error("layout handlers require paced delivery");
    },
  },
  AHEAD: {
    validate(kind, _type, policies, p) {
      if ((policies & p.POLICY_AHEAD) && kind !== p.KIND_SEEN) throw new Error("ahead policy requires a seen handler");
      if ((kind === p.KIND_SIZE || kind === p.KIND_SEEN) && (policies & ~(p.POLICY_PACED | p.POLICY_AHEAD))) throw new Error("observation handlers have no DOM event policies");
    },
  },
  DOCUMENT: {
    validate(kind, _type, policies, p) {
      if ((policies & p.POLICY_DOCUMENT) && kind !== p.KIND_KEY) throw new Error("document policy requires a key handler");
    },
  },
  PREVENT: {
    validate(kind, _type, policies, p) {
      if (kind === p.KIND_KEY && (policies & p.POLICY_PREVENT)) throw new Error("key prevention belongs to its keymap");
    },
    perform(event) { event.preventDefault(); },
  },
  STOP: {
    perform(event) { event.stopPropagation(); },
  },
};

// Validate the closed declaration tables before retaining a listener. An
// unknown number or bit is a producer/consumer mismatch, contained as executor.
function handlerEntry(h, kind, policies, type, protocol) {
  const row = protocol.PAYLOAD_KINDS[kind];
  if (!row) throw new Error(`unknown event payload kind ${kind}`);
  if (row.events && !row.events.includes(type)) throw new Error(`event payload kind ${kind} does not apply to ${type}`);
  if ((policies & ~protocol.policy_mask) !== 0) throw new Error(`unknown event policy bits ${policies}`);
  for (const validate of protocol.policyValidators) validate(kind, type, policies, protocol);
  if (kind === protocol.KIND_TEXT && (type === "keydown" || type === "keyup")) throw new Error("text key handler requires on_key");
  return { h, kind, policies };
}

function checkHandlerElement(element, type, handler, protocol) {
  const { KIND_OPEN_STATE } = protocol;
  if (handler.kind !== KIND_OPEN_STATE) return;
  if (type === "close" && element.tagName !== "DIALOG") throw new Error("open-state close requires a dialog");
  if (type === "toggle" && !["auto", "manual"].includes(element.getAttribute("popover"))) throw new Error("open-state toggle requires a popover");
}

// The files a files-kind event carries, captured before the browser clears
// a drop's or paste's list after dispatch.
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
    default:
      return "";
  }
}

const PAYLOAD_APPLIERS = {
  TEXT: { payload: payloadOf },
  PASTE: {},
  FILES: {
    payload(event) {
      const files = filesOf(event);
      return files.length === 0 ? null : { files };
    },
  },
  POINTER: {},
  KEY: {},
  SCROLL: {},
  SIZE: {},
  SEEN: {},
  OPEN_STATE: {
    payload(event) {
      const element = event.target;
      if (event.type === "change") {
        if (element.namespaceURI !== "http://www.w3.org/1999/xhtml" || element.tagName !== "INPUT" || !["checkbox", "radio"].includes(element.type)) return null;
        return new Uint8Array([element.checked ? 1 : 0]);
      }
      if (event.type === "close") {
        if (element.tagName !== "DIALOG") throw new Error("open-state close requires a dialog");
        return new Uint8Array([element.open ? 1 : 0]);
      }
      if (!["auto", "manual"].includes(element.getAttribute("popover"))) throw new Error("open-state toggle requires a popover");
      return new Uint8Array([element.matches(":popover-open") ? 1 : 0]);
    },
  },
};

// Build tables only after the complete metadata item has been validated. Each
// runtime holds its own bindings; mounting another module cannot change them.
function bindProtocolFacts(facts) {
  for (const rows of Object.values(facts)) {
    for (const row of rows) if (typeof row === "object") {
      for (const value of Object.values(row)) if (Array.isArray(value)) Object.freeze(value);
      Object.freeze(row);
    }
    Object.freeze(rows);
  }
  Object.freeze(facts);
  const protocol = { facts, text_entry_excluded: facts.text_entry_excluded };
  for (const row of facts.ops) protocol[`OP_${row.name}`] = row.code;
  for (const row of facts.kinds) protocol[`KIND_${row.name}`] = row.code;
  for (const row of facts.policies) protocol[`POLICY_${row.name}`] = row.bit;
  for (const row of facts.namespaces) protocol[`NS_${row.name}`] = row.code;
  for (const row of facts.template_nodes) protocol[`NODE_${row.name}`] = row.code;
  protocol.LOST_CLASSES = facts.fault_classes;
  protocol.HTTP_CACHE = Object.fromEntries(facts.http_cache.map(row => [row.code, row.name]));
  protocol.HTTP_CREDENTIALS = Object.fromEntries(facts.http_credentials.map(row => [row.code, row.name]));
  const bind = (rows, implementations, key, make, label) => {
    const names = new Set(rows.map(row => row.name));
    for (const row of rows) if (!Object.hasOwn(implementations, row.name)) throw new Error(`unknown ${label} name ${JSON.stringify(row.name)}`);
    for (const name of Object.keys(implementations)) if (!names.has(name)) throw new Error(`missing ${label} name ${JSON.stringify(name)}`);
    return Object.freeze(Object.fromEntries(rows.map(row => [row[key], Object.freeze(make(row, implementations[row.name]))])));
  };
  protocol.NAMESPACES = bind(facts.namespaces, NAMESPACE_READERS, "code", (_row, implementation) => implementation, "namespace");
  protocol.CONTAINERS = bind(facts.child_containers, CONTAINER_APPLIERS, "code", (_row, implementation) => implementation, "child container");
  protocol.TEMPLATE_NODES = bind(facts.template_nodes, TEMPLATE_NODE_APPLIERS, "code", (_row, implementation) => implementation, "template node");
  protocol.COMMANDS = bind(facts.ops, COMMAND_APPLIERS, "code", (_row, implementation) => implementation, "opcode");
  protocol.POLICIES = bind(facts.policies, POLICY_APPLIERS, "bit", (_row, implementation) => implementation, "policy");
  protocol.policyValidators = Object.freeze(Object.keys(POLICY_APPLIERS).flatMap(name => {
    const implementation = protocol.POLICIES[protocol[`POLICY_${name}`]];
    return implementation.validate ? [implementation.validate] : [];
  }));
  protocol.policy_mask = facts.policies.reduce((mask, row) => mask | row.bit, 0);
  protocol.PROPS = bind(facts.properties, PROPERTY_APPLIERS, "index", (row, implementation) => ({
    name: row.name, elements: row.elements.length ? row.elements.map(name => name.toUpperCase()) : null, apply: implementation.apply,
  }), "property");
  protocol.PAYLOAD_KINDS = bind(facts.kinds, PAYLOAD_APPLIERS, "code", (row, implementation) => ({
    events: row.events.length ? row.events : null, payload: implementation.payload,
  }), "payload kind");
  return Object.freeze(protocol);
}

const SCROLL_HISTORY = 4096;
const U64_MAX = (1n << 64n) - 1n;

// Observation retains weak identities rather than nodes or recycled command
// addresses. Exhaustion disables observation, never the command it observes.
// Observation never bounds application requests. Retained type bytes and
// record count are bounded independently; ordinals remain absolute.
class TransitionHistory {
  constructor(maximum = U64_MAX) { this.maximum = maximum; this.clear(); }
  clear() { this.count = 0n; this.exhausted = false; this.records = new Map(); this.bytes = 0; }
  add(types, cause) {
    if (this.exhausted) return;
    if (this.count === this.maximum) { this.exhausted = true; this.records.clear(); this.bytes = 0; return; }
    this.count += 1n;
    const bytes = types.reduce((n, type) => n + 4 + utf8enc.encode(type).length, 0);
    while (this.records.size && (this.records.size >= 4096 || this.bytes + bytes > 1048576)) {
      const oldest = this.records.keys().next().value;
      this.bytes -= this.records.get(oldest).bytes; this.records.delete(oldest);
    }
    if (bytes <= 1048576) {
      this.records.set(this.count, { ordinal: this.count, types: types.slice(), cause, bytes });
      this.bytes += bytes;
    }
  }
  total() { if (this.exhausted) throw new Error("transition history ordinal exhausted"); return this.count; }
  at(ordinal) {
    this.total();
    if (ordinal < 1n || ordinal > this.count) throw new Error(`transition ${ordinal} has not been performed`);
    const record = this.records.get(ordinal);
    if (!record) throw new Error(`transition ${ordinal} is outside retained transition history (newest 4096, at most 1048576 encoded type bytes)`);
    return record;
  }
}

class ScrollHistory {
  constructor(maximum = U64_MAX) {
    this.maximum = maximum;
    this.clear();
  }

  clear() { this.count = 0n; this.exhausted = false; this.records = []; }

  add(element, kind) {
    if (this.exhausted) return;
    if (this.count === this.maximum) { this.exhausted = true; this.records = []; return; }
    this.count += 1n;
    this.records[Number((this.count - 1n) % BigInt(SCROLL_HISTORY))] = { ordinal: this.count, target: new WeakRef(element), kind };
  }

  total() {
    if (this.exhausted) throw new Error("scroll history ordinal exhausted");
    return this.count;
  }

  at(ordinal) {
    this.total();
    if (ordinal < 1n || ordinal > this.count) throw new Error(`scroll command ${ordinal} was not performed`);
    if (this.count - ordinal >= BigInt(SCROLL_HISTORY)) throw new Error(`scroll command ${ordinal} is outside retained scroll history (newest ${SCROLL_HISTORY})`);
    const record = this.records[Number((ordinal - 1n) % BigInt(SCROLL_HISTORY))];
    if (record.ordinal !== ordinal) throw new Error("scroll history has an incoherent ordinal");
    return record;
  }
}

// This manual-driver observer records actual modal entry, not DOM order or
// the value an app requested. Neither links nor the reverse index own a node.
class ModalOrder {
  constructor() { this.clear(); }
  clear() { this.byElement = new WeakMap(); this.head = null; this.tail = null; }
  remove(element) {
    const entry = this.byElement.get(element);
    if (!entry) return;
    if (entry.before) entry.before.after = entry.after; else this.head = entry.after;
    if (entry.after) entry.after.before = entry.before; else this.tail = entry.before;
    this.byElement.delete(element);
  }
  add(element) {
    this.remove(element);
    const entry = { element: new WeakRef(element), before: this.tail, after: null };
    if (this.tail) this.tail.after = entry; else this.head = entry;
    this.tail = entry;
    this.byElement.set(element, entry);
  }
  top(root) {
    while (this.tail) {
      const element = this.tail.element.deref();
      if (element?.isConnected && root.contains(element) && element.matches(":modal")) return element;
      if (element) this.remove(element);
      else {
        this.tail = this.tail.before;
        if (this.tail) this.tail.after = null; else this.head = null;
      }
    }
    return null;
  }
}

// A rendered map is indexed once. Dispatch visits only the matching chord's
// entries, preserving the first declaration whose place applies.
function keyModifiers(event) {
  return (event.ctrlKey ? 1 : 0) | (event.altKey ? 2 : 0) | (event.shiftKey ? 4 : 0) | (event.metaKey ? 8 : 0);
}
function asciiLetter(key) { return /^[A-Za-z]$/.test(key); }
function asciiAlnum(key) { return /^[A-Za-z0-9]$/.test(key); }
// The browser supplies Unicode categories; the native oracle independently
// uses roc-lang/unicode. The all-scalar browser contract checks their agreement.
function symbolKey(key) {
  return /^[\p{P}\p{S}]$/u.test(key);
}
function chordIndex(key, modifiers) {
  return `${symbolKey(key) ? modifiers & ~4 : modifiers}:${asciiLetter(key) ? key.toLowerCase() : key}`;
}
function textEntry(target, excluded) {
  if (target?.nodeType !== 1) target = target?.parentElement;
  return !!target && (target.tagName === "TEXTAREA" || target.tagName === "SELECT" ||
    (target.tagName === "INPUT" && !excluded.includes(target.type)) || target.isContentEditable);
}
function parseKeymap(value) {
  const bytes = utf8enc.encode(value);
  const exact = new Map(), physical = new Map();
  let every = null, at = 0;
  const add = (index, key, entry) => {
    const entries = index.get(key);
    if (entries) entries.push(entry); else index.set(key, [entry]);
  };
  while (at < bytes.length) {
    const policy = bytes[at++];
    if ((policy === 97 || policy === 111) && bytes[at] === 42) {
      at += 1;
      if (at !== bytes.length || every !== null) throw new Error("keymap every must occur once at the end");
      every = { outside: policy === 111, prevent: false };
      continue;
    }
    if (policy !== 112 && policy !== 107) throw new Error("invalid keymap policy");
    const place = bytes[at++];
    if (place !== 97 && place !== 111) throw new Error("invalid keymap place");
    let modifiers = 0;
    for (let bit = 0; bit < 4; bit += 1) {
      const flag = bytes[at++];
      if (flag === [67, 65, 83, 77][bit]) modifiers |= 1 << bit;
      else if (flag !== 45) throw new Error("invalid keymap modifier");
    }
    const start = at;
    while (bytes[at] >= 48 && bytes[at] <= 57) at += 1;
    if (at === start || bytes[at++] !== 58 || (at - start > 2 && bytes[start] === 48)) throw new Error("invalid keymap key length");
    const length = Number(new TextDecoder().decode(bytes.subarray(start, at - 1)));
    if (!Number.isSafeInteger(length) || length > bytes.length - at) throw new Error("invalid keymap key length");
    const key = utf8.decode(bytes.subarray(at, at + length));
    at += length;
    const entry = { key, modifiers, outside: place === 111, prevent: policy === 112 };
    add(exact, chordIndex(key, modifiers), entry);
    if (asciiAlnum(key)) {
      const code = asciiLetter(key) ? `Key${key.toUpperCase()}` : `Digit${key}`;
      add(physical, `${modifiers}:${code}`, entry);
    }
  }
  return { exact, physical, every };
}
function matchKey(map, event, excluded) {
  if (!map || typeof event.key !== "string" || event.key === "") return null;
  const outside = !textEntry(event.target, excluded);
  const first = (entries) => entries?.find((entry) => !entry.outside || outside) ?? null;
  if (!event.isComposing && event.keyCode !== 229) {
    const modifiers = keyModifiers(event);
    const exact = first(map.exact.get(chordIndex(event.key, modifiers)));
    if (exact) return exact;
    if (!asciiAlnum(event.key)) {
      const physical = first(map.physical.get(`${modifiers}:${event.code}`));
      if (physical) return physical;
    }
  }
  if (map.every && (!map.every.outside || outside)) return { ...map.every, key: event.key, modifiers: keyModifiers(event) };
  return null;
}
function keyPayload(event, heard) {
  if (!event.key.isWellFormed() || !(event.code ?? "").isWellFormed()) throw new Error("key event contains malformed UTF-16");
  const flags = keyModifiers(event) | (event.repeat ? 16 : 0) | (event.isComposing || event.keyCode === 229 ? 32 : 0);
  return concat([new Uint8Array([flags]), encStr(event.key), encStr(event.code ?? ""), new Uint8Array([heard.modifiers]), encStr(heard.key)]);
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


function fileRange(dv, at) {
  const token = tokenAt(dv, 0, at), start = tokenAt(dv, 0, at + 8), len = tokenAt(dv, 0, at + 16);
  if (![token, start, len, start + len].every(Number.isSafeInteger)) throw new Error("file range exceeds the safe integer boundary");
  return { token, start, len };
}

// Storage uses UTF-16 strings. Refuse unrepresentable text rather than
// letting TextEncoder silently replace a lone surrogate at the Roc boundary.
function storageText(value) {
  if (typeof value !== "string" || !value.isWellFormed()) throw new Error("storage returned text that is not well-formed Unicode");
  return value;
}

function storageResult(value) {
  return value === null ? new Uint8Array([RES_MISSING]) : concat([new Uint8Array([RES_VALUE]), utf8enc.encode(storageText(value))]);
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
// runtime call it at each transition, after they have acted (the pool reads
// the clock for a post just before posting, since the worker may receive
// the job before this thread runs again), and it keeps
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

const END_CAUSES = ["cancel", "timeout", "fault", "executor", "unmount", "contained", "retired"];

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
    this.count = { issued: 0, done: 0, lost: 0, timeout: 0, cancelled: 0, unavailable: 0, lateAnswers: 0, wastedMs: 0, inputBytes: 0, outputBytes: 0, prepared: 0, reused: 0, prepareMs: 0 };
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
        if (pg.captureRefused !== undefined) page.captureRefused = pg.captureRefused;
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
  jobIssued(id, task, input, timeoutMs, held) {
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
      timeoutMs,
      wasted: false,
      output: null,
      t: { issue: at, submit: null, post: null, recv: null, begin: null, call: null, ret: null, sent: null, answer: null, turnStart: null, turnEnd: null, end: null },
    };
    this.jobs.set(id, job);
    this.count.issued += 1;
    this.count.inputBytes += input.length;
    const p = this.perTask(task);
    p.jobs += 1;
    p.inputBytes += input.length;
    const event = { kind: "job-issue", id, task, inputBytes: input.length, timeoutMs, at, held: !!held };
    if (this.payloads) event.input = input.slice();
    this.emit(event);
  }

  // The job was handed to the pool (its timeout starts now).
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
  // state it holds). `at` is the clock as the pool read it just before the
  // post: a worker may receive the job before the page's thread gets to
  // report it, so a reading taken here could be later than the worker's
  // own `recv`.
  jobPosted(id, seq, mode = "work", prep = null, at = this.tick()) {
    const job = this.jobs.get(id);
    const inst = this.insts.get(seq);
    if (job === undefined || inst === undefined || !this.live()) return;
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

  // The instance answered the job. `answer` is { t: [recv, begin, call, ret,
  // sent], mem: [memBytes, liveAllocs, liveBytes], outputBytes } in the
  // instance's clock.
  jobAnswered(id, seq, answer) {
    const job = this.jobs.get(id);
    const inst = this.insts.get(seq);
    if (job === undefined || inst === undefined || !this.live()) return;
    const at = this.tick();
    job.t.answer = at;
    if (answer && Array.isArray(answer.t) && answer.t.length === 5) {
      const [recv, begin, call, ret, sent] = answer.t.map((v) => v + inst.off);
      Object.assign(job.t, { recv, begin, call, ret, sent });
    }
    if (answer && typeof answer.outputBytes === "number") job.outputBytes = answer.outputBytes;
    // A preparation's task: how long preparing took (null when it reused).
    if (answer && typeof answer.prepareMs === "number") job.prepareMs = answer.prepareMs;
    if (answer && answer.held === false) inst.held = null;
    if (answer && Array.isArray(answer.mem)) this.memory(inst, answer.mem);
    this.release(inst, at);
    inst.jobs += 1;
  }

  // The runtime decided the job's result and is delivering it as a turn:
  // `outcome` is done, lost, timeout or unavailable.
  jobDelivered(id, outcome, faultClass, output) {
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
  // its timeout, so its instance stays busy until instanceFinished (or
  // instanceEnded with cause `timeout`).
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

  // An answer arrived for a job the pool no longer holds.
  lateAnswer() {
    this.count.lateAnswers += 1;
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
    if ((job.phase === "running" || job.phase === "starting") && job.t.answer === null && !job.finishing) {
      this.waste(job, this.lastAt);
      const inst = this.insts.get(job.instance);
      if (inst !== undefined && inst.job === job.id) this.release(inst, this.lastAt);
    }
  }

  // A started job that will never answer: its time on the instance is lost.
  waste(job, at) {
    if (job.wasted || job.t.post === null || job.t.answer !== null) return;
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
      stage: span(job.cold ? t.begin : t.recv, t.call),
      compute: span(t.call, t.ret),
      copyOut: span(t.ret, t.sent),
      fromWorker: span(t.sent, t.answer),
      resultWait: span(t.answer, t.turnStart),
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
      timeoutMs: job.timeoutMs,
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

  // The pool discarded the instance. `cause` is cancel, timeout, fault,
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
    if (t.post !== null && t.answer !== null) this.measure("roc:work.run", t.post, t.answer, { id: r.id, instance: r.instance }, lane);
    if (t.answer !== null && t.turnEnd !== null) this.measure("roc:work.result", t.answer, t.turnEnd, { id: r.id }, "jobs");
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
  constructor({ module, url, max, inline, Worker: W, monitor, faultClasses, maxBytes = Infinity, live = () => true }) {
    this.LOST_CLASSES = faultClasses;
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
  // `stop("timeout")` when its timeout expired. `objects` are the job's
  // own files; `prepared`, for a preparation's task, is { key, prepare,
  // prepareObjects }: `payload` is then the task's (`task:str input:rest`)
  // and `prepare` the preparation's (`prep:str init:rest`). `finish` says
  // that a cancelled running job completes (its answer dropped) instead of
  // ending its worker; `timeout` (ms from now, 0 for none) still bounds it
  // then; `maxOutput` bounds what it appends to builders.
  submit(payload, done, { id, task, objects = [], prepared = null, finish = false, timeout = 0, maxOutput = 0 }) {
    const limit = timeout > 0 ? Math.min(timeout, MAX_TIMEOUT_MS) : MAX_TIMEOUT_MS;
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
  // bounded: if it has not completed by its timeout (ten minutes after it
  // was performed when it has none), its worker is terminated as a
  // timed-out job's is, so a job that never ends cannot hold a worker for
  // good. Anything else running is stopped by terminating its worker. A
  // timeout always stops.
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

  // A finishing job reached its timeout: end its worker and give the
  // worker's place to the queue.
  overran(job) {
    job.timer = null;
    if (!job.finishing || job.slot === null || this.closed) return;
    this.discard(job.slot, "timeout");
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
    // The post hands the job to another thread, which may receive it before
    // this one runs again: the clock is read before the post, and the
    // monitor is told after it, as for every transition.
    const postedAt = this.monitor.tick();
    slot.worker.postMessage(m, transfer);
    this.monitor.jobPosted(job.id, slot.seq, mode, job.prepared === null ? null : job.prepared.key.name, postedAt);
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
  // them may outlive it. A busy holder is checked when its job answers.
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
      this.monitor.lateAnswer();
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
        this.monitor.jobAnswered(job.id, slot.seq, { t: m.t, mem: m.mem, outputBytes: m.output.byteLength, prepareMs: m.prepareMs, held: m.held });
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
    this.discard(slot, lost === LOST_EXECUTOR ? "executor" : "fault", { class: this.LOST_CLASSES[lost], message });
    if (job !== null) {
      job.slot = null;
      this.settle(job, { lost, message });
    }
    this.pump();
  }

  // `cause`: cancel, timeout, fault, executor, retired or shutdown (for
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
          mon.jobAnswered(job.id, this.inlineSeq, { t: [begin, begin, call, ret, sent], mem, outputBytes: output.length, prepareMs, held: this.inlineKey !== null });
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
          mon.instanceEnded(this.inlineSeq, lost === LOST_EXECUTOR ? "executor" : "fault", { class: this.LOST_CLASSES[lost], message });
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

// The deployment marks the mount wrapper explicitly. No descendant spelling
// assigns an engine address or an adoption role.
const PICTURE_MARKER = "data-roc-picture";
const PICTURE_FAILED = "data-roc-failed";
const PICTURE_HOLD = Symbol("roc-picture-hold");

function markedPicture(root) {
  return root?.nodeType === 1 && root.hasAttribute(PICTURE_MARKER);
}

function holdPicture(root) {
  // A failed loader has no runtime to retain the hold. The one token stays
  // with its root across retries and becomes unreachable with that root.
  if (!root[PICTURE_HOLD]) root[PICTURE_HOLD] = { inert: root.hasAttribute("inert") };
  if (!root.hasAttribute("inert")) root.setAttribute("inert", "");
}

function restorePictureHold(runtime) {
  const hold = runtime.root[PICTURE_HOLD];
  if (!hold) return;
  delete runtime.root[PICTURE_HOLD];
  if (!hold.inert) runtime.root.removeAttribute("inert");
}

function failPicture(root) {
  root.setAttribute(PICTURE_FAILED, "");
}

function finishPicture(runtime) {
  if (!runtime.picturePending) return;
  runtime.picturePending = false;
  runtime.root.removeAttribute(PICTURE_MARKER);
  runtime.root.removeAttribute(PICTURE_FAILED);
  restorePictureHold(runtime);
}

// A module can fail before there is a runtime whose containment path can
// report it. Keep the document's picture and use the same fault vocabulary.
function pictureLoadFault(root, error, onFault) {
  holdPicture(root);
  failPicture(root);
  const message = String(error?.message ?? error);
  const fault = { class: "executor", code: 0, message, trap: String(error) };
  console.error(`roc engine fault [executor]: ${message}`);
  if (onFault) onFault(fault);
}

export class RocEngineRuntime {
  constructor(exports, root, options = {}) {
    this.x = exports;
    this.root = root;
    this.pictureManaged = markedPicture(root);
    this.picturePending = this.pictureManaged;
    if (this.picturePending) holdPicture(root);
    this.doc = options.document ?? globalThis.document;
    this.statics = [];
    this.sites = [];
    this.templates = [];
    this.listening = new Map();
    this.internal = [];
    this.documentKeys = new Map();
    this.documentListeners = new Map();
    this.heardKeys = new WeakSet();
    this.onEvent = (event) => { if (!this.picturePending && event.bubbles) this.guard(() => this.handle(event)); };
    this.onCapture = (event) => { if (!this.picturePending && !event.bubbles) this.guard(() => this.handle(event)); };
    this.busy = false;
    this.pendingTransition = null;
    this.transitionIdle = Promise.resolve();
    this.transitionIdleState = null;
    this.transitionEpoch = {};
    this.viewTransitions = options.viewTransitions ?? "document";
    if (this.viewTransitions !== "document" && this.viewTransitions !== "off") throw new TypeError('viewTransitions must be "document" or "off"');
    this.queue = { head: null, tail: null, length: 0 };
    this.reportSources = new Map();
    this.reportEpoch = {};
    this.reportsReplaced = 0;
    this.reportDrain = null;
    this.reportDue = false;
    this.pointerLog = [];
    this.captureRefused = 0;
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
    // Armed request timeout and progress timers (must return to zero).
    this.timers = 0;
    this.fxOut = [];
    // id -> { kind, req, cancel } for every effect this runtime holds.
    this.live = new Map();
    // Manual mode: awaited non-subscription requests in issue order.
    this.issued = [];
    this.win = options.window ?? globalThis.window;
    const environment = options.environment === undefined ? {} : options.environment;
    if (typeof environment !== "object" || environment === null || Array.isArray(environment)) throw new Error("options.environment must be an object of readers");
    for (const key of Object.keys(environment)) {
      if (!["online", "visible", "matchMedia", "now", "seed", "languages", "timeZone"].includes(key)) throw new Error(`options.environment has an unknown reader "${key}"`);
      if (typeof environment[key] !== "function") throw new Error(`options.environment.${key} must be a function`);
    }
    this.environment = environment;
    // One registration per live observed element and kind. The reverse index
    // releases only an owning node's registrations, including row descendants.
    this.observations = new Map();
    this.observationOwners = new Map();
    this.layoutObservers = new Map();
    this.mediaQueries = [];
    this.manualScrollers = this.manual ? new Map() : null;
    this.pendingManualScrolls = new Set();
    this.manualScrollError = null;
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
    // "Workers"): a builder's parts are held in memory, and the browser does
    // not page a large in-memory Blob to disk. An append beyond it is
    // refused with TooLarge, which the job sees.
    this.maxOutputBytes = options.maxOutputBytes ?? 256 * 1024 * 1024;
    if (!Number.isInteger(this.maxOutputBytes) || this.maxOutputBytes < 0) throw new Error(`maxOutputBytes: ${this.maxOutputBytes} is not a whole number of bytes`);
    // Manual mode: the files the app saved (`SAVE`), in order, as
    // { name, blob }, for a spec to read.
    this.saveLog = [];
    this.scrollLog = this.manual ? new ScrollHistory() : null;
    this.transitionLog = this.manual ? new TransitionHistory() : null;
    this.modalOrder = this.manual ? new ModalOrder() : null;
    this.nativeTasks = new Map();
    this.nativeObservationError = null;
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
    this.leaveGuard = false;
    this.leaveListener = null;
    this.storageChanges = new Map();
    this.storageListener = null;
    this.storageFailureHead = null;
    this.storageFailureTail = null;
    this.storageFailureEpoch = {};
    this.storageFailureSubscribers = new Map();
    this.storageFailureCount = 0;
    this.storageFailureTask = null;
    this.clipboardText = "";
    this.clipboardHtml = "";
    this.clipboardWrites = 0n;
    this.clipboardObservationError = null;
    this.manualClipboardDenied = options.manualClipboardDenied ?? false;
    this.maxPasteBytes = options.maxPasteBytes ?? 4 * 1024 * 1024;
    if (!Number.isSafeInteger(this.maxPasteBytes) || this.maxPasteBytes < 0) throw new Error("maxPasteBytes must be a nonnegative safe integer");
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
    this.sessionStorage = options.sessionStorage ?? (() => {
      try { return this.win.sessionStorage; }
      catch { return null; }
    })();
  }

  // The last applied GUARD is the complete policy. This listener never
  // enters Roc and deliberately survives poisoning of the visible page.
  setLeaveGuard(on) {
    if (on === this.leaveGuard) return;
    this.leaveGuard = on;
    if (on) {
      this.leaveListener = event => { event.preventDefault(); event.returnValue = true; };
      this.win.addEventListener("beforeunload", this.leaveListener);
    } else if (this.leaveListener !== null) {
      this.win.removeEventListener("beforeunload", this.leaveListener);
      this.leaveListener = null;
    }
  }

  // Manual assertions observe the last successful write and an exact count,
  // never retain earlier clipboard contents or affect request performance.
  clipboardSnapshot() {
    if (this.clipboardObservationError) throw new Error(this.clipboardObservationError);
    return { text: this.clipboardText, html: this.clipboardHtml, writes: this.clipboardWrites.toString() };
  }

  unlinkStorageFailure(item) {
    if (item.previous) item.previous.next = item.next;
    else this.storageFailureHead = item.next;
    if (item.next) item.next.previous = item.previous;
    else this.storageFailureTail = item.previous;
    item.owner.pendingFailures.delete(item);
    item.next = null; item.previous = null;
    this.storageFailureCount -= 1;
  }

  clearStorageFailures() {
    if (this.storageFailureTask !== null) clearTimeout(this.storageFailureTask);
    this.storageFailureTask = null;
    while (this.storageFailureHead) this.unlinkStorageFailure(this.storageFailureHead);
    this.storageFailureEpoch = {};
  }

  storageWriteFailed(fx, error) {
    if (this.storageFailureSubscribers.size === 0) return;
    if (this.storageFailureCount + this.storageFailureSubscribers.size + this.queue.length > MAX_QUEUED) {
      this.contain(new Error(`resource_limit: more than ${MAX_QUEUED} pending storage failures and ingress entries`), "resource_limit");
      return;
    }
    const payload = concat([new Uint8Array([RES_STORAGE_FAILED, fx.session ? 2 : 1, error?.name === "QuotaExceededError" ? 1 : 2]), utf8enc.encode(fx.key)]);
    for (const [id, owner] of this.storageFailureSubscribers) {
      const item = { id, owner, payload, epoch: this.storageFailureEpoch, previous: this.storageFailureTail, next: null };
      if (this.storageFailureTail) this.storageFailureTail.next = item;
      else this.storageFailureHead = item;
      this.storageFailureTail = item;
      owner.pendingFailures.add(item);
      this.storageFailureCount += 1;
    }
    if (this.storageFailureTask === null) this.storageFailureTask = setTimeout(() => {
      this.storageFailureTask = null;
      const epoch = this.storageFailureEpoch;
      this.storageFailureEpoch = {};
      // A write made by a delivered failure belongs to the next task, even
      // when it appends while this callback is draining earlier failures.
      while (this.storageFailureHead?.epoch === epoch && !this.poisoned && !this.ending) {
        const item = this.storageFailureHead;
        this.unlinkStorageFailure(item);
        if (this.live.get(item.id) === item.owner) this.result(item.id, item.payload);
      }
    }, 0);
  }

  // Boot: check the protocol version and declaration sections, then read
  // browser facts through the checked environment seam and stage their
  // sections. A module that speaks another protocol is refused before
  // anything runs: the runtime throws and never applies an unreadable command.
  mount() {
    try {
      const version = typeof this.x.protocol_version === "function" ? this.x.protocol_version() : 0;
      if (version !== PROTOCOL_VERSION) {
        throw new Error(`roc engine protocol ${version} is not the protocol ${PROTOCOL_VERSION} this runtime implements`);
      }
      // The app's port declarations, checked against options.ports before
      // anything mounts: a mismatch throws, and nothing runs.
      const boot = readDeclarations(this.x);
      this.protocol = boot.bindings;
      this.bootKeys = boot.keys;
      this.sessionKeys = boot.sessionKeys;
      this.mediaQueries = boot.media;
      this.zoneDays = boot.zoneDays;
      this.portDecls = new Map(boot.decls.map((d) => [d.name, d]));
      checkPortHandlers(boot.decls, this.ports, this.manual);
      const bytes = this.bootBytes();
      this.monitor.runtimeMounted();
      this.guard(() => this.mountInner(bytes));
      this.drainQueue();
    } catch (error) {
      if (this.pictureManaged && !this.poisoned) this.contain(error, "executor");
      throw error;
    }
  }

  bootBytes() {
    const mountRoot = mountRootBytes(this.root, this.protocol);
    // Read before mount with the port table (see mount()).
    const keys = this.bootKeys;
    // Storage is unavailable when there is none or any read throws; then
    // the app boots with no stored values rather than some of them.
    let storageOk = !!this.storage && typeof this.storage.getItem === "function";
    const pairs = [];
    for (const k of keys) {
      if (!storageOk) break;
      let value;
      try { value = this.storage.getItem(k); }
      catch { storageOk = false; continue; }
      if (value !== null) pairs.push([k, storageText(value)]);
    }
    if (!storageOk) pairs.length = 0;
    let sessionOk = !!this.sessionStorage && typeof this.sessionStorage.getItem === "function";
    const session = [];
    for (const key of this.sessionKeys) {
      if (!sessionOk) break;
      let value;
      try { value = this.sessionStorage.getItem(key); }
      catch { sessionOk = false; continue; }
      if (value !== null) session.push([key, storageText(value)]);
    }
    if (!sessionOk) session.length = 0;
    const loc = this.win ? this.win.location : null;
    const url = loc ? loc.pathname + loc.search + loc.hash : "/";
    // The default zone probe uses this exact mount sample rather than
    // reading a second clock value. Injected zone readers retain their one
    // argument: the span the program declares, in days each side of mount.
    const now = this.readNow();
    const seed = checkedSeed(this.environment.seed ? this.environment.seed() : browserSeed());
    const languages = checkedLanguages(this.environment.languages ? this.environment.languages() : browserLanguages(this.win?.navigator));
    const zone = this.environment.timeZone ? checkedZone(this.environment.timeZone(this.zoneDays)) : probeTimeZone(this.zoneDays, now);
    const sections = [
      { tag: 1, write: () => encStr(url) },
      { tag: 2, write: () => concat([new Uint8Array([storageOk ? 1 : 0]), u32(pairs.length), ...pairs.flatMap(([k, v]) => [encStr(k), encStr(v)])]) },
      { tag: 3, write: () => new Uint8Array([this.isOnline() ? 1 : 0]) },
      { tag: 4, write: () => new Uint8Array([this.isVisible() ? 1 : 0]) },
      { tag: 6, write: () => new Uint8Array(this.mediaQueries.map((query) => this.mediaMatch(this.mediaQuery(query)) ? 1 : 0)) },
      { tag: 7, write: () => i64Bytes(now) },
      { tag: 8, write: () => seed },
      { tag: 9, write: () => concat([u32(languages.length), ...languages.map(encStr)]) },
      { tag: 10, write: () => concat([encStr(zone.name), i64Bytes(zone.from_ms), i64Bytes(zone.until_ms), u32(zone.offsets.length), ...zone.offsets.flatMap(offset => [i64Bytes(offset.from_ms), i32Bytes(offset.minutes)])]) },
      { tag: 11, write: () => concat([new Uint8Array([sessionOk ? 1 : 0]), u32(session.length), ...session.flatMap(([key, value]) => [encStr(key), encStr(value)])]) },
      { tag: 13, write: () => mountRoot },
    ];
    return concat(sections.map(({ tag, write }) => {
      const body = write();
      return concat([new Uint8Array([tag]), u32(body.length), body]);
    }));
  }

  mountInner(bytes) {
    this.controlListeners();
    this.nativeEventListeners();
    this.documentKeyListeners();
    this.listen("click");
    this.listen("submit");
    const x = this.x;
    this.stage(bytes);
    this.busy = true;
    try {
      x.init();
      this.apply();
    } finally {
      this.busy = this.pendingTransition !== null;
    }
  }

  // ---------------------------------------------------------------------
  // Containment (design.md, "Error Containment"). Any trap or executor failure
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
      this.contain(e, e instanceof ContractFault ? "contract" : null);
      return null;
    }
  }

  // `klass` names a fault the runtime itself classifies (an ingress bound
  // or a value property applied to a file input);
  // otherwise the instance's fault class decides, and a trap the instance
  // did not classify is an executor failure.
  contain(error, klass = null) {
    this.cancelTransition();
    if (this.poisoned) return;
    if (this.pictureManaged) failPicture(this.root);
    if (this.picturePending) holdPicture(this.root);
    let code = 0;
    let message = String(error && error.message ? error.message : error);
    if (klass !== null) {
      code = klass === "executor" ? 0 : this.protocol.LOST_CLASSES.indexOf(klass);
    } else {
      try {
        code = this.x.fault();
        if (code !== 0) message = new TextDecoder().decode(new Uint8Array(this.x.memory.buffer, this.x.err_ptr(), this.x.err_len()));
      } catch (_) {
        code = 0;
      }
    }
    this.poisoned = { class: code === 0 ? "executor" : this.protocol.LOST_CLASSES[code] ?? "unknown", code, message, trap: String(error) };
    for (const [type, listeners] of this.listening) {
      this.root.removeEventListener(type, listeners.bubble);
      if (listeners.capture) this.root.removeEventListener(type, listeners.capture, true);
    }
    this.listening.clear();
    this.clearDocumentKeys();
    this.clearObservations();
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
    this.clearIngress();
    this.clearStorageFailures();
    this.live.clear();
    this.pushSubs.clear();
    this.stopWorkers();
    this.files.clear();
    this.revokeUrls();
    this.fxOut = [];
    this.nativeObservationError = null;
    this.nativeTasks.clear();
    if (this.modalOrder) this.modalOrder.clear();
    this.monitor.runtimeEnded("poisoned", this.poisoned);
    console.error(`roc engine fault [${this.poisoned.class}]: ${message}`);
    if (this.onFault) this.onFault(this.poisoned);
  }

  // A fresh instance from the same module; the poisoned one is abandoned.
  async recover() {
    this.cancelTransition();
    this.setLeaveGuard(false);
    this.clearStorageFailures();
    for (const id of [...this.live.keys()]) this.cancel(id);
    if (!this.module) throw new Error("recover() needs the compiled module (mountRocEngineApp keeps it)");
    const instance = await WebAssembly.instantiate(this.module, pageImports(this.module));
    this.x = instance.exports;
    if (this.pictureManaged) {
      this.picturePending = false;
      this.root.removeAttribute(PICTURE_MARKER);
      this.root.removeAttribute(PICTURE_FAILED);
      restorePictureHold(this);
    }
    this.root.textContent = "";
    this.statics = [];
    this.sites = [];
    this.templates = [];
    this.clearIngress();
    this.live = new Map();
    this.files = new Map();
    this.revokeUrls();
    this.issued = [];
    this.reportEpoch = {};
    this.reportsReplaced = 0;
    this.pointerLog = [];
    this.captureRefused = 0;
    this.fxOut = [];
    this.busy = false;
    this.poisoned = null;
    this.ending = null;
    this.pushSubs = new Map();
    this.portLog = [];
    this.saveLog = [];
    this.clipboardText = "";
    this.clipboardHtml = "";
    this.clipboardWrites = 0n;
    this.clipboardObservationError = null;
    this.scrollLog = this.manual ? new ScrollHistory() : null;
    this.transitionLog = this.manual ? new TransitionHistory() : null;
    this.modalOrder = this.manual ? new ModalOrder() : null;
    this.nativeTasks = new Map();
    this.nativeObservationError = null;
    this.manualScrollers = this.manual ? new Map() : null;
    this.pendingManualScrolls.clear();
    this.manualScrollError = null;
    this.mount();
    return this;
  }

  unmount() {
    this.cancelTransition();
    this.setLeaveGuard(false);
    this.clearStorageFailures();
    this.monitor.runtimeEnding("unmount");
    this.ending = "unmounted";
    this.clearIngress();
    for (const id of [...this.live.keys()]) this.cancel(id);
    this.pushSubs.clear();
    this.stopWorkers();
    this.monitor.runtimeEnded("unmounted");
    for (const [type, listeners] of this.listening) {
      this.root.removeEventListener(type, listeners.bubble);
      if (listeners.capture) this.root.removeEventListener(type, listeners.capture, true);
    }
    this.listening.clear();
    this.clearDocumentKeys();
    this.clearObservations();
    for (const [type, fn] of this.internal) this.root.removeEventListener(type, fn, true);
    this.internal = [];
    this.x.drop();
    this.files.clear();
    this.revokeUrls();
    this.root.textContent = "";
    this.statics = [];
    this.sites = [];
    this.templates = [];
    if (this.scrollLog) this.scrollLog.clear();
    if (this.transitionLog) this.transitionLog.clear();
    this.nativeTasks.clear();
    if (this.modalOrder) this.modalOrder.clear();
    this.nativeObservationError = null;
    if (this.manualScrollers) this.manualScrollers.clear();
    this.pendingManualScrolls.clear();
    this.manualScrollError = null;
  }

  // Only the manual driver observes native queued UI callbacks. This does
  // not deliver or schedule a turn: the browser's actual callbacks do that.
  nativeEventListeners() {
    if (!this.manual) return;
    const on = (type, callback) => {
      const listener = event => { if (!this.picturePending) callback(event); };
      this.root.addEventListener(type, listener, true);
      this.internal.push([type, listener]);
    };
    on("beforetoggle", (event) => {
      const element = event.target;
      const property = element.__shownControl ? 6 : element.__popoverControl ? 7 : 0;
      if (!property) return;
      const slot = property === 6 ? "__shownControl" : "__popoverControl";
      const control = element[slot];
      queueMicrotask(() => {
        if (this.poisoned || this.ending || !element.isConnected || !this.root.contains(element) || element[slot] !== control || (event.cancelable && event.defaultPrevented)) return;
        if (property === 6 && !element.matches(":modal")) this.modalOrder.remove(element);
        const pending = this.nativeTasks.get(element) ?? { control, close: 0n, toggle: false };
        if (property === 6 && event.newState === "closed") {
          if (pending.close === U64_MAX) this.nativeObservationError = "native UI callback observation exhausted";
          else pending.close += 1n;
        }
        if (property === 7 || element.__h?.toggle) pending.toggle = true;
        if (pending.close || pending.toggle) this.nativeTasks.set(element, pending);
      });
    });
    const completed = (event) => {
      const pending = this.nativeTasks.get(event.target);
      if (!pending) return;
      if (event.type === "close" && pending.close) pending.close -= 1n;
      if (event.type === "toggle") pending.toggle = false;
      if (!pending.close && !pending.toggle) this.nativeTasks.delete(event.target);
    };
    on("close", completed);
    on("toggle", completed);
  }

  nativeEventsReady() {
    if (this.nativeObservationError) throw new Error(this.nativeObservationError);
    return this.nativeTasks.size === 0;
  }

  // Controlled-input bookkeeping: composition flags, deferred values applied
  // on blur, and input echoes that make a deferred value moot. Runs before
  // (capture) and independently of the app's own handlers.
  controlListeners() {
    const on = (type, fn) => {
      const listener = event => { if (!this.picturePending) fn(event); };
      this.root.addEventListener(type, listener, true);
      this.internal.push([type, listener]);
    };
    on("compositionstart", (e) => {
      e.target.__composing = true;
    });
    on("compositionend", (e) => {
      const t = e.target;
      t.__composing = false;
      if (t.__applyValue) {
        t.__applyValue = false;
        applyRenderedValue(t);
      }
    });
    on("input", (e) => {
      const t = e.target;
      if (t.__deferred !== undefined && t.__deferred === t.value) t.__deferred = undefined;
      if (t.__applyValue && t.value === t.__renderedValue) t.__applyValue = false;
    });
    on("focusout", (e) => {
      const t = e.target;
      t.__composing = false;
      if (t.__applyValue) {
        t.__applyValue = false;
        applyRenderedValue(t);
      } else if (t.__deferred !== undefined) {
        const v = t.__deferred;
        t.__deferred = undefined;
        if (t.value !== v) t.value = v;
      }
    });
  }

  // Two delegated listeners per event type, added the first time a LISTEN
  // command or template hole names that type. The event's own bubbles flag
  // selects exactly one; non-bubbling events only find their target's handler.
  // App "focus"/"blur" handlers listen to the bubbling focusin/focusout.
  listen(type) {
    const dom = DOM_EVENT[type] ?? type;
    if (this.listening.has(dom)) return;
    this.listening.set(dom, { bubble: this.onEvent, capture: this.onCapture });
    this.root.addEventListener(dom, this.onEvent);
    this.root.addEventListener(dom, this.onCapture, true);
    if (dom === "drop") {
      // A drop target that takes files lets the drop happen (see "Handler
      // event names" above); this helper itself dispatches no app event.
      const over = (event) => {
        if (this.picturePending) return;
        for (let node = event.target; node && node !== this.root; node = node.parentNode) {
          const h = node.__h && node.__h.drop;
          if (h !== undefined) {
            if (h.kind === this.protocol.KIND_FILES) event.preventDefault();
            return;
          }
        }
      };
      // This default-action helper is independent of app delegation: a
      // later LISTEN for dragover must still register its own handlers.
      this.internal.push(["dragover", over]);
      this.root.addEventListener("dragover", over, true);
    }
  }

  // Find the target's handler, or for a bubbling event the nearest ancestor
  // handler, then its nearest routing id. Reference ids never route events.
  handle(event) {
    const type = APP_EVENT[event.type] ?? event.type;
    // Forms are app-managed: a submit never navigates (design.md,
    // "Controlled inputs").
    if (event.type === "submit") event.preventDefault();
    let node = event.target;
    let handler = null;
    let declaring = null;
    let heard = null;
    while (node && node !== this.root) {
      if (handler === null && (event.bubbles || node === event.target) && node.__h !== undefined) {
        const h = node.__h[type];
        if (h !== undefined && !(h.policies & this.protocol.POLICY_DOCUMENT)) {
          const match = h.kind === this.protocol.KIND_KEY ? matchKey(type === "keydown" ? node.__keymapDown : node.__keymapUp, event, this.protocol.text_entry_excluded) : null;
          if (h.kind !== this.protocol.KIND_KEY || match) { handler = h; declaring = node; heard = match; }
        }
      }
      if (node.__rn !== undefined && handler !== null) {
        if (heard?.prevent || (handler.policies & this.protocol.POLICY_PREVENT) !== 0 || (handler.kind === this.protocol.KIND_FILES && type === "drop") || handler.kind === this.protocol.KIND_PASTE) this.protocol.POLICIES[this.protocol.POLICY_PREVENT].perform(event);
        // A non-bubbling event is heard during capture; stopping it there
        // would prevent its target's own listeners from running.
        if (event.bubbles && (handler.policies & this.protocol.POLICY_STOP) !== 0) this.protocol.POLICIES[this.protocol.POLICY_STOP].perform(event);
        if ((handler.policies & this.protocol.POLICY_CAPTURE) !== 0) {
          try { declaring.setPointerCapture(event.pointerId); }
          catch (_) {
            this.captureRefused += 1;
            this.monitor.emit({ kind: "pointer-capture-refused", pointer: event.pointerId, at: this.monitor.tick() });
          }
        }
        if (handler.kind === this.protocol.KIND_KEY) {
          this.heardKeys.add(event);
          this.dispatch(node.__rn, handler.h, keyPayload(event, heard), node);
        } else if (handler.kind === this.protocol.KIND_POINTER) {
          const pointer = this.pointerPayload(event);
          if (this.manual) {
            if (this.pointerLog.length >= MAX_QUEUED) {
              this.contain(new Error(`resource_limit: more than ${MAX_QUEUED} pointer dispatches before the replay drained its log`), "resource_limit");
              return;
            }
            this.pointerLog.push({ type, id: event.pointerId, kind: event.pointerType || "other", at: pointer.at, paced: (handler.policies & this.protocol.POLICY_PACED) !== 0 });
          }
          const source = (handler.policies & this.protocol.POLICY_PACED) !== 0 ? this.pointerSource(declaring, handler, event.pointerId) : undefined;
          this.dispatch(node.__rn, handler.h, pointer.bytes, node, source);
        } else if (handler.kind === this.protocol.KIND_PASTE) {
          // getData returns the whole DOMString; the browser exposes no
          // pre-read size check. UTF-8 needs at least one byte per UTF-16
          // code unit, so reject this lower bound before any Unicode scan.
          const text = event.clipboardData?.getData("text/plain") ?? "";
          if (text.length > this.maxPasteBytes) {
            this.dispatch(node.__rn, handler.h, new Uint8Array([1]), node);
            return;
          }
          if (!text.isWellFormed()) throw new Error("paste text is not well-formed Unicode");
          let bytes = 0;
          for (const character of text) {
            const point = character.codePointAt(0);
            bytes += point <= 0x7f ? 1 : point <= 0x7ff ? 2 : point <= 0xffff ? 3 : 4;
            if (bytes > this.maxPasteBytes) break;
          }
          const payload = bytes > this.maxPasteBytes ? new Uint8Array([1]) : concat([new Uint8Array([0]), utf8enc.encode(text)]);
          this.dispatch(node.__rn, handler.h, payload, node);
        } else if (handler.kind === this.protocol.KIND_SCROLL) {
          this.observeManualScroll(declaring);
          const position = this.scrollPosition(declaring);
          this.dispatch(node.__rn, handler.h, concat([u32(position.top), u32(position.left)]), node, this.elementReportSource(declaring, type, handler));
        } else {
          if (type === "scroll") this.observeManualScroll(declaring);
          const payload = this.protocol.PAYLOAD_KINDS[handler.kind].payload(event);
          if (payload !== null) this.dispatch(node.__rn, handler.h, payload, node);
        }
        return;
      }
      node = node.parentNode;
    }
  }

  // Fix each instance's document-listener position at mount, independently
  // of when conditional declarations first appear or which key phase they use.
  documentKeyListeners() {
    for (const type of ["keydown", "keyup"]) {
      this.documentKeys.set(type, []);
      const listener = (event) => this.guard(() => {
        if (this.picturePending || this.heardKeys.has(event)) return;
        const live = this.documentKeys.get(type);
        for (let i = live.length - 1; i >= 0; i -= 1) {
          const { el: declaring, handler: h } = live[i];
          const heard = matchKey(type === "keydown" ? declaring.__keymapDown : declaring.__keymapUp, event, this.protocol.text_entry_excluded);
          if (!heard) continue;
          if (heard.prevent) event.preventDefault();
          if (h.policies & this.protocol.POLICY_STOP) this.protocol.POLICIES[this.protocol.POLICY_STOP].perform(event);
          this.heardKeys.add(event);
          this.dispatch(declaring.__rn, h.h, keyPayload(event, heard), declaring);
          return;
        }
      });
      this.documentListeners.set(type, listener);
      this.doc.addEventListener(type, listener);
    }
  }

  registerDocumentKey(el, type, handler) {
    this.documentKeys.get(type).push({ el, handler });
  }

  releaseNode(el) {
    this.releaseObservations(el);
    for (const [type, entries] of this.documentKeys) {
      this.documentKeys.set(type, entries.filter((entry) => entry.el !== el));
    }
  }

  clearDocumentKeys() {
    for (const [type, listener] of this.documentListeners) this.doc.removeEventListener(type, listener);
    this.documentListeners.clear();
    this.documentKeys.clear();
    this.heardKeys = new WeakSet();
  }

  // Observation routes use the owning element's id. A template descendant
  // is owned by its row root even when it also has a reference address.
  registerLayout(element, type, handler, owner) {
    if (this.manualScrollers && type === "scroll") {
      this.manualScrollers.set(element, { expected: this.scrollPosition(element), allowed: false });
    }
    if (handler.kind !== this.protocol.KIND_SIZE && handler.kind !== this.protocol.KIND_SEEN) return;
    let kinds = this.observations.get(element);
    if (!kinds) this.observations.set(element, kinds = new Map());
    if (kinds.has(handler.kind)) throw new Error("duplicate layout observation");
    const registration = { element, owner, type, handler, observer: null };
    kinds.set(handler.kind, registration);
    let owned = this.observationOwners.get(owner);
    if (!owned) this.observationOwners.set(owner, owned = new Set());
    owned.add(registration);
    if (this.manual) return;
    const key = handler.kind === this.protocol.KIND_SIZE ? "size" : handler.policies & this.protocol.POLICY_AHEAD ? "ahead" : "seen";
    let observer = this.layoutObservers.get(key);
    if (!observer) {
      const callback = (entries) => this.guard(() => {
        for (const entry of entries) {
          const current = this.observations.get(entry.target)?.get(handler.kind);
          if (!current || current.observer !== observer || !entry.target.isConnected) continue;
          const value = handler.kind === this.protocol.KIND_SIZE
            ? { width: this.layoutPixel(entry.contentRect.width), height: this.layoutPixel(entry.contentRect.height) }
            : { intersecting: entry.isIntersecting, ratio_permille: Math.max(0, Math.min(1000, Math.round(entry.intersectionRatio * 1000))) };
          this.deliverObservation(current, value);
        }
        // ResizeObserver runs after the frame's normal report drain. Its
        // completed callback must settle this frame's sizes before paint.
        if (handler.kind === this.protocol.KIND_SIZE) this.drainQueue(true);
      });
      observer = key === "size"
        ? new this.win.ResizeObserver(callback)
        : new this.win.IntersectionObserver(callback, key === "ahead" ? { rootMargin: "100%", scrollMargin: "100%" } : {});
      this.layoutObservers.set(key, observer);
    }
    registration.observer = observer;
    observer.observe(element);
  }

  releaseObservations(owner) {
    const owned = this.observationOwners.get(owner);
    if (!owned) return;
    for (const registration of owned) {
      const { element, handler, observer } = registration;
      if (observer) observer.unobserve(element);
      const kinds = this.observations.get(element);
      kinds.delete(handler.kind);
      if (kinds.size === 0) this.observations.delete(element);
      const source = element.__layoutReports?.get(handler.kind);
      if (source) { this.dropReports(source, source); source.retire(); }
    }
    this.observationOwners.delete(owner);
  }

  clearObservations() {
    for (const observer of this.layoutObservers.values()) observer.disconnect();
    this.layoutObservers.clear();
    this.observations.clear();
    this.observationOwners.clear();
    if (this.manualScrollers) this.manualScrollers.clear();
    this.pendingManualScrolls.clear();
    this.manualScrollError = null;
  }

  // Reports capture values at arrival. The element owns the source while
  // its declaration lives, and RELEASE cancels its queued observations.
  elementReportSource(element, type, handler) {
    const sources = element.__layoutReports ??= new Map();
    let source = sources.get(handler.kind);
    if (!source || !source.isLive()) {
      source = { dom: true, dispatching: 0, reports: new Set(),
        isLive: () => element.isConnected && element.__h?.[type] === handler &&
          (handler.kind !== this.protocol.KIND_SIZE && handler.kind !== this.protocol.KIND_SEEN || this.observations.get(element)?.get(handler.kind)?.handler === handler),
        retire: () => { if (source.dispatching === 0 && source.reports.size === 0 && sources.get(handler.kind) === source) sources.delete(handler.kind); } };
      sources.set(handler.kind, source);
    }
    return source;
  }

  deliverObservation(registration, value) {
    const { element, owner, type, handler } = registration;
    const bytes = handler.kind === this.protocol.KIND_SIZE ? concat([u32(value.width), u32(value.height)]) : new Uint8Array(3);
    if (handler.kind === this.protocol.KIND_SEEN) {
      if (typeof value.intersecting !== "boolean" || !Number.isInteger(value.ratio_permille) || value.ratio_permille < 0 || value.ratio_permille > 1000) throw new Error("invalid seen observation");
      bytes[0] = value.intersecting ? 1 : 0;
      new DataView(bytes.buffer).setUint16(1, value.ratio_permille, true);
    }
    this.dispatch(owner.__rn, handler.h, bytes, owner, this.elementReportSource(element, type, handler));
  }

  // Manual specs inject the same facts a real observer reports. They never
  // measure Chrome's layout to invent an answer the native oracle lacks.
  injectLayout(element, kind, value) {
    if (!this.manual) throw new Error("layout injection requires manualEffects");
    const registration = this.observations.get(element)?.get(kind);
    if (!registration) throw new Error(`element has no ${kind === this.protocol.KIND_SIZE ? "size" : "seen"} observation`);
    if (kind === this.protocol.KIND_SIZE) {
      const size = { width: value.width, height: value.height };
      for (const dimension of Object.values(size)) if (!Number.isInteger(dimension) || dimension < 0 || dimension > 0xffffffff) throw new Error("invalid size observation");
      this.deliverObservation(registration, size);
    } else this.deliverObservation(registration, { intersecting: value.intersecting, ratio_permille: value.ratio_permille });
  }

  layoutPixel(value) {
    if (!Number.isFinite(value)) throw new Error("layout dimension is not finite");
    return Math.max(0, Math.min(0xffffffff, Math.round(value)));
  }

  scrollCoordinates(element) {
    const direction = this.win.getComputedStyle(element).direction;
    const top = element.scrollTop, left = direction === "rtl" ? -element.scrollLeft : element.scrollLeft;
    if (!Number.isFinite(top) || !Number.isFinite(left)) throw new Error("scroll position is not finite");
    return { top, left };
  }

  scrollPosition(element) {
    const coordinates = this.scrollCoordinates(element);
    return { top: this.layoutPixel(coordinates.top), left: this.layoutPixel(coordinates.left) };
  }

  // The replay observes only scrollers a step or command touched. Any real
  // unannounced scroll records a step failure rather than changing input.
  observeManualScroll(element) {
    const observed = this.manualScrollers?.get(element);
    if (!observed) return;
    const position = this.scrollCoordinates(element);
    if (!observed.allowed && (position.top !== observed.expected.top || position.left !== observed.expected.left)) {
      this.manualScrollError ??= `scrolling ${element.getAttribute("aria-label") || element.tagName} moved without a scroll step or modelled ScrollTo; scroll first`;
    }
    this.pendingManualScrolls.add(element);
  }

  expectManualScroll(element, position) {
    const expected = { top: position.top, left: position.left };
    for (const distance of Object.values(expected)) if (!Number.isInteger(distance) || distance < 0 || distance > 0xffffffff) throw new Error("scroll position must be unsigned U32 CSS pixels");
    const observed = this.manualScrollers?.get(element);
    if (!observed) throw new Error("element has no scroll handler");
    observed.expected = expected;
    observed.allowed = true;
    this.pendingManualScrolls.add(element);
  }

  checkManualScrolls() {
    if (this.manualScrollError) throw new Error(this.manualScrollError);
    for (const element of this.pendingManualScrolls) {
      const observed = this.manualScrollers?.get(element);
      if (!observed) continue;
      const actual = this.scrollCoordinates(element);
      if (actual.top !== observed.expected.top || actual.left !== observed.expected.left) throw new Error(`scrolling ${element.getAttribute("aria-label") || element.tagName} did not retain requested position ${observed.expected.top}, ${observed.expected.left}; got ${actual.top}, ${actual.left}`);
      observed.allowed = false;
    }
    this.pendingManualScrolls.clear();
  }

  // A hit test ignores capture, and returns only the nearest nonempty zone
  // inside this mount. Fractions are sampled before a report can wait.
  pointerPayload(event) {
    if (!Number.isInteger(event.pointerId) || event.pointerId < 0 || event.pointerId > 0xffffffff ||
        !Number.isInteger(event.button) || event.button < -1 || event.button > 254 ||
        !Number.isInteger(event.buttons) || event.buttons < 0 || event.buttons > 0xffff) throw new Error("pointer fields do not fit their wire record");
    let at = null;
    if (event.type !== "pointercancel") {
      if (!Number.isFinite(event.clientX) || !Number.isFinite(event.clientY)) throw new Error("pointer coordinates are not finite");
      let hit = this.doc.elementFromPoint(event.clientX, event.clientY);
      if (hit && this.root.contains(hit)) {
        while (hit && hit !== this.root) {
          if (hit.__pointerZone) {
            const box = hit.getBoundingClientRect();
            if (![box.x, box.y, box.width, box.height].every(Number.isFinite)) throw new Error("pointer zone box is not finite");
            if (box.width > 0 && box.height > 0) {
              const fraction = (point, start, size) => Math.max(0, Math.min(10000, Math.round((point - start) * 10000 / size)));
              at = { zone: hit.__pointerZone, x: fraction(event.clientX, box.x, box.width), y: fraction(event.clientY, box.y, box.height) };
            }
            break;
          }
          hit = hit.parentElement;
        }
      }
    }
    const header = new Uint8Array(at === null ? 11 : 15);
    const view = new DataView(header.buffer);
    view.setUint32(0, event.pointerId, true);
    header[4] = ({ mouse: 0, pen: 1, touch: 2 })[event.pointerType] ?? 3;
    header[5] = event.button + 1;
    view.setUint16(6, event.buttons, true);
    header[8] = (event.shiftKey ? 1 : 0) | (event.ctrlKey ? 2 : 0) | (event.altKey ? 4 : 0) | (event.metaKey ? 8 : 0);
    header[9] = event.isPrimary ? 1 : 0;
    header[10] = at === null ? 0 : 1;
    if (at !== null) { view.setUint16(11, at.x, true); view.setUint16(13, at.y, true); }
    return { at, bytes: at === null ? header : concat([header, encStr(at.zone)]) };
  }

  // The element owns this cache only while a pointer has queued entries.
  // Identity never depends on a recyclable engine node id.
  pointerSource(element, handler, pointer) {
    const sources = element.__pointerReports ??= new Map();
    const key = `${handler.h}:${pointer}`;
    let source = sources.get(key);
    if (source === undefined || !source.isLive()) {
      source = { dom: true, dispatching: 0, reports: new Set(), isLive: () => element.isConnected && element.__h?.pointermove === handler,
        retire: () => { if (source.dispatching === 0 && source.reports.size === 0 && sources.get(key) === source) sources.delete(key); } };
      sources.set(key, source);
    }
    return source;
  }

  // Manual replay verifies and drains each input step; production retains no log.
  takePointerLog() {
    const log = this.pointerLog;
    this.pointerLog = [];
    return log;
  }

  // An occurrence pins every earlier report in O(1) by advancing the epoch.
  // Reports replace only their own source's entry from the current epoch.
  // The linked queue makes appending and draining constant work per entry.
  dispatch(node, handler, payload, el, source) {
    if (this.picturePending) {
      if (source?.dom) source.retire();
      return;
    }
    if (this.poisoned || this.ending) {
      this.refused += 1;
      if (source?.dom) source.retire();
      return;
    }
    const report = source !== undefined;
    const owner = report ? source.dom ? source : this.live.get(source) : null;
    if (owner?.dom) owner.dispatching += 1;
    try {
      if (report) {
        if (owner === undefined || (owner.dom && !owner.isLive())) return;
        const waiting = this.reportSources.get(source);
        if (waiting !== undefined && waiting.epoch === this.reportEpoch) {
          waiting.payload = payload;
          this.reportsReplaced += 1;
          this.guard(() => this.scheduleReports());
          return true;
        }
      }
      if (!report) this.reportEpoch = {};
      // Keep an idle occurrence synchronous, including its user activation.
      if (!report && !this.busy && this.queue.length === 0) {
        this.busy = true;
        try {
          this.guard(() => this.deliver(node, handler, payload));
        } finally {
          this.busy = this.pendingTransition !== null;
        }
        this.drainQueue();
        return false;
      }
      if (this.storageFailureCount > 0 && this.queue.length + this.storageFailureCount >= MAX_QUEUED) {
        this.contain(new Error(`resource_limit: more than ${MAX_QUEUED} pending storage failures and ingress entries`), "resource_limit");
        return;
      }
      let active = null, waiting = null;
      if (this.queue.length >= MAX_QUEUED && this.pendingTransition?.phase === "waiting") {
        // Reserve the oldest entry as the active delivery, as on an idle
        // full queue. Admit this input before any older turn can raise a
        // newer report; the linked queue stays within MAX_QUEUED.
        waiting = this.pendingTransition;
        active = this.takeIngress();
      }
      if (this.queue.length >= MAX_QUEUED) {
        if (this.busy) {
          this.contain(new Error(`resource_limit: more than ${MAX_QUEUED} events queued behind one batch (an event feedback loop)`), "resource_limit");
          return;
        }
        // Reports and occurrences both take their FIFO place before an
        // older delivery can synchronously emit another report.
        active = this.takeIngress();
      }
      const entry = { node, handler, payload, el, source, owner, epoch: this.reportEpoch, next: null };
      if (this.queue.tail === null) this.queue.head = entry;
      else this.queue.tail.next = entry;
      this.queue.tail = entry;
      this.queue.length += 1;
      if (report) {
        this.reportSources.set(source, entry);
        if (!owner.reports) owner.reports = new Set();
        owner.reports.add(entry);
        this.guard(() => this.scheduleReports());
      }
      if (waiting !== null) waiting.update("queue", false);
      if (this.poisoned || this.ending) {
        if (active !== null) active.payload = null;
        return false;
      }
      if (active !== null) {
        const first = this.takePayload(active);
        if (first !== null) {
          this.busy = true;
          try {
            this.guard(() => this.deliver(active.node, active.handler, first));
          } finally {
            this.busy = this.pendingTransition !== null;
          }
        }
      }
      if (active !== null && report) {
        // Capacity pressure flushes older inputs, not this newly admitted
        // report. Keep its FIFO position and ordinary epoch pacing intact.
        this.drainQueue(true, entry);
        this.drainQueue();
      } else if (!report) this.drainQueue();
      return false;
    } finally {
      if (owner?.dom) { owner.dispatching -= 1; owner.retire(); }
    }
  }

  // Taking the head retires just that entry's index and ownership links.
  takeIngress() {
    const entry = this.queue.head;
    this.queue.head = entry.next;
    this.queue.length -= 1;
    if (this.queue.length === 0) this.queue.tail = null;
    if (entry.source !== undefined) {
      if (this.reportSources.get(entry.source) === entry) this.reportSources.delete(entry.source);
      entry.owner.reports.delete(entry);
      if (entry.owner.retire) entry.owner.retire();
    }
    return entry;
  }

  // A disposed source or recycled DOM id never receives its queued input.
  // Clear the payload even on a dropped entry so no browser files linger.
  takePayload(entry) {
    const { node, payload, el } = entry;
    entry.payload = null;
    if (payload === null || (entry.owner && (entry.owner.dom ? !entry.owner.isLive() : this.live.get(entry.source) !== entry.owner))) return null;
    if (el !== undefined && (!el.isConnected || el.__rn !== node)) return null;
    if (payload.isLive && !payload.isLive()) return null;
    return payload;
  }

  // A report's payload was captured at arrival, never read again here.
  // Current-epoch reports wait; an occurrence has pinned older epochs.
  drainQueue(reports = false, before = null) {
    if (this.busy) {
      // A real frame remains due across a batch. Capacity pressure's
      // bounded older-entry flush is not a frame and persists no release.
      if (reports && before === null) this.reportDue = true;
      return;
    }
    reports ||= this.reportDue;
    this.reportDue = false;
    if (reports) this.cancelReportDrain();
    let turns = 0;
    while (!this.busy && !this.poisoned && this.queue.length > 0) {
      const entry = this.queue.head;
      if (entry === before) break;
      if (entry.source !== undefined && entry.epoch === this.reportEpoch && !reports && entry.payload !== null) break;
      this.takeIngress();
      const payload = this.takePayload(entry);
      if (payload === null) continue;
      if (turns >= MAX_QUEUED) {
        this.contain(new Error(`resource_limit: more than ${MAX_QUEUED} turns delivered without returning to idle (an event feedback loop)`), "resource_limit");
        return;
      }
      turns += 1;
      this.busy = true;
      try {
        this.guard(() => this.deliver(entry.node, entry.handler, payload));
      } finally {
        this.busy = this.pendingTransition !== null;
      }
    }
    if (this.queue.length === 0) this.cancelReportDrain();
    else if (!this.poisoned) this.guard(() => this.scheduleReports());
  }

  // Manual replay supplies the frame; manualWork/manualIntervals do not.
  releaseReports() {
    this.drainQueue(true);
  }

  // One drain for all report sources, paced by a frame or its liveness
  // timer. Hidden pages use a microtask because their frames may stop.
  scheduleReports() {
    if (this.manual || this.poisoned || this.ending) return;
    const hidden = !this.isVisible();
    if (this.reportDrain !== null) {
      if (!hidden || this.reportDrain.hidden) return;
      this.cancelReportDrain();
    }
    const drain = { hidden, frame: null, timer: null };
    this.reportDrain = drain;
    const run = () => {
      if (this.reportDrain !== drain) return;
      this.cancelReportDrain();
      this.drainQueue(true);
    };
    if (hidden) queueMicrotask(run);
    else {
      if (typeof this.win?.requestAnimationFrame === "function") drain.frame = this.win.requestAnimationFrame(run);
      drain.timer = setTimeout(run, FRAME_WAIT_MS);
    }
  }

  cancelReportDrain() {
    const drain = this.reportDrain;
    if (drain === null) return;
    this.reportDrain = null;
    if (drain.frame !== null) this.win.cancelAnimationFrame(drain.frame);
    if (drain.timer !== null) clearTimeout(drain.timer);
  }

  // A source owns its queued entries, including pinned earlier reports.
  // CANCEL visits only that source, releases payloads immediately and lets
  // the ordinary drain skip the dead queue cells without scanning others.
  dropReports(id, owner) {
    this.reportSources.delete(id);
    if (owner.reports) {
      for (const entry of owner.reports) entry.payload = null;
      owner.reports.clear();
    }
  }

  clearIngress() {
    this.cancelReportDrain();
    for (const entry of this.reportSources.values()) {
      entry.owner.reports.clear();
      if (entry.owner.retire) entry.owner.retire();
    }
    this.queue = { head: null, tail: null, length: 0 };
    this.reportSources.clear();
    this.reportDue = false;
    this.pointerLog = [];
    for (const owner of this.live.values()) if (owner.reports) owner.reports.clear();
  }

  // One engine call for an event: a files-kind event stages its handles and
  // file record (design.md, Appendix B); other events stage their bytes or text.
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
    if (payload.before) payload.before();
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

  // Removing an ancestor also disposes the rows and command-only aliases
  // beneath it. Walk only that subtree; the engine need not emit a REMOVE
  // for each descendant when one ancestor removal already removes its DOM.
  forgetSubtree(el) {
    const pending = [el];
    while (pending.length > 0) {
      const node = pending.pop();
      this.nativeTasks.delete(node);
      if (this.manualScrollers) this.manualScrollers.delete(node);
      this.pendingManualScrolls.delete(node);
      if (this.modalOrder) this.modalOrder.remove(node);
      node.__shownControl = undefined;
      node.__popoverControl = undefined;
      for (let child = node.firstChild; child; child = child.nextSibling) pending.push(child);
      if (node.__childTarget && node.__childTarget !== node) pending.push(node.__childTarget);
      if (node.__site !== undefined) {
        this.sites[node.__site].delete(node.__rn);
        for (const id of node.__aliases) this.statics[id] = undefined;
      }
      if (node.__rn !== undefined) this.statics[node.__rn] = undefined;
      if (node.__id !== undefined) this.statics[node.__id] = undefined;
    }
  }

  place(el, parent, before) {
    if (before === 0) {
      const owner = this.lookup(parent);
      (parent === 0 ? owner : owner.__childTarget ?? owner).appendChild(el);
    }
    else {
      const b = this.lookup(before);
      b.parentNode.insertBefore(el, b);
    }
  }

  parseTemplate(u8, dv, start, len, dry = false) {
    let at = start;
    const doc = this.doc;
    const str = () => {
      const n = dv.getUint32(at, true);
      at += 4;
      const s = readStr(u8, at, n);
      at += n;
      return s;
    };
    const reader = { u8, dv, at, doc, protocol: this.protocol, path: [], contentOwners: [], dry };
    const root = templateNode(reader);
    at = reader.at;
    const holes = [];
    const count = u8[at++];
    for (let i = 0; i < count; i += 1) {
      const kind = u8[at++];
      const depth = u8[at++];
      const path = Array.from(u8.subarray(at, at + depth * 2));
      at += depth * 2;
      if (dry) walkShape(root, path, this.protocol); else walk(root, path, this.protocol);
      const hole = { kind, path, name: null, handler: 0, prop: 0, entry: null };
      if (kind === HOLE_ATTR) { reader.at = at; hole.name = expandedName(reader, false); at = reader.at; }
      else if (kind === HOLE_CLICK) {
        hole.handler = u8[at++];
        hole.name = str();
        const payloadKind = u8[at++];
        const policies = dv.getUint32(at, true);
        at += 4;
        hole.entry = handlerEntry(hole.handler, payloadKind, policies, hole.name, this.protocol);
        if (!dry && payloadKind !== this.protocol.KIND_SIZE && payloadKind !== this.protocol.KIND_SEEN) this.listen(hole.name);
      } else if (kind === HOLE_PROP) {
        hole.prop = u8[at++];
        if (!this.protocol.PROPS[hole.prop]) throw new Error(`unknown element property ${hole.prop}`);
      } else if (kind !== HOLE_TEXT && kind !== HOLE_BIND && kind !== HOLE_REF) throw new Error(`unknown template hole kind ${kind}`);
      holes.push(hole);
    }
    if (at !== start + len) throw new Error("template length mismatch");
    return { root, holes, contentOwners: reader.contentOwners };
  }

  // One shared promise covers both a deferred update and its animation. Manual
  // replay waits for this before allowing another pointer event.
  idle() { return this.transitionIdle; }

  transitionEvent(state, detail = {}) {
    this.monitor.emit({ kind: "transition", state, at: this.monitor.tick(), ...detail });
  }

  skipTransition(pending) {
    pending.skipRequested = true;
    if (!pending.transition || pending.skipped) return;
    pending.skipped = true;
    try { pending.transition.skipTransition(); } catch { /* animation only */ }
  }

  cancelTransition() {
    this.transitionEpoch = {};
    const idle = this.transitionIdleState;
    this.transitionIdleState = null;
    idle?.resolve();
    if (idle?.token) this.skipTransition(idle.token);
    const pending = this.pendingTransition;
    if (!pending) return;
    this.pendingTransition = null;
    clearTimeout(pending.timer);
    pending.cancelled = true;
    pending.batch.definitions.clear(); pending.batch.spans.clear(); pending.batch.types = null;
    this.skipTransition(pending);
    pending.resolve();
  }

  flushEffects() {
    const out = this.fxOut;
    this.fxOut = [];
    for (const fx of out) {
      if (this.poisoned || this.ending) break;
      this.perform(fx);
    }
  }

  apply() {
    const len = this.x.cmd_len();
    if (!len) {
      if (this.picturePending) this.root.replaceChildren();
      finishPicture(this); this.releaseFiles(); return 0;
    }
    const flags = new Uint8Array(this.x.memory.buffer, this.x.cmd_ptr(), len)[0];
    if (flags !== 0 && flags !== 1) throw new Error(`invalid command batch flags ${flags}`);
    if (this.picturePending) {
      if (flags !== 0) throw new Error("picture mount batch must be unmarked");
      const batch = { definitions: new Map() };
      try {
        // The shared wire reader builds only temporary template shapes. DOM
        // factories and effect registration run once, after framing succeeds.
        this.applyBatch("preflight", batch);
        this.root.replaceChildren();
        this.applyBatch("normal", batch);
        finishPicture(this);
        this.flushEffects();
        if (!this.poisoned && !this.ending) this.releaseFiles();
        return len;
      } finally {
        batch.definitions.clear();
      }
    }
    const animate = flags === 1 && this.viewTransitions === "document" && this.doc.visibilityState !== "hidden" && typeof this.doc.startViewTransition === "function";
    if (!animate) {
      const batch = { types: null };
      this.applyBatch("normal", batch);
      finishPicture(this);
      this.flushEffects();
      if (this.poisoned || this.ending) return len;
      this.releaseFiles();
      if (flags) { this.transitionLog?.add(batch.types, "none"); this.transitionEvent("applied", { cause: "none", typeCount: batch.types.length }); }
      return len;
    }
    const batch = { definitions: new Map(), spans: new Map(), types: null };
    this.applyBatch("early", batch);
    // No effect runs until the complete marked batch has passed framing checks.
    this.flushEffects();
    if (this.poisoned || this.ending) return len;
    // All callers share one outstanding idle promise. A document transition
    // supersedes the preceding animation, so only the newest token completes
    // it; stale browser promise handlers cannot affect a later generation.
    let state = this.transitionIdleState;
    if (state === null) {
      let finish;
      const promise = new Promise(resolve => { finish = resolve; });
      state = { resolve: finish, token: null };
      this.transitionIdleState = state;
      this.transitionIdle = promise;
    }
    const epoch = this.transitionEpoch;
    const isCurrent = () => this.transitionEpoch === epoch && !this.poisoned && !this.ending;
    let pending;
    const resolve = () => {
      if (this.transitionIdleState !== state || state.token !== pending) return;
      this.transitionIdleState = null;
      state.resolve();
    };
    pending = { batch, resolve, timer: null, transition: null, applied: false, cancelled: false, finished: false, phase: "waiting" };
    state.token = pending;
    this.pendingTransition = pending;
    this.busy = true;
    const update = (cause = "callback", drain = true) => {
      if (!isCurrent() || pending.cancelled || pending.applied || this.pendingTransition !== pending) return;
      pending.applied = true;
      pending.phase = "applying";
      clearTimeout(pending.timer);
      this.guard(() => {
        this.applyBatch("update", batch);
        this.flushEffects();
        if (this.poisoned || this.ending) return;
        this.releaseFiles();
        this.transitionLog?.add(batch.types, cause);
        this.transitionEvent("applied", { cause, typeCount: batch.types.length });
      });
      // Browser animation promises retain only their small lifecycle token,
      // never completed requests' files or parsed template trees.
      batch.definitions.clear(); batch.spans.clear(); batch.types = null;
      if (this.pendingTransition === pending) this.pendingTransition = null;
      this.busy = false;
      if (cause !== "callback" || this.manual || this.poisoned) {
        this.skipTransition(pending);
      }
      if (drain) this.drainQueue();
      if (pending.finished) resolve();
    };
    pending.update = update;
    pending.timer = setTimeout(() => update("timer"), TRANSITION_WAIT_MS);
    try {
      try { pending.transition = this.doc.startViewTransition({ update: () => update(), types: batch.types }); }
      catch (error) {
        // Older implementations support only the callback overload.
        if (pending.applied) throw error;
        pending.transition = this.doc.startViewTransition(() => update());
      }
      const transition = pending.transition;
      if (pending.skipRequested || pending.applied && (this.manual || this.poisoned)) this.skipTransition(pending);
      const rejected = (state, error) => { if (isCurrent()) this.transitionEvent(state, { message: String(error?.message ?? error).slice(0, 1024) }); };
      Promise.resolve(transition?.ready).catch(error => rejected("ready-rejected", error));
      const finished = () => { if (!isCurrent()) return; pending.finished = true; if (pending.applied || pending.cancelled) resolve(); };
      Promise.resolve(transition?.finished).then(finished, error => { rejected("finished-rejected", error); finished(); });
    } catch (error) {
      if (isCurrent()) this.transitionEvent("start-rejected", { message: String(error?.message ?? error).slice(0, 1024) });
      update("none");
      resolve();
    }
    return len;
  }

  applyBatch(mode = "normal", batch = {}) {
    const x = this.x;
    const len = x.cmd_len();
    if (len === 0) return 0;
    const buffer = x.memory.buffer;
    const ptr = x.cmd_ptr();
    const u8 = new Uint8Array(buffer, ptr, len);
    const dv = new DataView(buffer, ptr, len);
    const doc = this.doc;
    let at = 1;
    const flags = u8[0];
    if (flags !== 0 && flags !== 1) throw new Error(`invalid command batch flags ${flags}`);
    let marked = false;
    const scanning = mode === "early" || mode === "preflight";
    const shadow = scanning ? new Map() : null;
    const skipString = () => { const n = dv.getUint32(at, true); if (mode === "preflight") readStr(u8, at + 4, n); at += 4 + n; };
    const skipAttribute = () => { const present = u8[at++]; if (present === 1) skipString(); else if (present !== 0) throw new Error(`invalid attribute presence ${present}`); };
    // One reader per batch; no implementation retains it or its memory views.
    const reader = { u8, dv, doc, protocol: this.protocol, mode, batch, len, flags, at: 1, op: 0, offset: 0, marked: false };
    while (at < len) {
      const offset = at;
      const op = u8[at];
      at += 1;
      if (op === this.protocol.OP_TRANSITION) {
        reader.at = at; reader.marked = marked;
        at = this.protocol.COMMANDS[op].call(this, reader);
        marked = reader.marked;
        break;
      }
      if (mode === "update" && batch.spans.has(offset)) {
        at = batch.spans.get(offset); continue;
      }
      if (scanning) {
        let skipped = true;
        switch (op) {
          case this.protocol.OP_TEMPLATE: {
            const site = dv.getUint32(at, true), n = dv.getUint32(at + 4, true);
            const template = this.parseTemplate(u8, dv, at + 8, n, mode === "preflight");
            shadow.set(site, template); batch.definitions.set(offset, template); at += 8 + n; break;
          }
          case this.protocol.OP_INST: {
            const site = dv.getUint32(at + 12, true), template = shadow.get(site) ?? this.templates[site];
            if (!template) throw new Error(`INST names unknown template ${site}`);
            at += 16;
            for (const hole of template.holes) {
              if (hole.kind === HOLE_TEXT || hole.kind === HOLE_PROP) skipString();
              else if (hole.kind === HOLE_ATTR) skipAttribute();
              else if (hole.kind === HOLE_BIND || hole.kind === HOLE_REF) at += 4;
            }
            break;
          }
          case this.protocol.OP_HATTR: at += 5; skipAttribute(); break;
          case this.protocol.OP_TEXT: case this.protocol.OP_HPROP: case this.protocol.OP_PROP:
            if (mode === "preflight" && op === this.protocol.OP_PROP && !this.protocol.PROPS[u8[at + 4]]) throw new Error(`unknown element property ${u8[at + 4]}`);
            at += 5; skipString(); break;
          case this.protocol.OP_MOVE: case this.protocol.OP_CLEAR: at += 8; break;
          case this.protocol.OP_RELEASE: case this.protocol.OP_REMOVE: at += 4; break;
          case this.protocol.OP_ELEM: {
            reader.at = at + 12;
            const name = expandedName(reader, true);
            const container = reader.protocol.CONTAINERS[u8[reader.at++]];
            if (!container) throw new Error("unknown child container");
            if (container === CONTAINER_APPLIERS.TEMPLATE_CONTENT && (name.namespace !== HTML_NS || name.local !== "template")) throw new Error("template content requires an HTML template");
            at = reader.at;
            break;
          }
          case this.protocol.OP_TEXTNODE: case this.protocol.OP_COMMENT: at += 12; skipString(); break;
          case this.protocol.OP_ATTR: at += 4; reader.at = at; expandedName(reader, false); at = reader.at; skipAttribute(); break;
          case this.protocol.OP_LISTEN: {
            const n = dv.getUint32(at + 8, true);
            if (mode === "preflight") handlerEntry(dv.getUint32(at + 4, true), u8[at + 12 + n], dv.getUint32(at + 13 + n, true), readStr(u8, at + 12, n), this.protocol);
            at += 17 + n; break;
          }
          case this.protocol.OP_SETTEXT: at += 4; skipString(); break;
          case this.protocol.OP_REF: {
            const kind = u8[at]; at += 5;
            if (kind < 1 || kind > 7) throw new Error(`unknown reference operation ${kind}`);
            if (kind === 6) { if (u8[at] > 3 || u8[at + 1] > 3 || u8[at + 2] > 2) throw new Error("invalid scroll-into-view operands"); at += 3; }
            if (kind === 7) { for (let i = 0; i < 2; i += 1) { const edge = u8[at++]; if (edge > 3) throw new Error("invalid scroll edge"); if (edge === 3) at += 4; } if (u8[at++] > 2) throw new Error("invalid scroll behavior"); }
            break;
          }
          default: skipped = false;
        }
        if (at > len) throw new Error("command exceeds batch length");
        if (skipped) continue;
      }
      reader.at = at; reader.op = op; reader.offset = offset;
      const apply = this.protocol.COMMANDS[op];
      if (!apply) throw new Error(`unknown engine command ${op} at byte ${at - 1}`);
      at = apply.call(this, reader);
      if (at > len) throw new Error("command exceeds batch length");
      if (mode === "early") batch.spans.set(offset, at);
    }
    if (at !== len || (flags === 1) !== marked) throw new Error("command batch flag/TRANSITION mismatch");
    return len;
  }

  // ---------------------------------------------------------------------
  // Effects.

  result(id, bytes) {
    this.dispatch(FX_NODE, id, bytes);
  }

  report(id, payload) {
    return this.dispatch(FX_NODE, id, payload, undefined, id);
  }

  // A request's file, `token:u64 start:u64 len:u64` at `at`, resolved while
  // the batch's released handles still name their files (see "Files"): the
  // browser's `File`, the range, and the range as a Blob of the file's type.
  // The request holds them, so the file outlives its handle until the
  // request is answered.
  // Preflight checks the range's framing without resolving a browser file.
  fileRef(dv, at, dry = false) {
    const { token, start, len } = fileRange(dv, at);
    if (dry) return {};
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

  // A later decision invalidates a deferred show, including a hide already
  // applied in stream order. Object tokens have no generation that can wrap.
  decideShown(element, property, value, node) {
    const control = property === 6 ? "__shownControl" : "__popoverControl";
    if (!element[control]) element[control] = {};
    const intent = {};
    element[property === 6 ? "__shownIntent" : "__popoverIntent"] = intent;
    if ((property === 6 && value === "hidden") || (property === 7 && value === "false")) this.applyShown(element, property, value, node);
    else this.fxOut.push({ op: "shown", element, property, value, node, intent });
  }

  applyShown(element, property, value, node) {
    try {
      if (property === 6) {
        const modal = element.matches(":modal");
        if (value === "hidden") { if (element.open) element.close(); }
        else if (value === "modal") {
          if (!modal) { if (element.open) element.close(); element.showModal(); }
        } else if (!element.open || modal) {
          if (element.open) element.close();
          element.show();
        }
        const actual = !element.open ? "hidden" : element.matches(":modal") ? "modal" : "open";
        if (actual !== value) throw new Error(`dialog stayed ${actual} after ${value}`);
        if (this.modalOrder) {
          if (actual !== "modal") this.modalOrder.remove(element);
          else if (!modal) this.modalOrder.add(element);
        }
      } else {
        const wanted = value === "true";
        if (element.matches(":popover-open") !== wanted) {
          if (wanted) element.showPopover(); else element.hidePopover();
        }
        if (element.matches(":popover-open") !== wanted) throw new Error("popover did not reach its decided shown state");
      }
    } catch (error) {
      throw new Error(`shown property at node ${node}: ${error.message}`);
    }
  }

  // Manual observations use decimal ordinals at the JSON boundary. Reading
  // old or exhausted history fails the assertion without stopping the app.
  topModal() { return this.modalOrder ? this.modalOrder.top(this.root) : null; }
  scrollCount() { return this.scrollLog ? this.scrollLog.total() : 0n; }
  scrollRecord(ordinal) {
    if (!this.scrollLog) throw new Error("scroll history requires manualEffects");
    return this.scrollLog.at(BigInt(ordinal));
  }

  perform(fx) {
    const w = this.win;
    switch (fx.op) {
      case "guardleave":
        this.setLeaveGuard(fx.on);
        return;
      case "push":
        w.history.pushState(null, "", fx.url);
        return;
      case "replace":
        w.history.replaceState(null, "", fx.url);
        return;
      case "title":
        w.document.title = fx.text;
        return;
      case "shown": {
        const { element, property, value, intent } = fx;
        if (!element.isConnected || !this.root.contains(element) || element[property === 6 ? "__shownIntent" : "__popoverIntent"] !== intent) return;
        this.applyShown(element, property, value, fx.node);
        return;
      }
      case "ref": {
        // After the batch: the element exists. Focus events this raises are
        // queued (busy) and delivered as their own turns.
        const el = fx.element;
        if (!el || this.lookup(fx.node) !== el || !this.root.contains(el)) return;
        if (fx.mode === 4) {
          checkValueControl(el, fx.node);
          if (el.__composing) el.__applyValue = el.value !== el.__renderedValue;
          else applyRenderedValue(el);
        } else if (fx.mode === 2) el.blur();
        else if (fx.mode === 5) el.focus({ preventScroll: true });
        else if (fx.mode === 6) {
          if (this.manualScrollers) {
            for (let ancestor = el.parentElement; ancestor && ancestor !== this.root; ancestor = ancestor.parentElement) {
              if (this.manualScrollers.has(ancestor)) this.manualScrollError = "ScrollIntoView inside an element that handles scroll needs layout the native oracle does not have; use a scroll step";
            }
          }
          el.scrollIntoView(fx.options);
          if (this.scrollLog) this.scrollLog.add(el, "into-view");
        } else if (fx.mode === 7) {
          const options = { behavior: fx.behavior };
          const handled = this.manualScrollers?.has(el);
          const unmodelled = handled && (fx.top.kind === "end" || fx.left.kind === "end");
          if (unmodelled) this.manualScrollError = "ScrollTo End on an element that handles scroll needs layout the native oracle does not have; use a scroll step";
          if (handled && !unmodelled) {
            this.observeManualScroll(el);
            const position = this.manualScrollers.get(el).expected;
            this.expectManualScroll(el, {
              top: fx.top.kind === "keep" ? position.top : fx.top.kind === "start" ? 0 : fx.top.pixels,
              left: fx.left.kind === "keep" ? position.left : fx.left.kind === "start" ? 0 : fx.left.pixels,
            });
          }
          for (const axis of ["top", "left"]) {
            const edge = fx[axis];
            if (edge.kind === "keep") continue;
            options[axis] = edge.kind === "start" ? 0 : edge.kind === "end" ? (axis === "top" ? el.scrollHeight : el.scrollWidth) : edge.pixels;
          }
          if (options.left !== undefined && this.win.getComputedStyle(el).direction === "rtl") options.left = -options.left;
          el.scrollTo(options);
          if (this.scrollLog) this.scrollLog.add(el, "to");
        }
        else {
          el.focus();
          if (fx.mode === 3 && typeof el.select === "function") el.select();
        }
        return;
      }
      case "set":
      case "remove":
        try {
          const store = fx.session ? this.sessionStorage : this.storage;
          if (!store) throw new Error("storage is unavailable");
          if (fx.op === "set") store.setItem(fx.key, fx.value);
          else store.removeItem(fx.key);
        } catch (error) {
          console.warn(`${fx.session ? "session" : "local"} storage ${fx.op} ${fx.key} failed: ${error}`);
          this.storageWriteFailed(fx, error);
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
        const fn = () => this.guard(() => this.report(fx.id, new Uint8Array([RES_ONLINE, this.isOnline() ? 1 : 0])));
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
        const fn = () => this.guard(() => this.report(fx.id, new Uint8Array([RES_VISIBLE, this.isVisible() ? 1 : 0])));
        doc.addEventListener("visibilitychange", fn);
        this.live.set(fx.id, { kind: "sub", req: fx, cancel: () => doc.removeEventListener("visibilitychange", fn) });
        return;
      }
      case "media": {
        if (!this.mediaQueries.includes(fx.query)) throw new Error(`undeclared media query ${JSON.stringify(fx.query)}`);
        const query = this.mediaQuery(fx.query);
        this.mediaMatch(query);
        const fn = () => this.guard(() => {
          const matches = this.mediaMatch(query);
          this.report(fx.id, new Uint8Array([RES_MATCHES, matches ? 1 : 0]));
        });
        query.addEventListener("change", fn);
        this.live.set(fx.id, { kind: "sub", req: fx, cancel: () => query.removeEventListener("change", fn) });
        return;
      }
      case "interval": {
        if (this.manual || this.manualIntervals) {
          // Manual mode: ticks only through tick(id).
          this.live.set(fx.id, { kind: "sub", req: fx, cancel: () => {} });
          return;
        }
        const h = setInterval(() => this.guard(() => this.result(fx.id, this.firedPayload())), fx.ms);
        this.live.set(fx.id, { kind: "sub", req: fx, cancel: () => clearInterval(h) });
        return;
      }
      case "storagechanges": {
        let ids = this.storageChanges.get(fx.key);
        if (!ids) { ids = new Set(); this.storageChanges.set(fx.key, ids); }
        ids.add(fx.id);
        if (this.storageListener === null) {
          this.storageListener = event => this.guard(() => {
            if (!this.storage || event.storageArea !== this.storage) return;
            // Reporting can drain an already-full ingress queue. Fix the
            // recipients before that delivery can dispose or mount a site.
            const recipients = event.key === null ? [...this.storageChanges.values()].flatMap(ids => [...ids]) : [...(this.storageChanges.get(event.key) ?? [])];
            if (recipients.length === 0) return;
            const payload = storageResult(event.key === null ? null : event.newValue);
            for (const id of recipients) this.report(id, payload);
          });
          w.addEventListener("storage", this.storageListener);
        }
        this.live.set(fx.id, { kind: "sub", req: fx, cancel: () => {
          ids.delete(fx.id);
          if (ids.size === 0) this.storageChanges.delete(fx.key);
          if (this.storageChanges.size === 0 && this.storageListener !== null) {
            w.removeEventListener("storage", this.storageListener);
            this.storageListener = null;
          }
        } });
        return;
      }
      case "storagefailures": {
        const entry = { kind: "sub", req: fx, pendingFailures: new Set(), cancel: () => {
          this.storageFailureSubscribers.delete(fx.id);
          for (const item of entry.pendingFailures) this.unlinkStorageFailure(item);
          if (this.storageFailureCount === 0 && this.storageFailureTask !== null) {
            clearTimeout(this.storageFailureTask); this.storageFailureTask = null;
          }
        } };
        this.storageFailureSubscribers.set(fx.id, entry);
        this.live.set(fx.id, entry);
        return;
      }
      case "clipboard": {
        const entry = { kind: "clipboard", req: fx, cancel: () => { entry.active = false; }, active: true };
        this.live.set(fx.id, entry);
        const finish = payload => {
          if (!entry.active || this.live.get(fx.id) !== entry || this.poisoned || this.ending) return;
          this.live.delete(fx.id);
          this.result(fx.id, payload);
        };
        if (this.manual) {
          // The write is performed with this batch. Cancellation can suppress
          // its later answer but cannot undo successful clipboard contents.
          const denied = this.manualClipboardDenied;
          if (!denied) {
            this.clipboardText = fx.text;
            this.clipboardHtml = fx.html ?? "";
            if (this.clipboardWrites === U64_MAX) this.clipboardObservationError = "clipboard write observation exhausted its U64 count";
            else this.clipboardWrites += 1n;
          }
          const task = setTimeout(() => finish(new Uint8Array(denied ? [RES_CLIPBOARD_FAILED, 1] : [RES_COPIED])), 0);
          entry.cancel = () => { entry.active = false; clearTimeout(task); };
          return;
        }
        const clipboard = w?.navigator?.clipboard;
        if (!clipboard || (fx.html === null ? typeof clipboard.writeText !== "function" : typeof clipboard.write !== "function" || typeof w.ClipboardItem !== "function")) {
          // Every answer is a later turn, even a synchronously unavailable API.
          const task = setTimeout(() => finish(new Uint8Array([RES_CLIPBOARD_FAILED, 2])), 0);
          entry.cancel = () => { entry.active = false; clearTimeout(task); };
          return;
        }
        try {
          const written = fx.html === null ? clipboard.writeText(fx.text) : clipboard.write([new w.ClipboardItem({
            "text/plain": new w.Blob([fx.text], { type: "text/plain" }),
            "text/html": new w.Blob([fx.html], { type: "text/html" }),
          })]);
          Promise.resolve(written).then(() => finish(new Uint8Array([RES_COPIED])), error => finish(new Uint8Array([RES_CLIPBOARD_FAILED, error?.name === "NotAllowedError" ? 1 : 2])));
        } catch (error) {
          const task = setTimeout(() => finish(new Uint8Array([RES_CLIPBOARD_FAILED, error?.name === "NotAllowedError" ? 1 : 2])), 0);
          entry.cancel = () => { entry.active = false; clearTimeout(task); };
        }
        return;
      }
      case "sessionget":
      case "get": {
        // One turn later, never inside the current call.
        const h = setTimeout(() => this.guard(() => {
          this.live.delete(fx.id);
          let v = null;
          try {
            const store = fx.op === "sessionget" ? this.sessionStorage : this.storage;
            v = store ? store.getItem(fx.key) : null;
          } catch (_) {
            v = null;
          }
          this.result(fx.id, storageResult(v));
        }), 0);
        this.live.set(fx.id, { kind: "get", cancel: () => clearTimeout(h) });
        return;
      }
      case "work": {
        const held = this.manual || this.manualWork;
        this.monitor.jobIssued(fx.id, fx.task, fx.input, fx.timeout, held);
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
          const h = setTimeout(() => this.guard(() => {
            const payload = this.firedPayload();
            this.live.delete(fx.id);
            this.result(fx.id, payload);
          }), fx.ms);
          this.live.set(fx.id, { kind: "timer", cancel: () => clearTimeout(h) });
          return;
        }
        this.startTransfer(fx);
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
        this.startTransfer(fx);
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
  // Saving and fetching files (design.md, "Files").

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

  // HTTP, upload and file-fetch share lifetime and timeout handling. A
  // terminal occurrence retains its source until delivery so already queued
  // reports remain valid; cancellation and timeout explicitly discard them.
  finishTransfer(id, entry, payload, discard = false) {
    if (this.live.get(id) !== entry || entry.terminal) return false;
    entry.terminal = true;
    entry.stop?.();
    if (discard) this.dropReports(id, entry);
    payload.isLive = () => this.live.get(id) === entry;
    payload.before = () => this.live.delete(id);
    this.result(id, payload);
    return true;
  }

  // Exactly one timer samples each request's latest counts. Split long U32
  // waits at the browser's signed timer limit rather than allowing overflow
  // to turn a many-day interval into a one-millisecond loop.
  transferSampler(fx, entry) {
    let timer = null, latest = null, deadline = 0;
    const now = () => performance.now();
    const clear = () => { if (timer !== null) { clearTimeout(timer); timer = null; this.timers -= 1; } latest = null; };
    const arm = () => {
      this.timers += 1;
      timer = setTimeout(() => {
        timer = null; this.timers -= 1;
        if (this.live.get(fx.id) !== entry || entry.terminal) return;
        if (now() < deadline) { arm(); return; }
        const payload = latest; latest = null;
        if (payload !== null) this.report(fx.id, payload);
      }, Math.min(0x7fffffff, Math.max(0, Math.ceil(deadline - now()))));
    };
    return { clear, sample: (direction, done, total) => {
      if (!fx.progressMs || entry.terminal || this.live.get(fx.id) !== entry) return;
      latest = this.transferPayload(direction, done, total);
      if (timer === null) { deadline = now() + fx.progressMs; arm(); }
    } };
  }

  transferPayload(direction, done, total) {
    const integer = value => {
      if (typeof value === "number" && (!Number.isSafeInteger(value) || value < 0)) throw new Error("transfer count is not an exact unsigned integer");
      if (typeof value !== "bigint" && typeof value !== "number" && !(typeof value === "string" && /^(0|[1-9][0-9]*)$/.test(value))) throw new Error("transfer count is not an unsigned integer");
      const n = BigInt(value);
      if (n < 0n || n > U64_MAX) throw new Error("transfer count is outside U64");
      return n;
    };
    const dir = direction === "sending" ? 1 : direction === "receiving" ? 2 : 0;
    if (dir === 0) throw new Error("invalid transfer direction");
    const bytes = new Uint8Array(19), view = new DataView(bytes.buffer);
    bytes[0] = RES_PROGRESS; bytes[1] = dir;
    view.setBigUint64(2, integer(done), true);
    bytes[10] = total === null ? 0 : 1;
    view.setBigUint64(11, total === null ? 0n : integer(total), true);
    return bytes;
  }

  // Manual replay reports the same bytes and uses the same ingress source as
  // a transport, without a sampling timer or retiring the pending request.
  progressEffect(id, direction, done, total) {
    const entry = this.live.get(id);
    if (this.poisoned || !entry || entry.terminal || !entry.req?.progressMs || !["http", "upload", "fetch"].includes(entry.req.op)) return false;
    this.report(id, this.transferPayload(direction, done, total));
    return true;
  }

  startTransfer(fx) {
    const ctl = new AbortController();
    let timeout = null, xhr = null;
    const entry = { kind: fx.op === "fetch" ? "fetch" : "http", req: fx, running: true, terminal: false };
    this.live.set(fx.id, entry);
    const sampler = this.transferSampler(fx, entry);
    entry.stop = () => {
      sampler.clear();
      if (timeout !== null) { clearTimeout(timeout); timeout = null; this.timers -= 1; }
    };
    entry.cancel = () => { entry.stop(); ctl.abort(); xhr?.abort(); };
    const finish = payload => this.finishTransfer(fx.id, entry, payload);
    const fail = error => finish(concat([new Uint8Array([RES_NETWORK]), utf8enc.encode(String(error))]));
    if (fx.timeout > 0) {
      this.timers += 1;
      timeout = setTimeout(() => {
        if (!this.finishTransfer(fx.id, entry, new Uint8Array([RES_TIMEOUT]), true)) return;
        ctl.abort(); xhr?.abort();
      }, fx.timeout);
    }
    // XHR's blob response keeps file bytes in the browser. An explicit fetch
    // backend always wins; nondefault cache needs Fetch's RequestInit.
    if (fx.progressMs && this.fetch === null && (fx.op === "upload" || (fx.op === "fetch" && fx.cache === "default"))) {
      try {
        xhr = new this.win.XMLHttpRequest();
        xhr.open(fx.method, fx.url);
        xhr.withCredentials = fx.credentials === "include";
        // Decode an HTTP answer as UTF-8, as Fetch.text does, regardless of
        // the response header's charset. File bytes remain a browser Blob.
        xhr.responseType = fx.op === "fetch" ? "blob" : "arraybuffer";
        for (const [name, value] of fx.headers) xhr.setRequestHeader(name, value);
        const progress = event => this.guard(() => {
          if (fx.op === "fetch" && event.loaded > this.maxFileBytes) {
            finish(new Uint8Array([RES_FILE_FAILED, FILE_TOO_LARGE])); xhr.abort(); return;
          }
          const sameOrigin = new URL(xhr.responseURL || fx.url, this.doc.baseURI).origin === this.win.location.origin;
          const known = fx.op === "upload" || (sameOrigin && !xhr.getResponseHeader("content-encoding"));
          sampler.sample(fx.op === "upload" ? "sending" : "receiving", event.loaded, known && event.lengthComputable ? event.total : null);
        });
        if (fx.op === "upload") xhr.upload.addEventListener("progress", progress);
        else xhr.addEventListener("progress", progress);
        xhr.onload = () => {
          const headers = new Headers();
          for (const line of xhr.getAllResponseHeaders().trim().split(/[\r\n]+/)) {
            if (!line) continue;
            const colon = line.indexOf(":");
            if (colon < 1) { fail("invalid response header"); return; }
            headers.append(line.slice(0, colon), line.slice(colon + 1).trim());
          }
          finish(fx.op === "fetch" ? this.fetchedPayload(fx.url, xhr.status, [...headers], xhr.response) : httpResult(xhr.status, new TextDecoder().decode(xhr.response), [...headers]));
        };
        xhr.onerror = () => fail("XMLHttpRequest network error");
        xhr.onabort = () => fail("XMLHttpRequest aborted");
        xhr.send(fx.op === "upload" ? fx.blob : null);
      } catch (error) { fail(error); }
      return;
    }
    const init = { method: fx.method, headers: fx.headers, signal: ctl.signal, cache: fx.cache, credentials: fx.credentials };
    if (fx.op === "upload") init.body = fx.blob;
    else if (fx.method !== "GET" && fx.method !== "HEAD" && fx.body !== "") init.body = fx.body;
    const send = this.fetch ?? globalThis.fetch;
    new Promise(resolve => resolve(send(fx.url, init))).then(async response => {
      if (this.live.get(fx.id) !== entry || entry.terminal) return;
      // Fetch exposes no sent-byte events. A supplied backend gets one coarse
      // complete Sending report when its response confirms the send finished.
      if (fx.op === "upload" && fx.progressMs) this.report(fx.id, this.transferPayload("sending", fx.blob.size, fx.blob.size));
      const headers = [...response.headers];
      let body;
      if (fx.progressMs && fx.op !== "upload") {
        const length = response.headers.get("content-length"), encoding = response.headers.get("content-encoding");
        const total = response.type !== "cors" && !encoding && length !== null && /^(0|[1-9][0-9]*)$/.test(length) && BigInt(length) <= U64_MAX ? BigInt(length) : null;
        const reader = response.body?.getReader();
        const chunks = [];
        let done = 0n;
        if (reader) {
          try {
            for (;;) {
              const next = await reader.read();
              if (this.live.get(fx.id) !== entry || entry.terminal) { await reader.cancel(); return; }
              if (next.done) break;
              done += BigInt(next.value.byteLength);
              if (fx.op === "fetch" && done > BigInt(this.maxFileBytes)) {
                finish(new Uint8Array([RES_FILE_FAILED, FILE_TOO_LARGE])); await reader.cancel(); return;
              }
              chunks.push(next.value);
              sampler.sample("receiving", done, total);
            }
          } finally { reader.releaseLock(); }
        }
        const blob = new Blob(chunks);
        body = fx.op === "fetch" ? blob : await blob.text();
      } else body = fx.op === "fetch" ? await response.blob() : await response.text();
      finish(fx.op === "fetch" ? this.fetchedPayload(fx.url, response.status, headers, body) : httpResult(response.status, body, headers));
    }).catch(fail);
  }

  // A fetched body as result tag 21 with its file, or FileFailed(TooLarge).
  fetchedPayload(url, status, headers, blob) {
    if (blob.size > this.maxFileBytes) return new Uint8Array([RES_FILE_FAILED, FILE_TOO_LARGE]);
    const type = (headers.find(([k]) => k.toLowerCase() === "content-type") ?? [null, ""])[1];
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
  readPortMessage(u8, dv, at0, dry = false) {
    let at = at0;
    const n = dv.getUint32(at, true);
    const json = readStr(u8, at + 4, n);
    at += 4 + n;
    const blobs = [];
    const nblobs = dv.getUint32(at, true);
    at += 4;
    for (let i = 0; i < nblobs; i += 1) {
      const len = dv.getUint32(at, true);
      if (len > u8.length - at - 4) throw new Error("truncated port blob");
      if (!dry) blobs.push(u8.slice(at + 4, at + 4 + len));
      at += 4 + len;
    }
    const files = [];
    const nfiles = dv.getUint32(at, true);
    at += 4;
    for (let i = 0; i < nfiles; i += 1) {
      const { token, start, len } = fileRange(dv, at);
      if (!dry) {
        const file = this.files.get(token);
        if (file === undefined) throw new Error(`a port message names file handle ${token}, which this runtime does not hold`);
        files.push(start === 0 && len === file.size ? file : new File([file.slice(start, start + len)], file.name ?? "", { type: file.type }));
      }
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
        if (payload.parts[0][0] === RES_PORT_ANSWER) this.portCount(fx.port, "answered");
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
      backlog: () => sub.latest ? sub.entry.reports?.size ?? 0 : sub.queue.length,
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
    let payload, data;
    try {
      data = portData(value);
      payload = portReplyPayload(data);
    } catch (e) {
      if (e instanceof PortDataError) throw new TypeError(`port "${sub.port}": emit was given something that is not JSON data: ${e.message}`);
      throw e;
    }
    if (payload.size > this.maxPortBytes) {
      this.portCount(sub.port, "tooLarge");
      payload = portFailed(2);
    } else if (sub.latest && data.blobs.length > 0) {
      // A report is a snapshot at emit, even if its caller later mutates a
      // byte array. Files are immutable browser objects and stay by reference.
      payload = portReplyPayload({ ...data, blobs: data.blobs.map((bytes) => bytes.slice()) });
    }
    if (sub.latest) {
      const replaced = this.report(sub.id, {
        ...payload,
        before: () => { if (payload.parts[0][0] === RES_PORT_ANSWER) this.portCount(sub.port, "messages"); },
      });
      if (replaced) this.portCount(sub.port, "coalesced");
      return true;
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
    if (sub.latest) {
      this.result(sub.id, {
        ...payload,
        isLive: () => this.live.get(sub.id) === sub.entry,
        before: () => {
          this.live.delete(sub.id);
          this.dropPushSub(sub);
        },
      });
      return;
    }
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
      } else if (payload.parts[0][0] === RES_PORT_ANSWER) this.portCount(sub.port, "messages");
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
  // port's answer (tag 14), a job's answer (tag 10) or a fetched body (tag
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
      const terminal = answer.closed || answer.threw !== undefined;
      const payload = manualPortPayload(answer);
      if (!terminal && this.portDecls.get(port).delivery === 2) this.report(id, payload);
      else {
        this.result(id, {
          ...payload,
          isLive: () => this.live.get(id) === e,
          before: () => { if (terminal) this.live.delete(id); },
        });
      }
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
  // timeout, Timeout) is delivered as a turn unless CANCEL forgets it
  // first; `settled`, when given, is called once either way. The timeout
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
      this.monitor.jobDelivered(fx.id, outcome, klass, output);
      open = false;
      if (timer !== null) {
        clearTimeout(timer);
        timer = null;
        this.timers -= 1;
      }
      this.result(fx.id, bytes);
      if (settled) settled();
    };
    // In manual mode a spec's time is manual too: a timeout never fires on
    // its own, and expireEffect(id) expires it instead.
    if (fx.timeout > 0 && !this.manual && !this.manualWork) {
      this.timers += 1;
      timer = setTimeout(() => {
        timer = null;
        this.timers -= 1;
        if (stop) stop("timeout");
        finish(new Uint8Array([RES_TIMEOUT]), "timeout");
      }, fx.timeout);
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
    // In manual mode the timeout is not on the clock, so a finishing job
    // there is bounded by the cap alone.
    const timeout = this.manual || this.manualWork ? 0 : fx.timeout;
    stop = this.workPool().submit(payload, done, { id: fx.id, task: fx.task, objects, prepared, finish: fx.finish, timeout, maxOutput: this.maxOutputBytes });
  }

  // Report a lost job and return its class name. The `roc worker fault
  // [CLASS]` prefix is stable: the browser spec runner tells these reports
  // from page errors by it.
  reportLost(fx, code, message) {
    const klass = this.protocol.LOST_CLASSES[code] ?? "executor";
    console.error(`roc worker fault [${klass}] in task "${fx.task}": ${message}`);
    if (this.onWorkerFault) this.onWorkerFault({ id: fx.id, task: fx.task, class: klass, message });
    return klass;
  }

  workPool() {
    if (this.pool === null) {
      const W = (this.win && this.win.Worker) ?? globalThis.Worker;
      this.pool = new WorkPool({ module: this.module, url: this.workerUrl, max: this.maxWorkers, inline: this.workerMode === "inline", Worker: W, monitor: this.monitor, faultClasses: this.protocol.LOST_CLASSES, maxBytes: this.maxWorkerBytes, live: (token) => this.files.has(token) });
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
    this.dropReports(id, e);
    this.live.delete(id);
    e.cancel();
  }

  // Manual mode: awaited requests still pending, in issue order.
  pendingEffects() {
    return this.issued.filter((id) => this.live.has(id) && !this.live.get(id).running && !this.live.get(id).terminal).map((id) => this.live.get(id).req ?? { id });
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
    if (e.running || e.terminal || e.kind === "portcall") return false;
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
      this.finishTransfer(id, e, this.fetchedPayload(e.req.url, answer.status, answer.headers ?? [], new Blob([answer.body ?? ""])));
      return true;
    }
    if (e.req?.progressMs) {
      const payload = answer.timeout ? new Uint8Array([RES_TIMEOUT]) : answer.network !== undefined ? concat([new Uint8Array([RES_NETWORK]), utf8enc.encode(answer.network)]) : httpResult(answer.status, answer.body ?? "", answer.headers ?? []);
      this.finishTransfer(id, e, payload, !!answer.timeout);
    } else {
      this.live.delete(id);
      if (answer.timeout) this.result(id, new Uint8Array([RES_TIMEOUT]));
      else if (answer.network !== undefined) this.result(id, concat([new Uint8Array([RES_NETWORK]), utf8enc.encode(answer.network)]));
      else if (answer.status !== undefined) this.result(id, httpResult(answer.status, answer.body ?? "", answer.headers ?? []));
      else this.guard(() => this.result(id, this.firedPayload()));
    }
    return true;
  }

  // Manual mode: answer pending work job `id` as lost with fault class
  // `klass` ("contract" ... "executor", the module's fault names) without
  // running it, reported as a real loss is. Returns false when `id` is not a
  // pending job or `klass` is not a class.
  loseEffect(id, klass) {
    const e = this.live.get(id);
    const code = this.protocol.LOST_CLASSES.indexOf(klass);
    if (this.poisoned || e === undefined || e.kind !== "work" || e.running || code < 1) return false;
    this.live.delete(id);
    const reported = this.reportLost(e.req, code, "lost by the spec");
    this.monitor.jobDelivered(id, code === LOST_UNAVAILABLE ? "unavailable" : "lost", reported, null);
    this.result(id, new Uint8Array([RES_WORK_LOST, code]));
    return true;
  }

  // Manual mode: expire the timeout of pending work job `id`, which answers
  // it `Timeout` as a real expiry does (a pending job has no worker to stop).
  // Returns false when `id` is not a pending job or has no timeout.
  expireEffect(id) {
    const e = this.live.get(id);
    if (this.poisoned || e === undefined || e.kind !== "work" || e.running || !(e.req.timeout > 0)) return false;
    this.live.delete(id);
    this.monitor.jobDelivered(id, "timeout", null, null);
    this.result(id, new Uint8Array([RES_TIMEOUT]));
    return true;
  }

  // Manual mode: one tick of a live interval subscription.
  tick(id) {
    const e = this.live.get(id);
    if (e === undefined || e.kind !== "sub") return false;
    this.guard(() => this.result(id, this.firedPayload()));
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

  // Wall time is sampled only at boot and when a timer callback runs. The
  // encoded result keeps that sample even if ingress must wait for a batch.
  readNow() {
    return checkedI64(this.environment.now ? this.environment.now() : Date.now(), "options.environment.now");
  }

  firedPayload() {
    return concat([new Uint8Array([RES_FIRED]), i64Bytes(this.readNow())]);
  }

  isOnline() {
    const nav = this.win ? this.win.navigator : null;
    const value = this.environment.online ? this.environment.online() : nav ? nav.onLine !== false : true;
    if (typeof value !== "boolean") throw new Error("options.environment.online must answer a boolean");
    return value;
  }

  isVisible() {
    const value = this.environment.visible ? this.environment.visible() : !this.doc || this.doc.visibilityState !== "hidden";
    if (typeof value !== "boolean") throw new Error("options.environment.visible must answer a boolean");
    return value;
  }

  // MediaQueryList is the browser fact and event source. Check the reader's
  // shape at boot and at subscription, before retaining a listener.
  mediaQuery(query) {
    const value = this.environment.matchMedia ? this.environment.matchMedia(query) : this.win.matchMedia(query);
    if (!value || typeof value.addEventListener !== "function" || typeof value.removeEventListener !== "function") throw new Error("options.environment.matchMedia must answer an object with boolean matches and change listener methods");
    return value;
  }

  mediaMatch(query) {
    const matches = query.matches;
    if (typeof matches !== "boolean") throw new Error("options.environment.matchMedia must answer an object with boolean matches");
    return matches;
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
    return { memBytes: x.memory.buffer.byteLength, liveAllocs: Number(x.metric(4)), liveBytes: Number(x.metric(5)), captureRefused: this.captureRefused, counters: this.workRecord().counters };
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

// Picture metadata is untrusted deployment input. This pass decodes only data:
// actual DOM kinds/text, hashes, the mount batch and Roc's verdict are separate.
class PictureEnvelopeError extends Error {
  constructor(rule) { super(`picture envelope: ${rule}`); this.rule = rule; }
}

// Read one bounded deployment envelope before any DOM allocation or claim
// execution. A classified malformed result is separate from a picture verdict;
// callers still measure actual names, text boundaries and hashes independently.
export function decodePictureEnvelope(bytes, limits = {}) {
  const ceiling = 16 * 1024 * 1024 - 37;
  const settings = { maxBytes: ceiling, maxNodes: 262144, maxDepth: 1024 };
  if (!limits || typeof limits !== "object" || Array.isArray(limits)) throw new PictureEnvelopeError("invalid limits");
  for (const key of Object.keys(limits)) {
    if (!Object.hasOwn(settings, key)) throw new PictureEnvelopeError(`unknown limit ${key}`);
    const value = limits[key], maximum = settings[key];
    if (!Number.isInteger(value) || value < 0 || value > maximum) throw new PictureEnvelopeError(`invalid limit ${key}`);
    settings[key] = value;
  }
  const fail = rule => { throw new PictureEnvelopeError(rule); };
  if (!(bytes instanceof Uint8Array) || bytes.length > settings.maxBytes) fail("byte limit");
  let view;
  try { view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength); } catch (_) { fail("unreadable bytes"); }
  let at = 0;
  const need = n => { if (!Number.isInteger(n) || n < 0 || n > bytes.length - at) fail("truncated bytes"); };
  const u8 = () => { need(1); return bytes[at++]; };
  const u16 = () => { need(2); const n = view.getUint16(at, true); at += 2; return n; };
  const u32 = () => { need(4); const n = view.getUint32(at, true); at += 4; return n; };
  const count = (minimum, maximum, label) => {
    const n = u32();
    if (n > maximum || n > Math.floor((bytes.length - at) / minimum)) fail(`${label} count`);
    return n;
  };
  const string = () => {
    const n = u32(); need(n);
    let value;
    try { value = utf8.decode(bytes.subarray(at, at + n)); } catch (_) { fail("invalid UTF-8"); }
    at += n; return value;
  };
  const name = () => {
    const namespace = string() || null, prefix = string() || null, local = string();
    if (local.length === 0) fail("empty local name");
    return { namespace, prefix, local };
  };
  const presence = () => { const value = u8(); if (value > 1) fail("invalid presence"); return value === 1; };
  const digest = () => { need(32); const value = bytes.slice(at, at + 32); at += 32; return value; };
  for (const value of [83, 80, 67, 49]) if (u8() !== value) fail("magic");
  if (u16() !== 1 || u16() !== 19 || u32() !== 0) fail("schema, protocol or flags");
  const root = name(), batch_bytes = u32(), mountFingerprint = digest(), expectedDigest = digest();
  const physicalCount = u32();
  if (physicalCount > settings.maxNodes || physicalCount > Math.floor((bytes.length - at) / 4)) fail("physical node limit");
  const parent = new Int32Array(physicalCount); parent.fill(-1);
  const kinds = new Uint8Array(physicalCount);
  const physical = ordinal => { if (ordinal >= physicalCount) fail("physical reference"); return ordinal; };
  const containers = [], containerKeys = new Set();
  const containerCount = count(9, 2 * physicalCount + 1, "container");
  if (containerCount === 0) fail("missing mount container");
  for (let i = 0; i < containerCount; i++) {
    const owner = u32(), role = u8();
    if (role > 1 || (i === 0 ? owner !== 0xffffffff || role !== 0 : owner === 0xffffffff)) fail("container owner or role");
    if (i !== 0) physical(owner);
    const key = `${owner}:${role}`;
    if (containerKeys.has(key)) fail("duplicate container");
    containerKeys.add(key);
    const n = count(4, physicalCount, "child"), children = [];
    let previous = -1;
    for (let j = 0; j < n; j++) {
      const child = physical(u32());
      if (child <= previous || (i !== 0 && child <= owner)) fail("child preorder");
      if (parent[child] !== -1) fail("duplicate physical placement");
      parent[child] = i; children.push(child); previous = child;
    }
    containers.push({ owner, role, children });
  }
  const container = ordinal => { if (ordinal >= containers.length) fail("container reference"); return containers[ordinal]; };
  const claim = (ordinal, kind) => {
    physical(ordinal);
    if (kinds[ordinal] !== 0) fail("duplicate physical claim");
    kinds[ordinal] = kind;
  };
  const logicalCount = count(5, settings.maxNodes, "logical"), logical = [];
  const constructed = new Set(), logicalChildren = new Uint32Array(containerCount);
  for (let i = 0; i < logicalCount; i++) {
    const target = u8();
    if (target === 0 || target === 1) {
      const node = physical(u32()); claim(node, target === 0 ? 1 : 3);
      if (parent[node] < 0) fail("unplaced physical node");
      logicalChildren[parent[node]]++;
      logical.push({ target, physical: node });
    } else if (target === 2) logical.push({ target, run: u32(), part: u32() });
    else if (target === 3 || target === 4) {
      const owner = u32(), childIndex = u32(); container(owner);
      const key = `${owner}:${childIndex}`;
      if (constructed.has(key)) fail("duplicate constructed position");
      constructed.add(key); logicalChildren[owner]++;
      logical.push({ target, container: owner, logical_child_index: childIndex, data: string() });
    } else fail("unknown logical target");
  }
  const logicalReference = ordinal => { if (ordinal >= logical.length) fail("logical reference"); return logical[ordinal]; };
  const runCount = count(13, logicalCount, "run"), runs = [], runPositions = new Set(), runContainers = new Set();
  const textParts = new Uint8Array(logicalCount);
  for (let i = 0; i < runCount; i++) {
    const owner = u32(), childIndex = u32(), children = container(owner).children;
    const present = presence(), node = present ? physical(u32()) : null;
    if (present ? childIndex >= children.length || children[childIndex] !== node : childIndex > children.length) fail("text run position");
    const key = `${owner}:${childIndex}`;
    if (runPositions.has(key)) fail("duplicate text run position");
    runPositions.add(key); runContainers.add(owner);
    if (present) claim(node, 2);
    const n = count(8, logicalCount, "part"), parts = [];
    if (n === 0) fail("empty text run");
    let utf16Units = 0;
    for (let j = 0; j < n; j++) {
      const ordinal = u32(), units = u32(), entry = logicalReference(ordinal);
      if (entry.target !== 2 || entry.run !== i || entry.part !== j || textParts[ordinal]) fail("text part back reference");
      textParts[ordinal] = 1; utf16Units += units;
      if (!Number.isSafeInteger(utf16Units) || (!present && units !== 0)) fail("text run length");
      parts.push({ logical: ordinal, utf16Units: units });
    }
    logicalChildren[owner] += n;
    runs.push({ container: owner, childIndex, physical: node, parts, utf16Units });
  }
  for (let i = 0; i < logical.length; i++) {
    const entry = logical[i];
    if (entry.target === 2 && !textParts[i]) fail("missing text part");
    if ((entry.target === 3 || entry.target === 4) && entry.logical_child_index >= logicalChildren[entry.container]) fail("constructed position");
  }
  const bindings = [], principals = new Set(), holes = new Set();
  const bindingCount = count(18, Math.floor(bytes.length / 18), "binding");
  for (let i = 0; i < bindingCount; i++) {
    const birthOffset = u32(), role = u8(), address = u32(), slot = u32(), kind = u8(), target = u32();
    logicalReference(target);
    if (birthOffset === 0 || birthOffset >= batch_bytes || address === 0 || address === 0xffffffff || role > 3) fail("binding address, birth or role");
    if ((role === 0 && (slot !== 0 || kind !== 0)) || (role === 1 && kind !== 0) || (role === 2 && (kind < 1 || kind > 6)) || (role === 3 && kind !== 4 && kind !== 5)) fail("binding fields");
    const index = role === 2 ? holes : principals;
    const key = role === 2 ? `${birthOffset}:${address}:${slot}` : `${birthOffset}:${address}`;
    if (index.has(key)) fail("duplicate binding role");
    index.add(key); bindings.push({ birthOffset, role, address, slot, kind, logical: target });
  }
  const scaffolds = [], scaffoldKeys = new Set();
  const scaffoldCount = count(9, Math.floor(bytes.length / 9), "scaffold");
  for (let i = 0; i < scaffoldCount; i++) {
    const role = u8(), owner = physical(u32());
    if (role === 0) {
      const target = u32(), c = container(target), present = presence(), node = present ? physical(u32()) : null;
      if (c.owner !== owner || c.children.length !== (present ? 1 : 0) || (present && c.children[0] !== node) || runContainers.has(target)) fail("control text container");
      if (present) claim(node, 2);
      const key = `text:${owner}:${target}`;
      if (scaffoldKeys.has(key)) fail("duplicate scaffold");
      scaffoldKeys.add(key); scaffolds.push({ role, owner, container: target, physical: node });
    } else if (role === 1) {
      const attribute = name(), original = presence() ? string() : null, value = presence() ? string() : null;
      const key = JSON.stringify([owner, attribute.namespace, attribute.local]);
      if (scaffoldKeys.has(key)) fail("duplicate scaffold attribute");
      scaffoldKeys.add(key); scaffolds.push({ role, owner, name: attribute, original, value });
    } else if (role === 2) {
      const node = physical(u32());
      if (parent[node] < 0 || containers[parent[node]].owner !== owner || containers[parent[node]].role !== 0) fail("selection option parent");
      claim(node, 1);
      const key = `selection:${owner}`;
      if (scaffoldKeys.has(key)) fail("duplicate scaffold");
      scaffoldKeys.add(key); scaffolds.push({ role, owner, physical: node });
    } else fail("unknown scaffold role");
  }
  if (at !== bytes.length) fail("trailing bytes");
  const depths = new Uint16Array(physicalCount), ancestry = [];
  for (let i = 0; i < physicalCount; i++) {
    if (parent[i] === -1 || kinds[i] === 0) fail("missing physical coverage");
    if (kinds[i] === 1 && !containerKeys.has(`${i}:0`)) fail("missing element Children container");
    const owner = containers[parent[i]].owner;
    if (owner === 0xffffffff) ancestry.length = 0;
    else {
      while (ancestry.length && ancestry[ancestry.length - 1] !== owner) ancestry.pop();
      if (ancestry.length === 0) fail("physical preorder");
    }
    depths[i] = owner === 0xffffffff ? 1 : depths[owner] + 1;
    if (depths[i] > settings.maxDepth) fail("depth limit");
    ancestry.push(i);
  }
  for (let i = 1; i < containers.length; i++) if (kinds[containers[i].owner] !== 1) fail("container owner is not an element");
  for (const scaffold of scaffolds) if (kinds[scaffold.owner] !== 1) fail("scaffold owner is not an element");
  return { root, batch_bytes, mountFingerprint, expectedDigest, physicalCount, containers, logical, runs, bindings, scaffolds };
}

// Read one bounded protocol-facts item. Field order, lengths and uniqueness are
// checked before any lookup table is constructed or app code is initialized.
export function readProtocolFacts(bytes) {
  if (!(bytes instanceof Uint8Array) || bytes.length > 65536) throw new Error("protocol facts exceed 65536 bytes");
  const reader = (body) => {
    let at = 0;
    const need = (n) => { if (n > body.length - at) throw new Error("short protocol facts body"); };
    const r = {
      u8() { need(1); return body[at++]; },
      u32() { need(4); const value = new DataView(body.buffer, body.byteOffset + at, 4).getUint32(0, true); at += 4; return value; },
      bytes(n) { need(n); const value = body.subarray(at, at + n); at += n; return value; },
      name() { const n = r.u32(); if (n < 1 || n > 128) throw new Error("invalid protocol fact name length"); const value = utf8.decode(r.bytes(n)); if (value.includes("\0")) throw new Error("NUL in protocol fact name"); return value; },
      rows(read, maximum = 64) { const n = r.u32(); if (n > maximum || n > body.length - at) throw new Error("invalid protocol fact row count"); return Array.from({ length: n }, () => read(r)); },
      done() { if (at !== body.length) throw new Error("trailing protocol facts bytes"); },
    };
    return r;
  };
  const unique = (values, label) => {
    const seen = new Set();
    for (const value of values) {
      if (seen.has(value)) throw new Error(`duplicate protocol ${label} ${JSON.stringify(value)}`);
      seen.add(value);
    }
    return values;
  };
  const names = (r, maximum = 64) => unique(r.rows(s => s.name(), maximum), "names");
  const codeRows = r => r.rows(s => ({ code: s.u8(), name: s.name() }));
  const nestedRows = (r, key, nested) => r.rows(s => ({ [key]: s.u8(), name: s.name(), [nested]: names(s, 32) }));
  const fields = [
    ["ops", codeRows],
    ["kinds", r => nestedRows(r, "code", "events")],
    ["policies", r => r.rows(s => ({ bit: s.u32(), name: s.name() }))],
    ["properties", r => nestedRows(r, "index", "elements")],
    ["http_cache", codeRows], ["http_credentials", codeRows],
    ["namespaces", codeRows], ["text_entry_excluded", names], ["fault_classes", names], ["template_nodes", codeRows], ["child_containers", codeRows],
  ];
  const outer = reader(bytes), facts = {};
  for (let i = 0; i < fields.length; i += 1) {
    const tag = outer.u8();
    if (tag !== i + 1) throw new Error(`expected protocol fact field ${i + 1}, found ${tag}`);
    const body = reader(outer.bytes(outer.u32()));
    facts[fields[i][0]] = fields[i][1](body);
    body.done();
  }
  outer.done();
  for (const field of ["ops", "kinds", "policies", "properties", "http_cache", "http_credentials", "namespaces", "template_nodes", "child_containers"]) {
    const rows = facts[field];
    if (rows.length === 0) throw new Error(`empty protocol ${field}`);
    unique(rows.map(row => row.name), `${field} names`);
    const key = field === "policies" ? "bit" : field === "properties" ? "index" : "code";
    unique(rows.map(row => row[key]), `${field} codes`);
    if (field === "policies") {
      if (rows.some(row => row.bit === 0 || (row.bit & (row.bit - 1)) !== 0)) throw new Error("invalid protocol policy bit");
    } else if (rows.some((row, i) => row[key] !== i + (["namespaces", "child_containers"].includes(field) ? 0 : 1))) throw new Error(`non-dense protocol ${field}`);
  }
  if (facts.fault_classes.length === 0) throw new Error("empty protocol fault classes");
  return facts;
}

// Declaration sections are decoded inside their own lengths. A module that
// omitted or malformed a section is refused before any app code mounts.
export function readDeclarations(x) {
  x.boot_keys();
  const bytes = new Uint8Array(x.memory.buffer, x.cmd_ptr(), x.cmd_len());
  const out = { keys: [], sessionKeys: [], decls: [], media: [], zoneDays: 366 };
  const sections = [
    { tag: 2, name: "local-storage", read: (r) => {
      for (let n = r.u32(); n > 0; n -= 1) out.keys.push(r.str());
    } },
    { tag: 5, name: "ports", read: (r) => {
      const names = new Set();
      const count = r.u32();
      if (count > 64) throw new Error("more than 64 ports");
      for (let n = count; n > 0; n -= 1) {
        const name = r.str();
        const kind = r.u8(), delivery = r.u8(), bound = r.u32();
        if (utf8enc.encode(name).length < 1 || utf8enc.encode(name).length > 128 || names.has(name)) throw new Error("invalid or duplicate port name");
        if (![1, 2, 3].includes(kind) || (kind !== 3 ? delivery !== 0 || bound !== 0 : delivery === 1 ? bound < 1 || bound > 1024 : delivery !== 2 || bound !== 1)) throw new Error("invalid port shape or delivery");
        names.add(name);
        out.decls.push({ name, kind, delivery, bound });
      }
    } },
    { tag: 6, name: "media", read: (r) => {
      const count = r.u32();
      if (count > 32) throw new Error("more than 32 media queries");
      const queries = new Set();
      for (let n = count; n > 0; n -= 1) {
        const query = r.str(), length = utf8enc.encode(query).length;
        if (length < 1 || length > 256 || queries.has(query)) throw new Error("invalid or duplicate media query");
        queries.add(query); out.media.push(query);
      }
    } },
    { tag: 10, name: "time-zone", read: (r) => {
      out.zoneDays = r.u16();
      if (out.zoneDays > 7305) throw new Error("zone_days is greater than 7305");
    } },
    { tag: 11, name: "session-storage", read: r => {
      for (let n = r.u32(); n > 0; n -= 1) out.sessionKeys.push(r.str());
    } },
    { tag: 12, name: "protocol", read: r => { out.protocol = readProtocolFacts(r.bytes(r.remaining())); } },
  ];
  let at = 0;
  for (const section of sections) {
    const prefix = `contract: declaration section ${section.tag} (${section.name})`;
    try {
      if (at === bytes.length) throw new Error("is missing");
      const tag = bytes[at];
      if (tag !== section.tag) throw new Error(`expected tag ${section.tag}, found ${tag} (unknown, repeated or out of order)`);
      if (bytes.length - at < 5) throw new Error("has a short header");
      const len = new DataView(bytes.buffer, bytes.byteOffset + at + 1, 4).getUint32(0, true);
      at += 5;
      if (len > bytes.length - at) throw new Error("has a short body");
      const body = bytes.subarray(at, at + len);
      let pos = 0;
      const need = (n) => { if (n > body.length - pos) throw new Error("has a short body"); };
      const reader = {
        remaining: () => body.length - pos,
        bytes: n => { need(n); const value = body.subarray(pos, pos + n); pos += n; return value; },
        u8: () => { need(1); return body[pos++]; },
        u16: () => { need(2); const value = new DataView(body.buffer, body.byteOffset + pos, 2).getUint16(0, true); pos += 2; return value; },
        u32: () => { need(4); const value = new DataView(body.buffer, body.byteOffset + pos, 4).getUint32(0, true); pos += 4; return value; },
        str: () => { const n = reader.u32(); need(n); const value = readStr(body, pos, n); pos += n; return value; },
      };
      section.read(reader);
      if (pos !== body.length) throw new Error("has bytes left over");
      at += len;
    } catch (error) {
      throw new Error(`${prefix}: ${error.message}`);
    }
  }
  if (at !== bytes.length) throw new Error(`contract: declaration section ${bytes[at]} (unknown, repeated or out of order): unexpected section`);
  try { out.bindings = bindProtocolFacts(out.protocol); }
  catch (error) { throw new Error(`contract: declaration section 12 (protocol): ${error.message}`); }
  return out;
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
  const parts = [new Uint8Array([RES_PORT_ANSWER]), u32(text.length), text, u32(blobs.length)];
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
  const picture = markedPicture(root);
  if (picture) holdPicture(root);
  let runtime = null;
  try {
    const response = await fetch(wasmUrl);
    if (!response.ok) throw new Error(`failed to fetch ${wasmUrl}: ${response.status}`);
    const module = await WebAssembly.compile(await response.arrayBuffer());
    const instance = await WebAssembly.instantiate(module, pageImports(module));
    runtime = new RocEngineRuntime(instance.exports, root, { ...options, module });
    runtime.mount();
    return runtime;
  } catch (error) {
    if (picture) {
      if (runtime) {
        if (!runtime.poisoned) runtime.contain(error, "executor");
      } else pictureLoadFault(root, error, options.onFault);
    }
    throw error;
  }
}
