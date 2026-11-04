// Browser runtime for the pure Roc engine (platform/Engine.roc). The engine
// decides everything; this file applies its command bytes to the DOM and
// routes DOM events back as (node id, handler number, payload bytes).
// Commands are read straight out of Wasm linear memory after each call; views
// are re-created per apply (a call may grow memory).
//
// Encoding: see the command stream header in platform/Engine.roc.
//
// Event payloads (UTF-8, staged with `payload_reserve` and moved into Roc by
// `event`): click/submit "", input: the target's value, change: "true"/"false"
// for a checkbox or radio, else the target's value, keydown/keyup: the key.
//
// Effects (see "Effects" in Engine.roc): the engine emits FX requests with
// ids, CANCEL, NAV, STORE and TITLE commands. They are collected while a
// batch is applied and performed only after the whole batch is applied.
// Each awaited result comes back as its own event on FX_NODE (one turn, in
// completion order). In manual mode (options.manualEffects) HTTP requests
// and timers wait in `pending` until runEffect() answers them; the engine,
// not this file, decides staleness: a result for a cancelled id is never
// sent because CANCEL forgets it here, and anything late is dropped by the
// engine and counted.
//
// Handler event names may carry a policy suffix: "click:prevent" listens to
// "click" and calls preventDefault when it dispatches (in-app links, forms).
//
// Attribute values: "" removes the attribute. `value` and `checked` are set
// as properties (the live control state), boolean attributes (disabled,
// selected, readonly, required, hidden, multiple) are present for any value
// other than "" and "false".

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

// Effect results are events on this node; the handler number is the id.
const FX_NODE = 0xffffffff;
const RES_HTTP = 1;
const RES_NETWORK = 2;
const RES_VALUE = 3;
const RES_MISSING = 4;
const RES_FIRED = 5;
const RES_LOCATION = 6;

const HOLE_TEXT = 1;
const HOLE_ATTR = 2;
const HOLE_CLICK = 3;
const HOLE_BIND = 4;

const SITE_SHIFT = 20;
const SLOT_MASK = 0xfffff;

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

