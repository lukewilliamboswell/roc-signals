// A work request (FX kind 8) with a value or an operand outside the request
// is a `contract` fault (design.md, Appendix B, FX kinds), not an executor
// failure. Each case is a raw command batch, encoded here independently of
// the engine's encoder, applied by a runtime bound to the test fixture's
// protocol facts; only the host exports are fake.
import assert from "node:assert/strict";
import { RocEngineRuntime, PROTOCOL_VERSION, readDeclarations } from "../../platform/runtime.mjs";
import { protocolFixtureFacts, protocolFixtureSection } from "../browser/protocol-fixture.mjs";

const check = (name, test) => {
  try { test(); console.log(`ok   ${name}`); }
  catch (error) { console.log(`FAIL ${name}: ${error.message.split("\n")[0]}`); process.exitCode = 1; }
};
const word = n => [n & 255, (n >>> 8) & 255, (n >>> 16) & 255, n >>> 24];
const part = (tag, bytes) => [tag, ...word(bytes.length), ...bytes];
const text = value => { const bytes = [...new TextEncoder().encode(value)]; return [...word(bytes.length), ...bytes]; };
const FX = protocolFixtureFacts.ops.find(row => row.name === "FX").code;
const declarations = Uint8Array.from([...part(2, word(0)), ...part(5, word(0)), ...part(6, word(0)), ...part(10, [110, 1]), ...part(11, word(0)), ...protocolFixtureSection]);

const runtimeWith = batch => {
  const memory = new WebAssembly.Memory({ initial: 2 });
  let length = 0;
  const x = {
    memory, protocol_version: () => PROTOCOL_VERSION, dbg_ptr: () => 0, dbg_len: () => 0,
    boot_keys() { new Uint8Array(memory.buffer).set(declarations); length = declarations.length; },
    cmd_ptr: () => 0, cmd_len: () => length, fault: () => 0, err_ptr: () => 0, err_len: () => 0,
    files_released: () => 0, work_len: () => 0, metric: () => 0n, drop() {},
  };
  const root = { nodeType: 1, hasAttributeNS: () => false, addEventListener() {}, removeEventListener() {}, textContent: "" };
  const runtime = new RocEngineRuntime(x, root, { manualEffects: true, module: {} });
  // The fixture's bindings, read through the ordinary declaration reader;
  // the batch is then applied as a mounted runtime applies one.
  runtime.protocol = readDeclarations(x).bindings;
  new Uint8Array(memory.buffer).set(batch); length = batch.length;
  const error = console.error; console.error = () => {};
  try { runtime.guard(() => runtime.apply()); } finally { console.error = error; }
  return runtime;
};

// One work request: `task`, its input bytes, its files, then timeout,
// cancel policy and prepared flag, and the preparation's operands if any.
const work = ({ input = [1, 2, 3], files = [], cancel = 1, flag = 0, prep = [] } = {}) =>
  [0, FX, ...word(1), 8, ...text("sum"), ...word(input.length), ...input, ...word(files.length), ...files.flat(), ...word(0), cancel, flag, ...prep];

check("a well-formed work request is accepted", () => {
  const runtime = runtimeWith(work());
  assert.equal(runtime.poisoned, null);
  assert.equal(runtime.pendingEffects().length, 1);
});
check("a well-formed preparation's task is accepted", () => {
  const runtime = runtimeWith(work({ flag: 1, prep: [...text("index"), ...word(2), ...word(0)] }));
  assert.equal(runtime.poisoned, null);
});

const contract = (name, batch, detail) => check(name, () => {
  const runtime = runtimeWith(batch);
  assert.equal(runtime.poisoned?.class, "contract", `class ${runtime.poisoned?.class}: ${runtime.poisoned?.message}`);
  if (detail) assert.match(runtime.poisoned.message, detail);
});
const full = work();
contract("input longer than the request is a contract fault", [0, FX, ...word(1), 8, ...text("sum"), ...word(1000), 1, 2, 3], /work request/);
contract("a truncated task name is a contract fault", [0, FX, ...word(1), 8, ...word(1000), 115], /work request/);
contract("file ranges beyond the request are a contract fault", [0, FX, ...word(1), 8, ...text("sum"), ...word(0), ...word(1000)], /work request/);
contract("a request cut before its policy bytes is a contract fault", full.slice(0, -3), /work request/);
contract("cancel policy 0 is a contract fault", work({ cancel: 0 }), /cancel policy 0/);
contract("cancel policy 3 is a contract fault", work({ cancel: 3 }), /cancel policy 3/);
contract("prepared flag 2 is a contract fault", work({ flag: 2 }), /flag 2/);
contract("a preparation's input longer than the input is a contract fault", work({ flag: 1, prep: [...text("index"), ...word(4), ...word(0)] }), /preparation operands/);
contract("a preparation's files beyond the request's files are a contract fault", work({ flag: 1, prep: [...text("index"), ...word(0), ...word(1)] }), /preparation operands/);
contract("a preparation cut before its operands is a contract fault", work({ flag: 1, prep: [...text("index"), ...word(0)] }), /work request/);
contract("a truncated preparation name is a contract fault", work({ flag: 1, prep: [...word(1000)] }), /work request/);
// A file the runtime does not hold, or a name that is not UTF-8, can only
// come from an engine and runtime that disagree: a contract fault too.
const invalidName = [...word(2), 0xc3, 0x28];
contract("a file handle the runtime does not hold is a contract fault", work({ files: [[...word(77), ...word(0), ...word(0), ...word(0), ...word(0), ...word(0)]] }), /file handle 77/);
contract("a task name that is not UTF-8 is a contract fault", [0, FX, ...word(1), 8, ...invalidName, ...word(0), ...word(0), ...word(0), 1, 0], /task name is not UTF-8/);
contract("a preparation name that is not UTF-8 is a contract fault", work({ flag: 1, prep: [...invalidName, ...word(0), ...word(0)] }), /preparation name is not UTF-8/);

// onWorkerFault is the page's own observer, called just before a lost
// job's WorkLost result is delivered: one that throws must not keep that
// result from its request, which would leave the request unanswered.
check("an onWorkerFault observer that throws changes nothing", () => {
  const runtime = runtimeWith([0]);
  runtime.onWorkerFault = () => { throw new Error("observer broke"); };
  const error = console.error; console.error = () => {};
  try { assert.equal(runtime.reportLost({ id: 1, task: "sum" }, 4, "app_crash: boom"), "app_crash"); }
  finally { console.error = error; }
});
