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

function setAttr(el, name, value) {
  if (name === "class") {
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
  }

  mount() {
    this.listen("click");
    this.x.init();
    this.apply();
  }

  unmount() {
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
    let handler = -1;
    while (node && node !== this.root) {
      if (handler < 0 && node.__h !== undefined) {
        const h = node.__h[type];
        if (h !== undefined) handler = h;
      }
      if (node.__rn !== undefined && handler >= 0) {
        if (type === "submit") event.preventDefault();
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
      while (this.queue.length > 0) {
        const [n, h, p] = this.queue.shift();
        this.deliver(n, h, p);
      }
    } finally {
      this.busy = false;
    }
  }

  stage(payload) {
    if (payload === "") {
      this.x.payload_reserve(0);
      return;
    }
    const bytes = utf8enc.encode(payload);
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
    const node = () => {
      const kind = u8[at++];
      if (kind === 2) return doc.createTextNode(str());
      const el = doc.createElement(str());
      const attrs = u8[at++];
      for (let i = 0; i < attrs; i += 1) {
        const name = str();
        setAttr(el, name, str());
      }
      const children = u8[at++];
      for (let i = 0; i < children; i += 1) el.appendChild(node());
      return el;
    };
    const root = node();
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
        this.listen(hole.name);
      }
      holes.push(hole);
    }
    if (at !== start + len) throw new Error("template length mismatch");
    return { root, holes };
  }

  // Returns the number of command bytes applied.
  apply() {
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
              target.__h[hole.name] = hole.handler;
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
          const el = op === OP_ELEM ? doc.createElement(s) : doc.createTextNode(s);
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
          el.__h[type] = dv.getUint32(at + 4, true);
          this.listen(type);
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
        default:
          throw new Error(`unknown engine command ${op} at byte ${at - 1}`);
      }
    }
    return len;
  }

  liveRows(site = 1) {
    return (this.sites[site] ?? []).reduce((n, el) => n + (el === undefined ? 0 : 1), 0);
  }
}

export async function mountRocEngineApp({ wasmUrl, root }) {
  const { instance } = await instantiateEngineWasm(wasmUrl);
  const runtime = new RocEngineRuntime(instance.exports, root);
  runtime.mount();
  return runtime;
}
