// Cold-frame transport only. No application key, state or reactive decision
// enters this module. Every allocation follows bounded, checked framing.
export const STARTUP_LIMITS = Object.freeze({ nodes: 262144, depth: 1024, annotations: 8 * 1024 * 1024, ranges: 64 });
const NODE = 'data-roc-node', CHILDREN = 'data-roc-children', FRAME = 'data-roc-frame';
const decoder = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true });
const fail = message => { throw new Error(`startup: ${message}`); };
const assert = (condition, message) => { if (!condition) fail(message); };

function binary(text, budget) {
  assert(typeof text === 'string', 'missing annotation');
  budget.bytes += text.length;
  assert(budget.bytes <= STARTUP_LIMITS.annotations, 'annotation resource limit');
  assert(text.length % 4 === 0, 'noncanonical Base64');
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  const padding = text.endsWith('==') ? 2 : text.endsWith('=') ? 1 : 0;
  const end = text.length - padding;
  for (let at = 0; at < end; at++) assert(alphabet.includes(text[at]), 'noncanonical Base64');
  assert(padding === 0 || end > 0 && (alphabet.indexOf(text[end - 1]) & (padding === 2 ? 15 : 3)) === 0, 'noncanonical Base64 unused bits');
  const raw = atob(text);
  const bytes = Uint8Array.from(raw, character => character.charCodeAt(0));
  return new Reader(bytes);
}
class Reader {
  constructor(bytes) { this.bytes = bytes; this.at = 0; this.view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength); }
  need(count) { assert(count <= this.bytes.length - this.at, 'truncated annotation'); }
  u8() { this.need(1); return this.bytes[this.at++]; }
  u32() { this.need(4); const value = this.view.getUint32(this.at, true); this.at += 4; return value; }
  count(minimum) { const value = this.u32(); assert(value <= STARTUP_LIMITS.nodes && value <= Math.floor((this.bytes.length - this.at) / minimum), 'annotation count exceeds framing or resource limit'); return value; }
  text() { const length = this.u32(); this.need(length); const value = decoder.decode(this.bytes.subarray(this.at, this.at + length)); this.at += length; return value; }
  presence() { const tag = this.u8(); assert(tag < 2, 'attribute presence'); return tag ? this.text() : null; }
  end() { assert(this.at === this.bytes.length, 'trailing annotation bytes'); }
}
function facts(reader, budget, kind) {
  const ordinal = reader.u32();
  const aliasCount = reader.count(4);
  assert(1 + aliasCount <= STARTUP_LIMITS.nodes - budget.bindings, 'logical binding resource limit');
  const aliases = Array.from({ length: aliasCount }, () => reader.u32());
  const holes = Array.from({ length: reader.count(4) }, () => reader.u32());
  budget.bindings += 1 + aliases.length;
  assert(budget.bindings <= STARTUP_LIMITS.nodes, 'logical binding resource limit');
  assert(aliases.every(id => id !== 0xffffffff), 'reserved effect address');
  return { ordinal, aliases, holes, kind, node: null };
}
function children(reader, budget) {
  return Array.from({ length: reader.count(5) }, () => {
    const kind = reader.u8();
    assert(kind >= 1 && kind <= 3, 'unknown logical node kind');
    if (kind === 1) return { kind, ordinal: reader.u32() };
    return { ...facts(reader, budget, kind), text: reader.text() };
  });
}
function childFacts(reader, budget) {
  assert(reader.u8() === 1, 'child annotation version');
  const flags = reader.u8(); assert(flags <= 3, 'child annotation flags');
  const ordinary = children(reader, budget);
  const contentFlag = reader.u8(); assert(contentFlag <= 1, 'content annotation flag');
  const content = contentFlag ? children(reader, budget) : null;
  const controlText = flags & 2 ? reader.text() : null;
  const overrides = Array.from({ length: reader.count(14) }, () => ({ namespace: reader.text(), prefix: reader.text(), local: reader.text(), logical: reader.presence(), physical: reader.presence() }));
  const remove = Array.from({ length: reader.count(4) }, () => reader.u32());
  reader.end();
  return { flags, ordinary, content, controlText, overrides, remove };
}

