// Browser runtime for the Phase 1 pure-Roc-engine spike (platform-roc).
//
// The engine decides everything; this file only applies its command bytes to
// the DOM and routes clicks back as (node id, handler number). Commands are
// read straight out of Wasm linear memory after each call (no per-command
// boundary calls). The views are re-created per apply, so memory growth during
// a call can never leave a stale view.
//
// Encoding: see platform-roc/Engine.roc (command stream header).

const OP_INST = 1;
const OP_TEXT = 2;
const OP_CLASS = 3;
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
const HOLE_CLASS = 2;
const HOLE_CLICK = 3;

export async function instantiateEngineBytes(bytes) {
  return WebAssembly.instantiate(bytes, { env: {} });
}

export async function instantiateEngineWasm(url) {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`failed to fetch ${url}: ${response.status}`);
  return instantiateEngineBytes(await response.arrayBuffer());
}

const utf8 = new TextDecoder();

// Short ASCII strings dominate (labels, ids); decoding them without a
// TextDecoder call or a subarray view is markedly cheaper in V8.
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
    const site = node >>> 24;
    if (site === 0) return node === 0 ? this.root : this.statics[node];
    return this.sites[site][(node & 0xffffff) - 1];
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
        el.setAttribute(name, str());
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
      const hole = { kind, path, names: null, handler: 0 };
      if (kind === HOLE_CLASS) {
        const n = u8[at++];
        hole.names = [];
        for (let k = 0; k < n; k += 1) hole.names.push(str());
      } else if (kind === HOLE_CLICK) {
        hole.handler = u8[at++];
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
          const tpl = this.templates[dv.getUint32(at + 8, true)];
          at += 12;
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
            } else if (hole.kind === HOLE_CLASS) {
              const c = u8[at];
              at += 1;
              if (c !== 0) target.className = hole.names[c];
            } else {
              target.__rh = hole.handler;
            }
          }
          this.lookup(parent).appendChild(el);
          const site = node >>> 24;
          (this.sites[site] ??= [])[(node & 0xffffff) - 1] = el;
          break;
        }
        case OP_TEXT: {
          const node = dv.getUint32(at, true);
          const hole = this.templates[node >>> 24].holes[u8[at + 4]];
          const n = dv.getUint32(at + 5, true);
          walk(this.lookup(node), hole.path).nodeValue = readStr(u8, at + 9, n);
          at += 9 + n;
          break;
        }
        case OP_CLASS: {
          const node = dv.getUint32(at, true);
          const hole = this.templates[node >>> 24].holes[u8[at + 4]];
          walk(this.lookup(node), hole.path).className = hole.names[u8[at + 5]];
          at += 6;
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
          this.sites[node >>> 24][(node & 0xffffff) - 1] = undefined;
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
          this.sites[tpl] ??= [];
          at += 8 + n;
          break;
        }
        case OP_ELEM: {
          const node = dv.getUint32(at, true);
          const parent = dv.getUint32(at + 4, true);
          const n = dv.getUint32(at + 8, true);
          const el = doc.createElement(readStr(u8, at + 12, n));
          at += 12 + n;
          this.lookup(parent).appendChild(el);
          this.statics[node] = el;
          break;
        }
        case OP_ATTR: {
          const el = this.statics[dv.getUint32(at, true)];
          const n = dv.getUint32(at + 4, true);
          const name = readStr(u8, at + 8, n);
          at += 8 + n;
          const m = dv.getUint32(at, true);
          el.setAttribute(name, readStr(u8, at + 4, m));
          at += 4 + m;
          break;
        }
        case OP_TEXTNODE: {
          const node = dv.getUint32(at, true);
          const parent = dv.getUint32(at + 4, true);
          const n = dv.getUint32(at + 8, true);
          const text = doc.createTextNode(readStr(u8, at + 12, n));
          at += 12 + n;
          this.lookup(parent).appendChild(text);
          this.statics[node] = text;
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
          el.textContent = readStr(u8, at + 8, n);
          at += 8 + n;
          break;
        }
        default:
          throw new Error(`unknown engine command ${op} at byte ${at - 1}`);
      }
    }
    return len;
  }

  // Attribution helper: decode the pending command bytes exactly as `apply`
  // does (strings included) but touch no DOM. Returns a checksum so the work
  // cannot be optimised away. Only meaningful right after an event.
  scan() {
    const x = this.x;
    const len = x.cmd_len();
    if (len === 0) return 0;
    const buffer = x.memory.buffer;
    const ptr = x.cmd_ptr();
    const u8 = new Uint8Array(buffer, ptr, len);
    const dv = new DataView(buffer, ptr, len);
    let at = 0;
    let sum = 0;
    const str = (p) => {
      const n = dv.getUint32(p, true);
      sum += readStr(u8, p + 4, n).length;
      return p + 4 + n;
    };
    while (at < len) {
      const op = u8[at];
      at += 1;
      switch (op) {
        case OP_INST: {
          const tpl = this.templates[dv.getUint32(at + 8, true)];
          sum += dv.getUint32(at, true) + dv.getUint32(at + 4, true);
          at += 12;
          for (const hole of tpl.holes) {
            if (hole.kind === HOLE_TEXT) at = str(at);
            else if (hole.kind === HOLE_CLASS) { sum += u8[at]; at += 1; }
          }
          break;
        }
        case OP_TEXT: at = str(at + 5); break;
        case OP_CLASS: at += 6; break;
        case OP_MOVE: at += 8; break;
        case OP_REMOVE: at += 4; break;
        case OP_CLEAR: at += 8; break;
        case OP_TEMPLATE: at += 8 + dv.getUint32(at + 4, true); break;
        case OP_ELEM: at = str(at + 8); break;
        case OP_ATTR: at = str(str(at + 4)); break;
        case OP_TEXTNODE: at = str(at + 8); break;
        case OP_LISTEN: at += 8; break;
        case OP_SETTEXT: at = str(at + 4); break;
        default: throw new Error(`unknown engine command ${op}`);
      }
    }
    return sum;
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
