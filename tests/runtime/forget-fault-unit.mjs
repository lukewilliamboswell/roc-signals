// A worker whose `forget` traps is poisoned (worker.mjs: "a faulted instance
// is never called again"), so the pool must discard it rather than hand it the
// next job; eviction may cost time, never an answer. The pool is the runtime's
// own, reached through a runtime mounted on nothing; only Worker is fake.
import assert from "node:assert/strict";
import { RocEngineRuntime } from "../../platform/runtime.mjs";

const check = async (name, test) => {
  try { await test(); console.log(`ok   ${name}`); }
  catch (error) { console.log(`FAIL ${name}: ${error.message}`); process.exitCode = 1; }
};
const settle = () => new Promise(resolve => setTimeout(resolve, 0));

// A worker script stand-in: it records what it is sent, and a test answers
// for it. Once it has answered a fault its instance is poisoned, and every
// later job answers the same fault, as a trapped host does.
const workers = [];
class FakeWorker {
  constructor() { this.sent = []; this.terminated = false; this.poisoned = null; workers.push(this); }
  postMessage(m) { this.sent.push(m); }
  terminate() { this.terminated = true; }
  reply(data) { if (data.type === "fault") this.poisoned = data; this.onmessage({ data }); }
  jobs() { return this.sent.filter(m => m.type === "job"); }
  forgets() { return this.sent.filter(m => m.type === "forget").length; }
  // Answer the oldest unanswered job: its own fault once poisoned, else `out`.
  answerJob(out) {
    if (this.poisoned) return this.reply(this.poisoned);
    const output = new Uint8Array(out).buffer;
    this.reply({ type: "done", output, objects: [], t: [0, 0, 0, 0, 0], mem: [65536], prepareMs: 0, held: this.sent.at(-1).mode !== "work", handles: 0, dbg: null });
  }
}

const fixture = (maxWorkers = 1) => {
  workers.length = 0;
  const root = { nodeType: 1, hasAttributeNS: () => false, addEventListener() {}, removeEventListener() {}, textContent: "" };
  const runtime = new RocEngineRuntime({}, root, { module: {}, maxWorkers, window: { Worker: FakeWorker, navigator: {} } });
  const pool = runtime.workPool();
  const results = new Map();
  let id = 0;
  const submit = (prepared = null) => {
    const job = ++id;
    pool.submit(new Uint8Array([job]), outcome => results.set(job, outcome), { id: job, task: `task${job}`, prepared });
    return job;
  };
  // A preparation keyed on file token 7: its worker holds the state after
  // the job, until the runtime lets go of that file.
  const key = { name: "prep", init: new Uint8Array([1]), ranges: [7, 0, 1] };
  const prepared = { key, prepare: new Uint8Array([9]), prepareObjects: [] };
  runtime.files.set(7, {});
  const release = () => { runtime.files.delete(7); pool.released([7]); };
  return { runtime, pool, results, submit, prepared, release };
};
const forgetFault = { type: "fault", code: 4, message: "app_crash: forget trapped", dbg: null };

await check("a worker whose forget faults is discarded, and the next job runs on a fresh worker", async () => {
  const { pool, results, submit, prepared, release } = fixture();
  const first = submit(prepared);
  const [held] = workers;
  held.answerJob([1]);
  assert.deepEqual([...results.get(first).output], [1]);
  release();
  assert.equal(held.forgets(), 1);
  held.reply(forgetFault);
  assert(held.terminated, "the faulted worker is terminated");
  assert(!pool.slots.some(slot => slot.worker === held), "the faulted worker left the pool");
  const second = submit();
  await settle();
  assert.equal(held.jobs().length, 1, "the faulted worker is never sent another job");
  assert.equal(workers.length, 2);
  workers[1].answerJob([2]);
  assert.deepEqual([...results.get(second).output], [2], "the next job gets its real answer");
});

await check("a job submitted before the forget's fault arrives still gets its real answer", async () => {
  const { pool, results, submit, prepared, release } = fixture();
  submit(prepared);
  const [held] = workers;
  held.answerJob([1]);
  release();
  const second = submit();
  await settle();
  assert.equal(held.jobs().length, 1, "no job is posted behind a forget that has not answered");
  held.reply(forgetFault);
  await settle();
  assert(held.terminated);
  assert.equal(workers.length, 2, "the waiting job goes to a fresh worker");
  assert.equal(workers[1].jobs().length, 1);
  workers[1].answerJob([2]);
  assert.deepEqual([...results.get(second).output], [2]);
  assert.equal(results.get(second).lost, undefined);
  assert.equal(pool.slots.length, 1);
});

