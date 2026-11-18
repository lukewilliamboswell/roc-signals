// A port handler is the page's own JavaScript, and reading what it answered
// runs more of it: a getter, a Proxy's traps, a `message` or `toString` that
// throws. Whatever that code throws, the call is answered `PortFailed(Threw)`,
// its live entry is released and the page is never poisoned (design.md,
// "Error Containment": a port handler is contained like a browser service).
// A subscription the JavaScript ends with such a value still delivers its
// terminal failure, and a command's such failure is still only reported.
// Only the host exports, the root and the handlers are fake.
import assert from "node:assert/strict";
import { RocEngineRuntime, PROTOCOL_VERSION } from "../../platform/runtime.mjs";
import { protocolFixtureSection } from "../browser/protocol-fixture.mjs";

const check = async (name, test) => {
  try { await test(); console.log(`ok   ${name}`); }
  catch (error) { console.log(`FAIL ${name}: ${error.message.split("\n")[0]}`); process.exitCode = 1; }
};
const word = n => [n & 255, (n >>> 8) & 255, (n >>> 16) & 255, n >>> 24];
const part = (tag, bytes) => [tag, ...word(bytes.length), ...bytes];
const declarations = Uint8Array.from([...part(2, word(0)), ...part(5, word(0)), ...part(6, word(0)), ...part(10, [110, 1]), ...part(11, word(0)), ...protocolFixtureSection, ...part(14, [0])]);
const events = { addEventListener() {}, removeEventListener() {} };
const fakeRoot = () => ({ nodeType: 1, namespaceURI: "http://www.w3.org/1999/xhtml", prefix: null, localName: "div", hasAttributeNS: () => false, ...events, textContent: "" });

const mount = handler => {
  const memory = new WebAssembly.Memory({ initial: 2 });
  let cmdLen = 0;
  const x = {
    memory, protocol_version: () => PROTOCOL_VERSION, dbg_ptr: () => 0, dbg_len: () => 0,
    boot_keys() { new Uint8Array(memory.buffer).set(declarations); cmdLen = declarations.length; },
    cmd_ptr: () => 0, cmd_len: () => cmdLen, payload_reserve: () => 65536,
    init() { cmdLen = 0; return 0; }, event: () => 0, fault: () => 0, err_ptr: () => 0, err_len: () => 0,
    files_released: () => 0, keys_released: () => 0, work_len: () => 0, metric: () => 0n, drop() {},
  };
  const runtime = new RocEngineRuntime(x, fakeRoot(), {
    document: { ...events }, window: { ...events, location: { pathname: "/", search: "", hash: "" } },
    environment: { now: () => 0, seed: () => new Uint8Array(16), languages: () => ["en-US"], timeZone: () => ({ name: "", from_ms: -(2n ** 63n), until_ms: 2n ** 63n - 1n, offsets: [{ from_ms: -(2n ** 63n), minutes: 0 }] }) },
  });
  runtime.mount();
  runtime.portHandler = () => handler;
  const results = [];
  runtime.result = (id, payload) => results.push([id, payload.parts.flatMap(p => [...p])]);
  return { runtime, results };
};
const settled = () => new Promise(resolve => setTimeout(resolve, 0));
const message = { json: "null", blobs: [], files: [] };
const threw = text => [15, 1, ...new TextEncoder().encode(text)];
const quietly = async fn => {
  const error = console.error; console.error = () => {};
  try { return await fn(); } finally { console.error = error; }
};

const getter = () => ({ get ok() { throw new Error("getter broke"); } });
const proxy = () => new Proxy({}, { ownKeys() { throw new Error("trap broke"); } });
const proxyArray = () => new Proxy([], { get(target, key) { if (key === "map") throw new Error("array trap broke"); return target[key]; } });
const undescribable = () => ({ get message() { throw new Error("no message"); } });

for (const [label, answer, text] of [
  ["an object with a throwing getter", getter, "reading the answer threw: getter broke"],
  ["a Proxy whose ownKeys trap throws", proxy, "reading the answer threw: trap broke"],
  ["an array Proxy whose get trap throws", proxyArray, "reading the answer threw: array trap broke"],
]) {
  for (const [shape, call] of [["resolved", () => Promise.resolve(answer())], ["returned", answer]]) {
    await check(`a call ${shape} with ${label} answers Threw and releases its entry`, async () => {
      const { runtime, results } = mount({ call });
      runtime.performPortCall({ op: "portcall", id: 7, port: "p", msg: message, timeout: 0 });
      assert.equal(runtime.live.has(7), true);
      await settled();
      assert.equal(runtime.poisoned, null);
      assert.deepEqual(results, [[7, threw(text)]]);
      assert.equal(runtime.live.has(7), false);
      assert.equal(runtime.portCounts.get("p").threw, 1);
    });
  }
}

