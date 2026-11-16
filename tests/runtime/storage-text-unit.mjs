// Storage is written by other tabs, other versions of the app and other
// scripts on the origin, so a value Roc text cannot hold is external input,
// never a fault (design.md, "Storage availability"). At boot such a value
// makes its service unavailable, exactly as a read that throws does; a later
// read answers Missing, as an absent service or a throwing read does. Only
// the host exports, the root and the storage services are fake.
import assert from "node:assert/strict";
import { RocEngineRuntime, PROTOCOL_VERSION } from "../../platform/runtime.mjs";
import { protocolFixtureSection } from "../browser/protocol-fixture.mjs";

const check = async (name, test) => {
  try { await test(); console.log(`ok   ${name}`); }
  catch (error) { console.log(`FAIL ${name}: ${error.message.split("\n")[0]}`); process.exitCode = 1; }
};
const encoder = new TextEncoder();
const word = n => [n & 255, (n >>> 8) & 255, (n >>> 16) & 255, n >>> 24];
const part = (tag, bytes) => [tag, ...word(bytes.length), ...bytes];
const keys = list => [...word(list.length), ...list.flatMap(key => { const bytes = [...encoder.encode(key)]; return [...word(bytes.length), ...bytes]; })];
const declarations = (local, session) => Uint8Array.from([...part(2, keys(local)), ...part(5, word(0)), ...part(6, word(0)), ...part(10, [110, 1]), ...part(11, keys(session)), ...protocolFixtureSection]);
const fakeRoot = () => ({ nodeType: 1, namespaceURI: "http://www.w3.org/1999/xhtml", prefix: null, localName: "div", hasAttributeNS: () => false, addEventListener() {}, removeEventListener() {}, textContent: "" });

// A host that answers the declarations, keeps the boot bytes `init` was
// given and never faults.
const fakeHost = (local, session) => {
  const memory = new WebAssembly.Memory({ initial: 2 });
  const bytes = declarations(local, session);
  let cmdLen = 0, staged = 0, boot = null;
  const x = {
    memory, protocol_version: () => PROTOCOL_VERSION, dbg_ptr: () => 0, dbg_len: () => 0,
    boot_keys() { new Uint8Array(memory.buffer).set(bytes); cmdLen = bytes.length; },
    cmd_ptr: () => 0, cmd_len: () => cmdLen, payload_reserve: count => { staged = count; return 65536; },
    init() { boot = new Uint8Array(memory.buffer, 65536, staged).slice(); cmdLen = 0; return 0; },
    event: () => 0, fault: () => 0, err_ptr: () => 0, err_len: () => 0,
    files_released: () => 0, work_len: () => 0, metric: () => 0n, drop() {},
  };
  return { x, boot: () => boot };
};
const sectionOf = (boot, wanted) => {
  for (let at = 0; at < boot.length;) {
    const tag = boot[at], n = new DataView(boot.buffer, boot.byteOffset).getUint32(at + 1, true);
    if (tag === wanted) return [...boot.slice(at + 5, at + 5 + n)];
    at += 5 + n;
  }
  return null;
};
const mount = (options, local = [], session = []) => {
  const host = fakeHost(local, session);
  const events = { addEventListener() {}, removeEventListener() {} };
  const listeners = [];
  const window = { addEventListener: (type, listener) => listeners.push([type, listener]), removeEventListener() {}, location: { pathname: "/", search: "", hash: "" } };
  const runtime = new RocEngineRuntime(host.x, fakeRoot(), { manualEffects: true, document: { ...events }, window, environment: { now: () => 0, seed: () => new Uint8Array(16), languages: () => ["en-US"], timeZone: () => ({ name: "", from_ms: -(2n ** 63n), until_ms: 2n ** 63n - 1n, offsets: [{ from_ms: -(2n ** 63n), minutes: 0 }] }) }, ...options });
  runtime.mount();
  return { runtime, boot: host.boot, listeners };
};
const unavailable = [0, 0, 0, 0, 0];
const lone = "\ud800";

await check("a declared local key holding a lone surrogate makes local storage unavailable at boot", () => {
  const { runtime, boot } = mount({ storage: { getItem: key => key === "bad" ? lone : "kept" } }, ["kept", "bad"]);
  assert.equal(runtime.poisoned, null);
  assert.deepEqual(sectionOf(boot(), 2), unavailable);
});
await check("a declared session key holding a lone surrogate makes session storage unavailable at boot", () => {
  const { runtime, boot } = mount({ sessionStorage: { getItem: () => lone } }, [], ["draft"]);
  assert.equal(runtime.poisoned, null);
  assert.deepEqual(sectionOf(boot(), 11), unavailable);
});
await check("an injected service answering something other than a string is unavailable at boot", () => {
  const { boot } = mount({ storage: { getItem: () => 7 } }, ["draft"]);
  assert.deepEqual(sectionOf(boot(), 2), unavailable);
});
await check("a throwing read is unavailable at boot, as before", () => {
  const { boot } = mount({ storage: { getItem: () => { throw new Error("denied"); } } }, ["draft"]);
  assert.deepEqual(sectionOf(boot(), 2), unavailable);
});
await check("readable values still boot", () => {
  const { boot } = mount({ storage: { getItem: () => "é" } }, ["k"]);
  assert.deepEqual(sectionOf(boot(), 2), [1, ...word(1), ...word(1), 107, ...word(2), 195, 169]);
});
for (const op of ["get", "sessionget"]) {
  for (const [label, getItem] of [["a lone surrogate", () => lone], ["a throwing read", () => { throw new Error("denied"); }], ["a non-string", () => 7]]) {
    await check(`${op} of ${label} answers Missing and never faults`, async () => {
      const { runtime } = mount({ storage: { getItem }, sessionStorage: { getItem } });
      const results = [];
      runtime.result = (id, payload) => results.push([id, [...payload]]);
      runtime.perform({ op, id: 3, key: "k" });
      await new Promise(resolve => setTimeout(resolve, 0));
      assert.equal(runtime.poisoned, null);
      assert.deepEqual(results, [[3, [4]]]);
    });
  }
}
await check("another document's write of a lone surrogate reports Missing and never faults", () => {
  const storage = { getItem: () => null };
  const { runtime, listeners } = mount({ storage });
  const reports = [];
  runtime.report = (id, payload) => reports.push([id, [...payload]]);
  runtime.perform({ op: "storagechanges", id: 5, key: "k" });
  const [[type, listener]] = listeners.filter(([type]) => type === "storage");
  assert.equal(type, "storage");
  listener({ storageArea: storage, key: "k", newValue: lone });
  listener({ storageArea: storage, key: "k", newValue: "ok" });
  assert.equal(runtime.poisoned, null);
  assert.deepEqual(reports, [[5, [4]], [5, [3, 111, 107]]]);
});