await check("a job waiting behind a forget that succeeds runs on the same worker", async () => {
  const { results, submit, prepared, release } = fixture();
  submit(prepared);
  const [held] = workers;
  held.answerJob([1]);
  release();
  const second = submit();
  await settle();
  assert.equal(held.jobs().length, 1);
  held.reply({ type: "forgot", mem: [65536] });
  await settle();
  assert.equal(held.jobs().length, 2, "the forgotten worker takes the waiting job");
  assert.equal(workers.length, 1);
  held.answerJob([2]);
  assert.deepEqual([...results.get(second).output], [2]);
});

await check("a fault from an idle worker with no forget pending discards it", async () => {
  const { pool, submit } = fixture();
  submit();
  const [worker] = workers;
  worker.answerJob([1]);
  worker.reply({ type: "fault", code: 4, message: "app_crash: idle", dbg: null });
  assert(worker.terminated);
  assert.equal(pool.slots.length, 0);
});

await check("with room in the pool, a job waits for the forgetting worker rather than starting another", async () => {
  const { results, submit, prepared, release } = fixture(2);
  submit(prepared);
  const [held] = workers;
  held.answerJob([1]);
  release();
  const second = submit();
  await settle();
  assert.equal(workers.length, 1, "no worker is started for a job a forgetting worker will take");
  held.reply({ type: "forgot", mem: [65536] });
  await settle();
  assert.equal(held.jobs().length, 2);
  held.answerJob([2]);
  assert.deepEqual([...results.get(second).output], [2]);
});

// Inline mode: the second instance runs on the page's thread, and its
// forget is reached from the page's own apply when the page lets a file
// go. A trap there poisons that instance only; the page is untouched and
// the next job gets a fresh instance. WebAssembly.instantiate is the fake.
const inlineFixture = () => {
  const instances = [];
  const fakeInstance = () => {
    const memory = new WebAssembly.Memory({ initial: 1 });
    let fault = 0;
    const answer = out => { const bytes = new Uint8Array(memory.buffer); bytes.set([0, 0, 0, 0, ...out], 1024); return 4 + out.length; };
    let cmdLen = 0;
    const exports = {
      memory, dbg_len: () => 0, dbg_ptr: () => 0, metric: () => 0n, files_released: () => 0, files_tokens: () => 0,
      files_stage: n => n, payload_reserve: () => 2048, cmd_ptr: () => 1024, cmd_len: () => cmdLen,
      fault: () => fault, err_ptr: () => 0, err_len: () => 0,
      forget() { if (instance.forgetTraps) { fault = 4; throw new WebAssembly.RuntimeError("unreachable"); } },
      prepare() {}, work() { cmdLen = answer([instances.length]); }, ask() { cmdLen = answer([instances.length]); },
    };
    const instance = { exports, forgetTraps: false };
    instances.push(instance);
    return instance;
  };
  const root = { nodeType: 1, hasAttributeNS: () => false, addEventListener() {}, removeEventListener() {}, textContent: "" };
  const module = new WebAssembly.Module(Uint8Array.from([0, 97, 115, 109, 1, 0, 0, 0]));
  const runtime = new RocEngineRuntime({}, root, { module, workers: "inline", window: { navigator: {} } });
  const pool = runtime.workPool();
  const results = new Map();
  let id = 0;
  const submit = (prepared = null) => {
    const job = ++id;
    pool.submit(new Uint8Array([job]), outcome => results.set(job, outcome), { id: job, task: `task${job}`, prepared });
    return job;
  };
  const key = { name: "prep", init: new Uint8Array([1]), ranges: [7, 0, 1] };
  const prepared = { key, prepare: new Uint8Array([9]), prepareObjects: [] };
  runtime.files.set(7, {});
  return { runtime, pool, results, submit, prepared, instances, fakeInstance };
};

await check("inline: a trap in the instance's forget drops that instance, never the page", async () => {
  const { runtime, pool, results, submit, prepared, instances, fakeInstance } = inlineFixture();
  const instantiate = WebAssembly.instantiate;
  WebAssembly.instantiate = async () => fakeInstance();
  try {
    const first = submit(prepared);
    await settle(); await settle();
    assert.deepEqual([...results.get(first).output], [1]);
    assert.equal(pool.inlineKey, prepared.key, "the inline instance keeps the prepared state");
    instances[0].forgetTraps = true;
    runtime.files.delete(7);
    assert.doesNotThrow(() => runtime.guard(() => pool.released([7])));
    assert.equal(runtime.poisoned, null, "the page is not poisoned");
    assert.equal(pool.instance, null, "the trapped instance is dropped");
    assert.equal(pool.inlineKey, null);
    assert.equal(pool.terminated, 1, "the trapped instance is counted as ended");
    const second = submit();
    await settle(); await settle();
    assert.equal(instances.length, 2, "the next job gets a fresh instance");
    assert.deepEqual([...results.get(second).output], [2]);
    assert.equal(results.get(second).lost, undefined);
  } finally {
    WebAssembly.instantiate = instantiate;
  }
});
