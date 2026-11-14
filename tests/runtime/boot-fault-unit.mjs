// A module whose declarations cannot be built traps in `boot_keys`, before
// section 12 (which names the fault classes) exists. The declarations depend
// only on the top-level `main`, so this is a compiler gap or a platform bug,
// not app data; it must still be contained and classified. The runtime still
// classifies that trap by the host's fault code, poisons once and reports it
// through onFault; and the protocol facts it later binds must name the host's
// fault classes and HTTP policies exactly. Only the host exports are fake.
import assert from "node:assert/strict";
import { RocEngineRuntime, PROTOCOL_VERSION, readDeclarations } from "../../platform/runtime.mjs";
import { protocolFixtureFacts, protocolFixtureSectionOf } from "../browser/protocol-fixture.mjs";

const check = (name, test) => {
  try { test(); console.log(`ok   ${name}`); }
  catch (error) { console.log(`FAIL ${name}: ${error.message.split("\n")[0]}`); process.exitCode = 1; }
};
const word = n => [n & 255, (n >>> 8) & 255, (n >>> 16) & 255, n >>> 24];
const part = (tag, bytes) => [tag, ...word(bytes.length), ...bytes];
const prefix = [...part(2, word(0)), ...part(5, word(0)), ...part(6, word(0)), ...part(10, [110, 1]), ...part(11, word(0))];

// A root with the listener surface the runtime uses before and during
// containment; nothing here is a browser DOM.
const fakeRoot = () => ({ nodeType: 1, hasAttributeNS: () => false, addEventListener() {}, removeEventListener() {}, textContent: "" });

// A host whose `boot_keys` either answers `declarations` or poisons with
// `fault` and the diagnostic `message`, and then traps as `host.zig` does.
const fakeHost = ({ declarations = null, fault = 0, message = "" } = {}) => {
  const memory = new WebAssembly.Memory({ initial: 2 });
  let code = 0, errLen = 0, cmdLen = 0;
  const calls = { boot_keys: 0, init: 0 };
  const x = {
    memory, protocol_version: () => PROTOCOL_VERSION, dbg_ptr: () => 8192, dbg_len: () => 0,
    boot_keys() {
      calls.boot_keys++;
      if (code !== 0) throw new WebAssembly.RuntimeError("unreachable");
      if (declarations === null) {
        const bytes = new TextEncoder().encode(message);
        new Uint8Array(memory.buffer).set(bytes, 4096);
        errLen = bytes.length; code = fault;
        throw new WebAssembly.RuntimeError("unreachable");
      }
      new Uint8Array(memory.buffer).set(declarations); cmdLen = declarations.length;
    },
    cmd_ptr: () => 0, cmd_len: () => cmdLen, payload_reserve: () => 65536,
    init() { calls.init++; if (code !== 0) throw new WebAssembly.RuntimeError("unreachable"); cmdLen = 0; return 0; },
    event() { if (code !== 0) throw new WebAssembly.RuntimeError("unreachable"); return 0; },
    fault: () => code, err_ptr: () => 4096, err_len: () => errLen,
    files_released: () => 0, work_len: () => 0, metric: () => 0n, drop() {},
  };
  return { x, calls };
};

const quietly = fn => {
  const error = console.error; console.error = () => {};
  try { return fn(); } finally { console.error = error; }
};

check("a contract trap in boot_keys is contained, classified and reported once", () => {
  const message = "contract: worker catalogue: two tasks are named \"sum\"";
  const { x, calls } = fakeHost({ fault: 1, message });
  const faults = [];
  const runtime = new RocEngineRuntime(x, fakeRoot(), { manualEffects: true, onFault: f => faults.push(f) });
  quietly(() => runtime.mount());
  assert.equal(runtime.poisoned?.class, "contract");
  assert.equal(runtime.poisoned.code, 1);
  assert.equal(runtime.poisoned.message, message);
  assert.equal(faults.length, 1);
  assert.equal(faults[0], runtime.poisoned);
  assert.equal(calls.init, 0);
  // Later calls are refused without re-entering Wasm or faulting again.
  quietly(() => runtime.mount());
  runtime.guard(() => x.event());
  assert.equal(faults.length, 1);
  assert.equal(calls.boot_keys, 1);
  assert(runtime.refused >= 1);
});

check("a resource_limit trap in boot_keys keeps the host's class", () => {
  const { x } = fakeHost({ fault: 2, message: "resource_limit: more than 64 ports" });
  const runtime = new RocEngineRuntime(x, fakeRoot(), { manualEffects: true });
  quietly(() => runtime.mount());
  assert.equal(runtime.poisoned?.class, "resource_limit");
});

check("a runtime-classified fault before section 12 is read does not need the facts", () => {
  const { x } = fakeHost({ declarations: Uint8Array.from(prefix) });
  const runtime = new RocEngineRuntime(x, fakeRoot(), { manualEffects: true });
  quietly(() => runtime.contain(new Error("contract: early"), "contract"));
  assert.equal(runtime.poisoned?.class, "contract");
});

const facts = change => { const value = structuredClone(protocolFixtureFacts); change(value); return value; };
const declarations = value => Uint8Array.from([...prefix, ...protocolFixtureSectionOf(value)]);
const refuses = (name, value, detail) => check(name, () => {
  const { x, calls } = fakeHost({ declarations: declarations(value) });
  assert.throws(() => readDeclarations(x), error => error.message.startsWith("contract: declaration section 12 (protocol)") && error.message.includes(detail));
  const runtime = new RocEngineRuntime(x, fakeRoot(), { manualEffects: true });
  assert.throws(() => runtime.mount(), error => error.message.includes(detail));
  assert.equal(calls.init, 0);
  assert.equal(runtime.poisoned, null);
});

check("the host's own fault classes and fetch's policy names bind", () => {
  const { x } = fakeHost({ declarations: declarations(protocolFixtureFacts) });
  const bindings = readDeclarations(x).bindings;
  assert.equal(bindings.HTTP_CACHE[2], "no-store");
  assert.equal(bindings.HTTP_CREDENTIALS[2], "include");
});
refuses("reordered fault classes refuse the mount", facts(f => { [f.fault_classes[1], f.fault_classes[2]] = [f.fault_classes[2], f.fault_classes[1]]; }), "fault classes");
refuses("short fault classes refuse the mount", facts(f => { f.fault_classes = ["none", "contract"]; }), "fault classes");
refuses("an extra fault class refuses the mount", facts(f => { f.fault_classes.push("other"); }), "fault classes");
refuses("an unknown fault class refuses the mount", facts(f => { f.fault_classes[4] = "crash"; }), "fault classes");
refuses("an unknown HTTP cache name refuses the mount", facts(f => { f.http_cache[1].name = "no-storage"; }), 'unknown HTTP cache name "no-storage"');
refuses("a cache name fetch refuses outside same-origin mode refuses the mount", facts(f => { f.http_cache[4].name = "only-if-cached"; }), 'unknown HTTP cache name "only-if-cached"');
refuses("an unknown HTTP credentials name refuses the mount", facts(f => { f.http_credentials[0].name = "same_origin"; }), 'unknown HTTP credentials name "same_origin"');