await check("a call that rejects with a value whose message cannot be read answers Threw", async () => {
  const { runtime, results } = mount({ call: () => Promise.reject(undescribable()) });
  runtime.performPortCall({ op: "portcall", id: 8, port: "p", msg: message, timeout: 0 });
  await settled();
  assert.equal(runtime.poisoned, null);
  assert.deepEqual(results, [[8, threw("a value that could not be described")]]);
  assert.equal(runtime.live.has(8), false);
});

await check("a call that throws such a value synchronously answers Threw", async () => {
  const { runtime, results } = mount({ call: () => { throw undescribable(); } });
  runtime.performPortCall({ op: "portcall", id: 9, port: "p", msg: message, timeout: 0 });
  await settled();
  assert.deepEqual(results, [[9, threw("a value that could not be described")]]);
  assert.equal(runtime.live.has(9), false);
});

await check("a subscription whose subscribe throws such a value ends Threw and never poisons", async () => {
  const { runtime, results } = mount({ subscribe: () => { throw undescribable(); } });
  runtime.portDecls = new Map([["p", { delivery: 2, bound: 1 }]]);
  runtime.performPortSub({ op: "portsub", id: 10, port: "p", msg: message });
  await settled();
  assert.equal(runtime.poisoned, null);
  assert.deepEqual(results, [[10, threw("a value that could not be described")]]);
});

await check("a command that throws such a value is reported, not a fault", async () => {
  const { runtime } = mount({ command: () => { throw undescribable(); } });
  const reported = [];
  runtime.onPortFault = fault => reported.push(fault.message);
  await quietly(() => runtime.performPortCommand({ op: "portcommand", port: "p", msg: message }));
  assert.equal(runtime.poisoned, null);
  assert.deepEqual(reported, ["a value that could not be described"]);
});

await check("emit with a value whose getter throws gives the emitter its error and keeps the subscription", async () => {
  let ctx;
  const { runtime, results } = mount({ subscribe: (_message, given) => { ctx = given; } });
  runtime.portDecls = new Map([["p", { delivery: 1, bound: 4 }]]);
  runtime.performPortSub({ op: "portsub", id: 11, port: "p", msg: message });
  assert.throws(() => ctx.emit(getter()), /getter broke/);
  assert.equal(runtime.poisoned, null);
  assert.equal(runtime.live.has(11), true);
  await settled();
  assert.deepEqual(results, []);
});

await check("manual call fixtures keep malformed JSON and explicit binary attachments unchanged", () => {
  const { runtime, results } = mount({}); runtime.manual = true;
  runtime.performPortCall({ op: "portcall", id: 21, port: "p", msg: message, timeout: 0 });
  assert.equal(runtime.answerPort(21, { json: "{bad", blobs: [[], [0, 255, 128]] }), true);
  assert.deepEqual(results, [[21, [14, 4, 0, 0, 0, 123, 98, 97, 100, 2, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 255, 128, 0, 0, 0, 0]]]);
});

await check("manual subscriptions receive ordered byte blocks beside numeric markers", () => {
  const { runtime, results } = mount({}); runtime.manual = true;
  runtime.portDecls = new Map([["p", { delivery: 1, bound: 4 }]]);
  runtime.performPortSub({ op: "portsub", id: 22, port: "p", msg: message });
  const json = '{"$bytes":1}';
  assert.equal(runtime.messagePort("p", { json, blobs: [[0], [128, 255]] }), 1);
  const encoded = [...new TextEncoder().encode(json)];
  assert.deepEqual(results, [[22, [14, ...word(encoded.length), ...encoded, ...word(2), ...word(1), 0, ...word(2), 128, 255, ...word(0)]]]);
});

await check("a textual bytes marker is left as text and creates no attachment", () => {
  const { runtime, results } = mount({}); runtime.manual = true;
  runtime.performPortCall({ op: "portcall", id: 23, port: "p", msg: message, timeout: 0 });
  const json = '{"$bytes":"AP8="}', encoded = [...new TextEncoder().encode(json)];
  runtime.answerPort(23, { json });
  assert.deepEqual(results, [[23, [14, ...word(encoded.length), ...encoded, ...word(0), ...word(0)]]]);
});


await check("manual binary reports retain their bytes from message arrival", () => {
  const { runtime } = mount({}); runtime.manual = true;
  runtime.portDecls = new Map([["p", { delivery: 2, bound: 1 }]]);
  runtime.performPortSub({ op: "portsub", id: 24, port: "p", msg: message });
  let waiting;
  runtime.report = (_id, payload) => { waiting = payload; return false; };
  const source = Uint8Array.from([0, 255]);
  assert.equal(runtime.messagePort("p", { json: '{"$bytes":0}', blobs: [source] }), 1);
  source.fill(7);
  assert.deepEqual([...waiting.parts.at(-2)], [0, 255]);
  runtime.unmount();
});