// Preflight the complete frame before creating, splitting or removing a node.
// Maps are keyed by supplied values; no supplied address sizes a dense array.
export class StartupFrame {
  constructor(root, expectedToken) {
    const marker = root.getAttributeNS(null, FRAME);
    assert(marker !== null && marker.length <= STARTUP_LIMITS.annotations, 'frame annotation resource limit');
    assert(typeof expectedToken === 'string' && /^[A-Za-z0-9_-]+$/.test(expectedToken), 'missing or invalid expected build token');
    const match = /^1:(0|[1-9][0-9]{0,9}):([A-Za-z0-9_-]+)$/.exec(marker ?? '');
    assert(match && Number(match[1]) < 0xffffffff && match[2] === expectedToken, 'frame/build compatibility');
    this.entry = Number(match[1]); this.root = root;
    this.ordinals = new Map(); this.aliases = new Map(); this.elements = []; this.gates = []; this.containers = [];
    this.endpointMaps = new Map(); this.used = new Set([0]); this.usedOrdinals = new Set([0]); this.byNode = new Map(); this.placement = new Map();
    const budget = { bytes: marker.length, bindings: 0 };
    const stack = [{ node: root, depth: 0 }]; let physical = 0;
    while (stack.length) {
      const { node, depth } = stack.pop();
      assert(++physical <= STARTUP_LIMITS.nodes && depth <= STARTUP_LIMITS.depth, 'physical frame resource limit');
      if (node.nodeType !== 1) continue;
      if (node !== root) assert(!node.hasAttributeNS(null, FRAME), 'nested frame marker');
      const reader = binary(node.getAttributeNS(null, NODE), budget);
      assert(reader.u8() === 1, 'node annotation version');
      const record = facts(reader, budget, 1); reader.end(); record.node = node;
      this.add(record);
      const child = childFacts(binary(node.getAttributeNS(null, CHILDREN), budget), budget);
      this.elements.push({ record, child });
      if (child.flags & 1) { assert(node.getAttributeNS(null, 'inert') === '', 'producer inert scaffold'); this.gates.push(node); }
      assert(child.content === null || (node.namespaceURI === 'http://www.w3.org/1999/xhtml' && node.localName === 'template'), 'content owner is not an HTML template');
      assert(child.content !== null || node.namespaceURI !== 'http://www.w3.org/1999/xhtml' || node.localName !== 'template' || node.content.childNodes.length === 0, 'unexpected intrinsic template content');
      const childCount = node.childNodes.length + (child.content === null ? 0 : node.content.childNodes.length);
      assert(childCount <= STARTUP_LIMITS.nodes - physical - stack.length, 'physical frame resource limit');
      const scaffoldIndices = new Set(child.remove);
      const descendants = [...Array.from(node.childNodes).filter((_, index) => !scaffoldIndices.has(index)), ...(child.content === null ? [] : node.content.childNodes)];
      physical += child.remove.length; assert(physical <= STARTUP_LIMITS.nodes, 'physical frame resource limit');
      for (let at = descendants.length - 1; at >= 0; at--) stack.push({ node: descendants[at], depth: depth + 1 });
    }
    assert(this.ordinals.get(0)?.node === root, 'mount ordinal');
    for (const { record, child } of this.elements) {
      const element = record.node;
      for (const override of child.overrides) assert(element.getAttributeNS(override.namespace || null, override.local) === override.physical, 'attribute scaffold assertion');
      this.plan(element, child.ordinary, child.controlText, child.remove);
      if (child.content !== null) this.plan(element.content, child.content, null, []);
    }
    assert(this.parented.size === this.ordinals.size - 1, 'unowned logical binding');
    for (const record of this.ordinals.values()) for (const target of record.holes) assert(this.ordinals.has(target), 'missing row-hole ordinal');
    this.selection = captureSelection(root.ownerDocument);
  }
  add(record) {
    assert(!this.ordinals.has(record.ordinal), 'duplicate logical ordinal');
    this.ordinals.set(record.ordinal, record);
    for (const alias of record.aliases) { assert(!this.aliases.has(alias), 'duplicate engine address'); this.aliases.set(alias, record); }
  }
  plan(container, records, controlText, remove) {
    this.parented ??= new Set();
    const physical = Array.from(container.childNodes);
    const removed = new Set(remove);
    assert(removed.size === remove.length, 'duplicate scaffold child');
    for (const index of removed) {
      const node = physical[index];
      assert(node?.nodeType === 1 && node.namespaceURI === 'http://www.w3.org/1999/xhtml' && node.localName === 'option' && node.getAttributeNS(null, 'hidden') === '' && node.getAttributeNS(null, 'value') === '' && node.getAttributeNS(null, 'selected') === '' && node.childNodes.length === 0 && node.attributes.length === 3, 'selection scaffold assertion');
    }
    const actual = physical.filter((_, index) => !removed.has(index));
    if (controlText !== null) assert(actual.length === (controlText ? 1 : 0) && (!controlText || actual[0].nodeType === 3 && actual[0].data === controlText), 'control text scaffold assertion');
    let at = 0; const groups = [];
    for (let index = 0; index < records.length;) {
      let record = records[index];
      if (record.kind === 1) { record = this.ordinals.get(record.ordinal); assert(record?.kind === 1, 'missing element ordinal'); records[index] = record; }
      assert(record.ordinal !== 0 && !this.parented.has(record.ordinal), 'logical ownership or cycle'); this.parented.add(record.ordinal);
      record.container = container; record.position = index;
      if (record.kind === 2) {
        const run = [record]; this.add(record); index++;
        while (records[index]?.kind === 2) { const part = records[index++]; assert(!this.parented.has(part.ordinal), 'duplicate text ordinal'); this.parented.add(part.ordinal); part.container = container; part.position = index - 1; this.add(part); run.push(part); }
        const text = run.map(part => part.text).join('');
        const node = controlText === null && text ? actual[at++] : null;
        assert(controlText !== null || !text || node?.nodeType === 3 && node.data === text, 'logical text assertion');
        groups.push({ kind: 2, run, node, before: controlText === null ? actual[at] ?? null : null });
      } else {
        if (record.kind === 3) this.add(record);
        const node = controlText === null ? actual[at++] : null;
        assert(controlText !== null || (record.kind === 1 ? node === record.node : node?.nodeType === 8 && node.data === record.text), 'child ownership or comment assertion');
        if (record.kind === 3) record.node = node;
        assert(controlText === null || record.kind !== 1, 'element in control-text scaffold');
        groups.push({ kind: record.kind, record, node }); index++;
      }
    }
    assert(controlText !== null || at === actual.length, 'unexpected physical child');
    this.containers.push({ container, groups, physical, removed, controlText });
  }
  normalize() {
    const document = this.root.ownerDocument;
    for (const { record, child } of this.elements) for (const override of child.overrides) {
      if (override.logical === null) record.node.removeAttributeNS(override.namespace || null, override.local);
      else record.node.setAttributeNS(override.namespace || null, override.prefix ? `${override.prefix}:${override.local}` : override.local, override.logical);
    }
    for (const plan of this.containers) {
      const { container, groups, physical, removed, controlText } = plan;
      const boundaries = new Map(); let count = 0;
      if (controlText !== null) for (const node of physical) node.remove();
      for (const group of groups) {
        if (group.kind === 2) {
          const parts = []; let remaining = group.node;
          const before = remaining?.nextSibling ?? group.before;
          for (const record of group.run) {
            const units = record.text.length;
            let node;
            if (remaining && units > 0) { node = remaining; remaining = units < node.length ? node.splitText(units) : null; }
            else { node = document.createTextNode(record.text); container.insertBefore(node, remaining ?? before); }
            record.node = node; parts.push({ node, units }); count++;
          }
          if (group.node) { boundaries.set(group.node, { start: count - parts.length, end: count }); this.endpointMaps.set(group.node, parts); }
        } else {
          if (controlText !== null) { group.record.node = document.createComment(group.record.text); container.appendChild(group.record.node); }
          boundaries.set(group.node, { start: count, end: count + 1 }); count++;
        }
      }
      const offsets = [0]; let previous = 0;
      for (const node of physical) { const boundary = boundaries.get(node); if (boundary) previous = boundary.end; offsets.push(previous); }
      this.endpointMaps.set(container, offsets);
      for (const index of removed) physical[index].remove();
    }
    for (const record of this.ordinals.values()) this.byNode.set(record.node, record);
  }
  expectAliases(expected) {
    for (const id of this.aliases.keys()) assert(expected.has(id), `unexpected engine address ${id}`);
    for (const id of expected) assert(id === 0 || this.aliases.has(id), `missing engine address ${id}`);
  }
  bind(id, kind) { const record = this.aliases.get(id); assert(record && record.kind === kind && !this.used.has(id), `unexpected binding ${id}`); this.used.add(id); this.usedOrdinals.add(record.ordinal); return record; }
  consumeSkeleton(node) {
    const record = this.byNode.get(node); assert(record, 'template node has no logical ordinal'); this.usedOrdinals.add(record.ordinal);
  }
  seedPlacement(container, last) {
    if (!last) return;
    const record = this.byNode.get(last); assert(record?.container === container, 'template container assertion');
    let cursors = this.placement.get(container); if (!cursors) { cursors = new Map(); this.placement.set(container, cursors); }
    cursors.set(null, record.position);
  }
  assertPlaced(node, container, before) {
    const record = this.byNode.get(node); assert(record?.container === container && node.parentNode === container, 'binding parent');
    if (before) { const anchor = this.byNode.get(before); assert(anchor?.container === container && anchor.position > record.position, 'binding insertion point'); }
    let cursors = this.placement.get(container); if (!cursors) { cursors = new Map(); this.placement.set(container, cursors); }
    const previous = cursors.get(before); assert(previous === undefined || previous < record.position, 'cold construction order');
    cursors.set(before, record.position);
  }
  finish() {
    assert([...this.aliases.keys()].every(id => this.used.has(id)), 'missing expected command binding');
    assert(this.usedOrdinals.size === this.ordinals.size, 'unexpected unbound logical node');
    restoreSelection(this.selection, this.endpointMaps);
    for (const node of this.gates) node.removeAttributeNS(null, 'inert');
    // Transport lives only through the cold batch. Ordinary runtime id tables
    // now own the nodes, with no update-path annotation index.
    this.ordinals.clear(); this.aliases.clear(); this.elements.length = 0; this.containers.length = 0; this.gates.length = 0; this.endpointMaps.clear(); this.byNode.clear(); this.placement.clear(); this.used.clear(); this.usedOrdinals.clear(); this.parented.clear(); this.selection = null;
  }
}
function captureSelection(document) {
  const selection = document.getSelection?.(); if (!selection) return null;
  assert(selection.rangeCount <= STARTUP_LIMITS.ranges, 'selection range resource limit');
  const ranges = [];
  for (let at = 0; at < selection.rangeCount; at++) { const range = selection.getRangeAt(at); ranges.push({ start: [range.startContainer, range.startOffset], end: [range.endContainer, range.endOffset] }); }
  return { selection, document, ranges, anchor: [selection.anchorNode, selection.anchorOffset], focus: [selection.focusNode, selection.focusOffset] };
}
function restoreSelection(saved, maps) {
  if (!saved) return;
  const endpoint = ([node, offset]) => {
    const mapping = maps.get(node); if (!mapping) return [node, offset];
    if (typeof mapping[0] === 'number') return [node, mapping[offset]];
    for (const part of mapping) { if (offset <= part.units) return [part.node, offset]; offset -= part.units; }
    const last = mapping.at(-1); return [last.node, last.units];
  };
  const { selection, document, ranges } = saved;
  selection.removeAllRanges();
  for (const bounds of ranges) { const range = document.createRange(); range.setStart(...endpoint(bounds.start)); range.setEnd(...endpoint(bounds.end)); selection.addRange(range); }
  if (ranges.length === 1 && selection.setBaseAndExtent && saved.anchor[0]) selection.setBaseAndExtent(...endpoint(saved.anchor), ...endpoint(saved.focus));
}
