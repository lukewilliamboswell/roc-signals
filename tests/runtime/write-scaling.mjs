// One unmeasured warm-up before each group of 21 sparse writes; the median
// excludes fill/setup costs. Keyed samples release one earlier row, O(J_previous = 1).
// A self-comparison at two table sizes catches copies that allocation counts miss.
// Build this fixture with --opt=dev: optimized site storage is tracked upstream.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const file = process.argv[2];
assert.ok(file, "usage: node tests/runtime/write-scaling.mjs DEVELOPMENT.wasm");
const module = await WebAssembly.compile(await readFile(file));
const imports = {};
for (const entry of WebAssembly.Module.imports(module)) {
  assert.equal(entry.kind, "function", `unexpected import ${entry.module}.${entry.name}`);
  (imports[entry.module] ??= {})[entry.name] = () => { throw new Error(`unexpected hosted effect ${entry.name}`); };
}
const wasm = (await WebAssembly.instantiate(module, imports)).exports;
const text = new TextDecoder("utf-8", { fatal: true });
const labels = new Map(), listeners = new Map(), templates = new Map(), content = new Map();
function batch() {
  assert.equal(wasm.fault(), 0, "engine fault");
  // Every call may grow memory: retain no view across calls.
  const bytes = new DataView(wasm.memory.buffer, wasm.cmd_ptr(), wasm.cmd_len());
  if (!bytes.byteLength) return;
  let at = 0;
  const u8 = () => bytes.getUint8(at++);
  const u32 = () => { const value = bytes.getUint32(at, true); at += 4; return value; };
  const str = () => { const length = u32(); const value = text.decode(new Uint8Array(bytes.buffer, bytes.byteOffset + at, length)); at += length; return value; };
  // Protocol18 carries resolved namespace/prefix/local identity. This fixture
  // emits only HTML elements, unnamespaced attributes and ordinary children.
  const name = (namespace) => { assert.equal(u8(), namespace); assert.equal(str(), ""); return str(); };
  assert.equal(u8(), 0, "fixture batches are unmarked");
  while (at < bytes.byteLength) {
    const op = u8();
    if (op === 8) { u32(); u32(); u32(); name(0); assert.equal(u8(), 0); }
    else if (op === 9) { const node = u32(), attribute = name(3); assert.equal(u8(), 1); const value = str(); if (attribute === "aria-label") labels.set(value, node); }
    else if (op === 10) { const node = u32(), parent = u32(); u32(); const value = str(); content.set(node, value); if (listeners.has(parent)) labels.set(value, parent); }
    else if (op === 11) { const node = u32(), handler = u32(); assert.equal(str(), "click"); assert.equal(u8(), 1); assert.equal(u32(), 0); listeners.set(node, handler); }
    else if (op === 12) { content.set(u32(), str()); }
    else if (op === 7) { const id = u32(), length = u32(); templates.set(id, length); at += length; }
    else if (op === 1) { const node = u32(); u32(); u32(); assert.ok(templates.has(u32())); content.set(node, str()); }
    else if (op === 2) { const node = u32(); assert.equal(u8(), 0); content.set(node, str()); }
    else if (op === 5) { content.delete(u32()); }
    else if (op === 6) { u32(); u32(); }
    else if (op === 4) { u32(); u32(); }
    else throw new Error(`unexpected fixture opcode ${op}`);
  }
  assert.equal(at, bytes.byteLength, "complete command framing");
}
function click(label, measured = false) {
  const node = labels.get(label);
  assert.ok(node !== undefined && listeners.has(node), `missing actionable ${label}`);
  if (measured) wasm.reset_metrics();
  wasm.event(node, listeners.get(node));
  const bytes = Number(wasm.metric(2)), allocations = Number(wasm.metric(0));
  batch();
  return { bytes, allocations };
}
function median(label) {
  const samples = Array.from({ length: 21 }, () => click(label, true));
  return { bytes: samples.map(x => x.bytes).sort((a,b) => a-b)[10], allocations: samples.map(x => x.allocations).sort((a,b) => a-b)[10] };
}
wasm.init(); batch();
const results = [];
for (const size of [1000, 10000]) {
  click(`Fill ${size}`);
  assert.ok([...content.values()].includes("a long row name 7"));
  click("Rename"); // Establish a one-key previous record outside measurement.
  const keyed = median("Rename");
  click("Count");
  const small = median("Count");
  assert.ok([...content.values()].includes(`Count ${size === 1000 ? 22 : 44}`));
  assert.ok([...content.values()].includes(`a long row name 7${"!".repeat(22)}`));
  results.push({ size, keyed, small });
}
try {
  for (const kind of ["keyed", "small"]) {
    const [low, high] = results.map(result => result[kind].bytes);
    assert.ok(high <= low + 1024, `${kind} write allocates ${low} B at 1000 rows and ${high} B at 10000 (allowed: ${low + 1024})`);
  }
  console.log(JSON.stringify({ development: true, samples: 21, results }));
} finally {
  wasm.drop();
  assert.equal(Number(wasm.metric(4)), 0, "no live allocations after drop");
  assert.equal(Number(wasm.metric(5)), 0, "no live bytes after drop");
}
