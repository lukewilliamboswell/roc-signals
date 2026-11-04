// Browser runtime for the Phase 2 unified Roc engine (representation D with a
// column-store `each`). Derived from the Phase 1 runtime: the engine decides
// everything; this file only applies its command bytes to the DOM and routes
// clicks back as (node id, handler number). Commands are read straight out of
// Wasm linear memory after each call; views are re-created per apply.
//
// Encoding: see p2each/src/Engine.roc (command stream header).

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

function setAttr(el, name, value) {
  if (name === "class") el.className = value;
  else el.setAttribute(name, value);
}

export class RocEngineRuntime {
  constructor(exports, root, options = {}) {
    this.x = exports;
    this.root = root;
    this.doc = options.document ?? globalThis.document;
    this.statics = [];
    this.sites = [];
    this.templates = [];
    this.onClick = (event) => this.click(event);
    this.timing = options.timing ?? null;
  }

  mount() {
    this.root.addEventListener("click", this.onClick);
    this.x.init();
    this.apply();
  }

  unmount() {
    this.root.removeEventListener("click", this.onClick);
    this.x.drop();
    this.root.textContent = "";
    this.statics = [];
    this.sites = [];
    this.templates = [];
  }

  click(event) {
    let node = event.target;
    let handler = -1;
    while (node && node !== this.root) {
      if (handler < 0 && node.__rh !== undefined) handler = node.__rh;
      if (node.__rn !== undefined) {
        if (handler >= 0) this.dispatch(node.__rn, handler);
        return;
      }
      node = node.parentNode;
    }
  }

  dispatch(node, handler) {
    const t = this.timing;
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
      else if (kind === HOLE_CLICK) hole.handler = u8[at++];
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
          for (let i = 0; i < holes.length; i += 1) {
            const hole = holes[i];
            const target = walk(el, hole.path);
            if (hole.kind === HOLE_TEXT) {
              const n = dv.getUint32(at, true);
              target.nodeValue = readStr(u8, at + 4, n);
              at += 4 + n;
            } else if (hole.kind === HOLE_ATTR) {
              const n = dv.getUint32(at, true);
              if (n !== 0 || hole.name !== "class") setAttr(target, hole.name, readStr(u8, at + 4, n));
              at += 4 + n;
            } else if (hole.kind === HOLE_CLICK) {
              target.__rh = hole.handler;
            } else {
              this.statics[dv.getUint32(at, true)] = target;
              at += 4;
            }
          }
          this.place(el, parent, before);
          this.sites[site][(node & SLOT_MASK) - 1] = el;
          break;
        }
        case OP_TEXT:
        case OP_HATTR: {
          const node = dv.getUint32(at, true);
          const hole = this.templates[node >>> SITE_SHIFT].holes[u8[at + 4]];
          const n = dv.getUint32(at + 5, true);
          const target = walk(this.lookup(node), hole.path);
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
          el.__rn = node;
          el.__rh = dv.getUint32(at + 4, true);
          at += 8;
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