function setAttr(el, name, value) {
  if (name === "class" && el.namespaceURI === SVG_NS) {
    if (value === "") el.removeAttribute("class");
    else el.setAttribute("class", value);
  } else if (name === "class") {
    el.className = value;
  } else if (name === "value") {
    if (el.value !== value) el.value = value;
    if (el.tagName === "SELECT") el.__v = value;
    if (value === "") el.removeAttribute("value");
    else el.setAttribute("value", value);
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

function payloadOf(event) {
  const t = event.target;
  switch (event.type) {
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

function httpResult(status, body) {
  return concat([new Uint8Array([RES_HTTP, status & 0xff, (status >>> 8) & 0xff]), utf8enc.encode(body)]);
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
    this.onEvent = (event) => this.handle(event);
    this.timing = options.timing ?? null;
    this.busy = false;
    this.queue = [];
    this.manual = options.manualEffects ?? false;
    this.fxOut = [];
    // id -> { kind, req, cancel } for every effect this runtime holds.
    this.live = new Map();
    // Manual mode: awaited non-subscription requests in issue order.
    this.issued = [];
    this.win = options.window ?? globalThis.window;
    this.storage = options.storage ?? (() => {
      try {
        return this.win.localStorage;
      } catch (_) {
        return null;
      }
    })();
  }

  // Boot: read the app's declared storage keys, stage the URL and their
  // values, then mount.
  mount() {
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
    const pairs = [];
    for (const k of keys) {
      let v = null;
      try {
        v = this.storage ? this.storage.getItem(k) : null;
      } catch (_) {
        v = null;
      }
      if (v !== null) pairs.push([k, v]);
    }
    const loc = this.win ? this.win.location : null;
    const url = loc ? loc.pathname + loc.search + loc.hash : "";
    const parts = [encStr(url), u32(pairs.length)];
    for (const [k, v] of pairs) parts.push(encStr(k), encStr(v));
    this.stage(concat(parts));
    this.busy = true;
    try {
      x.init();
      this.apply();
    } finally {
      this.busy = false;
    }
    this.drainQueue();
  }

  unmount() {
    for (const id of [...this.live.keys()]) this.cancel(id);
    for (const [type, fn] of this.listening) this.root.removeEventListener(type, fn);
    this.listening.clear();
    this.x.drop();
    this.root.textContent = "";
    this.statics = [];
    this.sites = [];
    this.templates = [];
  }

  // One delegated listener per event type, added the first time a LISTEN
  // command or template hole names that type.
  listen(type) {
    if (this.listening.has(type)) return;
    this.listening.set(type, this.onEvent);
    this.root.addEventListener(type, this.onEvent);
  }

  // The nearest handler for this event type walking up from the target
  // (bubbling), then the nearest node carrying an engine id.
  handle(event) {
    const type = event.type;
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
        this.dispatch(node.__rn, handler, payloadOf(event));
        return;
      }
      node = node.parentNode;
    }
  }

  // Events raised while a batch is being applied (or while Wasm runs) are
  // queued and delivered in order after it; they never re-enter.
  dispatch(node, handler, payload) {
    if (this.busy) {
      this.queue.push([node, handler, payload]);
      return;
    }
    this.busy = true;
    try {
      this.deliver(node, handler, payload);
    } finally {
      this.busy = false;
    }
    this.drainQueue();
  }

  drainQueue() {
    while (!this.busy && this.queue.length > 0) {
      const [n, h, p] = this.queue.shift();
      this.busy = true;
      try {
        this.deliver(n, h, p);
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

  lookup(node) {
    const site = node >>> SITE_SHIFT;
    if (site === 0) return node === 0 ? this.root : this.statics[node];
    return this.sites[site][(node & SLOT_MASK) - 1];
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
          this.sites[site][(node & SLOT_MASK) - 1] = el;
          break;
        }
        case OP_TEXT:
        case OP_HATTR: {
          const node = dv.getUint32(at, true);
          const hole = this.templates[node >>> SITE_SHIFT].holes[u8[at + 4]];
          const n = dv.getUint32(at + 5, true);
          const target = this.lookup(node).__ht[u8[at + 4]];
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
          const site = node >>> SITE_SHIFT;
          if (site === 0) this.statics[node] = undefined;
          else this.sites[site][(node & SLOT_MASK) - 1] = undefined;
          at += 4;
          break;
        }
        case OP_CLEAR: {
          const parent = this.lookup(dv.getUint32(at, true));
          this.sites[dv.getUint32(at + 4, true)] = [];
          parent.textContent = "";
          at += 8;
          break;
        }
        case OP_TEMPLATE: {
          const tpl = dv.getUint32(at, true);
          const n = dv.getUint32(at + 4, true);
          this.templates[tpl] = this.parseTemplate(u8, dv, at + 8, n);
          this.sites[tpl] = [];
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
            this.fxOut.push({ op: "http", id, method, url, headers, body });
          } else if (kind === 2) {
            this.fxOut.push({ op: "get", id, key: str() });
          } else if (kind === 3 || kind === 4) {
            this.fxOut.push({ op: kind === 3 ? "timer" : "interval", id, ms: dv.getUint32(at, true) });
            at += 4;
          } else if (kind === 5) {
            this.fxOut.push({ op: "popstate", id });
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
      case "interval": {
        const h = setInterval(() => this.result(fx.id, new Uint8Array([RES_FIRED])), fx.ms);
        this.live.set(fx.id, { kind: "sub", cancel: () => clearInterval(h) });
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
        const ctl = new AbortController();
        this.live.set(fx.id, { kind: "http", req: fx, cancel: () => ctl.abort() });
        const init = { method: fx.method, headers: fx.headers, signal: ctl.signal };
        if (fx.method !== "GET" && fx.method !== "HEAD" && fx.body !== "") init.body = fx.body;
        (this.fetch ?? globalThis.fetch)(fx.url, init)
          .then(async (r) => {
            const body = await r.text();
            if (!this.live.has(fx.id)) return;
            this.live.delete(fx.id);
            this.result(fx.id, httpResult(r.status, body));
          })
          .catch((e) => {
            if (!this.live.has(fx.id)) return; // cancelled: the engine forgot it
            this.live.delete(fx.id);
            this.result(fx.id, concat([new Uint8Array([RES_NETWORK]), utf8enc.encode(String(e))]));
          });
        return;
      }
      default:
        throw new Error(`unknown effect ${fx.op}`);
    }
  }

  cancel(id) {
    const e = this.live.get(id);
    if (e === undefined) return;
    this.live.delete(id);
    e.cancel();
  }

  // Manual mode: awaited requests still pending, in issue order.
  pendingEffects() {
    return this.issued.filter((id) => this.live.has(id)).map((id) => this.live.get(id).req ?? { id });
  }

  // Manual mode: answer pending request `id` with an HTTP response
  // ({ status, body }), a network failure ({ network: message }) or a timer
  // tick ({}). Returns false when `id` is not pending (cancelled/answered).
  runEffect(id, answer) {
    if (!this.live.has(id)) return false;
    this.live.delete(id);
    if (answer.network !== undefined) this.result(id, concat([new Uint8Array([RES_NETWORK]), utf8enc.encode(answer.network)]));
    else if (answer.status !== undefined) this.result(id, httpResult(answer.status, answer.body ?? ""));
    else this.result(id, new Uint8Array([RES_FIRED]));
    return true;
  }

  // Deliver a result for an arbitrary id, bypassing this runtime's own
  // bookkeeping (stale-result tests: the engine must drop and count it).
  injectResult(id, status, body) {
    this.result(id, httpResult(status, body));
  }

  liveRows(site = 1) {
    return (this.sites[site] ?? []).reduce((n, el) => n + (el === undefined ? 0 : 1), 0);
  }
}

export async function mountRocEngineApp({ wasmUrl, root, ...options }) {
  const { instance } = await instantiateEngineWasm(wasmUrl);
  const runtime = new RocEngineRuntime(instance.exports, root, options);
  runtime.mount();
  return runtime;
}
