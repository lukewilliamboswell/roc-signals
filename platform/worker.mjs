// The generic worker script of the roc-signals runtime (design.md,
// "Workers" and Appendix B). `runtime.mjs` starts it as a module worker
// beside itself; it contains nothing specific to an app.
//
// Messages from the page, in order:
//   { type: "init", module, version, userTiming } — the page's compiled
//     `WebAssembly.Module` (the same module the page runs) and the protocol
//     version the page's runtime implements. The worker instantiates its own
//     instance, which never mounts, and answers
//     { type: "ready", origin, instStart, instEnd, memBytes, liveAllocs,
//     liveBytes }: its clock's `performance.timeOrigin`, when instantiation
//     started and ended, the instance's linear memory and its live
//     allocations before any job, for the page's monitor.
//   { type: "job", mode, payload, objects, maxOutputBytes, program } — one
//     job. `payload` (a transferred ArrayBuffer) is `name:str input:rest`;
//     `objects` are the browser's Blobs or Files the request names (whole,
//     by reference), and `maxOutputBytes` bounds what the job appends to
//     its builders; `program` (the task's name) is sent only when
//     `userTiming` asked for a `roc:work.compute` measure here. The worker
//     mints a handle for each object in its instance (`files_stage`),
//     stages the payload and calls the instance's `work()` export, during
//     which the task's hosted effects call the imports below: reading a
//     range of a file with FileReaderSync, and building files from parts.
//     Its answer, `n:u32 (token:u64)* output:rest`, names the files it
//     holds: they are posted back as { blob, name, type } in `objects`
//     beside the output, by reference, in
//     { type: "done", output, objects, t, mem, prepareMs, held, handles }:
//     the output bytes (transferred), its stamps `t` = [received, instance
//     ready, staged, returned, posted] in this worker's clock, `mem` =
//     [linear memory bytes, live allocations, live bytes] (the host's
//     metric 4 and 5), `held` (whether the instance holds a prepared
//     state) and `handles`, the live handles left in the instance after the
//     job (0 when the job let go of everything and no state holds any). Or
//     { type: "fault", code, message } when the instance trapped (`code` is
//     the instance's fault class, 0 when it recorded none) or could not be
//     used. A faulted instance is never called again: the page discards
//     this worker.
//   A preparation's task (design.md, "Prepared state"): `mode` "prepare"
//     also carries `prepare` (an ArrayBuffer, `prep:str init:rest`) and
//     `prepareObjects`, the preparation's files: the worker lets go of any
//     state it holds, mints handles for those files, calls `prepare()`,
//     which keeps the new state, and then runs the job in `payload`
//     (`task:str input:rest`) on it with `ask()`. `mode` "ask" runs the job
//     on the state already held. "done" then also carries `prepareMs` (the
//     `prepare()` call, or null).
//   { type: "forget" } — let go of the held state (eviction); answered
//     { type: "forgot", mem } once it has.
// Every builder a call opened is closed when the call returns: a builder
// never outlives its job or its preparation, so one a prepared state kept
// is refused to every later job (status 3, a contract error in Roc).
// The page runs one job per worker at a time, and stops a job by
// terminating the worker; it sends "forget" only to an idle worker.

let ready = null;
let userTiming = false;
// Measures this worker has added to its own performance timeline; it clears
// them at 1024 (observers and DevTools traces have already seen them).
let measures = 0;

// What this instance's handles name, by token (a Number): a file,
// { blob, name, type }, or a builder, { parts, name, type, open, expired }.
// A token's entry goes when the instance's host releases the handle
// (`files_released`, drained after each call), so a builder's parts go
// with the job that made them, finished or not, a file a prepared state
// keeps stays as long as the state does, and a terminated worker takes
// everything with it.
const held = new Map();

// The builders the running call opened, closed when it returns.
let opened = [];

// The bytes a running job may still append (its maxOutputBytes).
let outputLeft = 0;

// The instance's exports, for the imports to reach its memory.
let exportsOf = null;

const textDecoder = new TextDecoder();

function readText(ptr, len) {
  return len === 0 ? "" : textDecoder.decode(new Uint8Array(exportsOf.memory.buffer, ptr, len));
}

// A builder's refusal: 3 when the call that opened it has returned, 2 when
// it is not an open builder; 0 when it may be used.
function refusal(b) {
  if (b === undefined || b.parts === undefined) return 2;
  if (b.expired) return 3;
  return b.open ? 0 : 2;
}

// The worker halves of a job's hosted effects (`Hosted.roc`; `host.zig`
// calls them only inside a job). Tokens arrive as BigInts. Each answers a
// status the Roc side decides with; none throws for a job's mistakes.
const taskImports = {
  // Read a range of a file straight into `dst`, which the host allocated.
  // 1 when it read exactly `len` bytes, 0 when the browser could not.
  js_file_read(token, start, len, dst) {
    const entry = held.get(Number(token));
    if (entry === undefined || entry.blob === undefined) return 0;
    try {
      const from = Number(start);
      const buf = new FileReaderSync().readAsArrayBuffer(entry.blob.slice(from, from + Number(len)));
      if (buf.byteLength !== Number(len)) return 0;
      new Uint8Array(exportsOf.memory.buffer, dst, buf.byteLength).set(new Uint8Array(buf));
      return 1;
    } catch (_) {
      return 0;
    }
  },
  js_file_size(token) {
    const entry = held.get(Number(token));
    return BigInt(entry !== undefined && entry.blob !== undefined ? entry.blob.size : 0);
  },
  js_builder_open(token, namePtr, nameLen, mimePtr, mimeLen, from, start, len) {
    const parts = [];
    if (from !== 0n) {
      const source = held.get(Number(from));
      if (source === undefined || source.blob === undefined) return 2;
      const s = Number(start);
      parts.push(source.blob.slice(s, s + Number(len)));
    }
    held.set(Number(token), { parts, name: readText(namePtr, nameLen), type: readText(mimePtr, mimeLen), open: true, expired: false });
    opened.push(Number(token));
    return 0;
  },
  // The one copy of a written byte: out of linear memory into a part.
  js_builder_append(token, src, len) {
    const b = held.get(Number(token));
    const no = refusal(b);
    if (no !== 0) return no;
    if (len > outputLeft) return 1;
    outputLeft -= len;
    if (len > 0) b.parts.push(new Blob([new Uint8Array(exportsOf.memory.buffer, src, len)]));
    return 0;
  },
  js_builder_append_file(token, file, start, len) {
    const b = held.get(Number(token));
    const no = refusal(b);
    if (no !== 0) return no;
    const f = held.get(Number(file));
    if (f === undefined || f.blob === undefined) return 2;
    const s = Number(start);
    b.parts.push(f.blob.slice(s, s + Number(len)));
    return 0;
  },
  // Compose the parts into one immutable Blob (constant time; the parts are
  // referenced) behind the fresh handle `file`.
  js_builder_finish(token, file) {
    const b = held.get(Number(token));
    const no = refusal(b);
    if (no !== 0) return no;
    held.set(Number(file), { blob: new Blob(b.parts, { type: b.type }), name: b.name, type: b.type });
    b.open = false;
    b.parts = [];
    return 0;
  },
};

// Close the builders the call that just returned opened.
function closeOpened() {
  for (const token of opened) {
    const b = held.get(token);
    if (b !== undefined && b.parts !== undefined && b.open) {
      b.open = false;
      b.expired = true;
      b.parts = [];
    }
  }
  opened = [];
}

// Let go of what the instance's host released: after a call, its input
// files, the builders it opened and the files of its answer, which were
// posted first; after "forget", what the state held.
function drainReleased(x) {
  const n = x.files_released();
  if (n === 0) return;
  const dv = new DataView(x.memory.buffer, x.files_tokens(), 8 * n);
  for (let i = 0; i < n; i += 1) held.delete(dv.getUint32(8 * i, true) + dv.getUint32(8 * i + 4, true) * 0x100000000);
}

// Mint a handle for each object in the instance, for the next call.
function stageObjects(x, objects) {
  const n = x.files_stage(objects.length);
  if (n < objects.length) {
    x.files_stage(0);
    // The instance has no room for the job's files: a resource limit of
    // the job, which the page answers lost with that class.
    throw { code: 2, message: `resource_limit: a job was sent ${objects.length} files and its instance has room for ${n}` };
  }
  const tokens = new DataView(x.memory.buffer, x.files_tokens(), 8 * n);
  for (let i = 0; i < n; i += 1) {
    const o = objects[i];
    held.set(tokens.getUint32(8 * i, true) + tokens.getUint32(8 * i + 4, true) * 0x100000000, { blob: o, name: o.name ?? "", type: o.type ?? "" });
  }
}

// Stage `payload` as the next call's payload.
function stage(x, payload) {
  const bytes = new Uint8Array(payload);
  const ptr = x.payload_reserve(bytes.length);
  // A fresh view: reserving may have grown memory.
  if (bytes.length > 0) new Uint8Array(x.memory.buffer, ptr, bytes.length).set(bytes);
}

// Run a job (`work()`, or `ask()` on the held state, preparing it first in
// "prepare" mode) and return its output and the objects its answer holds.
function runJob(x, m) {
  outputLeft = m.maxOutputBytes ?? 0;
  let prepareMs = null;
  if (m.mode === "prepare") {
    // A new state replaces the held one.
    x.forget();
    drainReleased(x);
    stageObjects(x, m.prepareObjects ?? []);
    stage(x, m.prepare);
    const t = performance.now();
    x.prepare();
    prepareMs = performance.now() - t;
    closeOpened();
    drainReleased(x);
  }
  stageObjects(x, m.objects ?? []);
  stage(x, m.payload);
  const call = performance.now();
  if (m.mode === "work") x.work();
  else x.ask();
  const ret = performance.now();
  closeOpened();
  const answer = new Uint8Array(x.memory.buffer, x.cmd_ptr(), x.cmd_len());
  const dv = new DataView(answer.buffer, answer.byteOffset, answer.byteLength);
  const count = dv.getUint32(0, true);
  const out = [];
  for (let i = 0; i < count; i += 1) {
    const at = 4 + 8 * i;
    const entry = held.get(dv.getUint32(at, true) + dv.getUint32(at + 4, true) * 0x100000000);
    if (entry === undefined || entry.blob === undefined) throw new Error("a job's answer names a handle that is not a file");
    out.push({ blob: entry.blob, name: entry.name, type: entry.type });
  }
  const output = answer.slice(4 + 8 * count);
  drainReleased(x);
  return { output, objects: out, call, ret, prepareMs };
}

async function start(module, version) {
  const instStart = performance.now();
  const instance = await WebAssembly.instantiate(module, { env: taskImportsFor(module) });
  const instEnd = performance.now();
  const x = instance.exports;
  exportsOf = x;
  const got = typeof x.protocol_version === "function" ? x.protocol_version() : 0;
  if (got !== version) throw new Error(`roc engine protocol ${got} is not the protocol ${version} the page's runtime implements`);
  if (typeof x.work !== "function") throw new Error("the module has no work export");
  self.postMessage({ type: "ready", origin: performance.timeOrigin, instStart, instEnd, memBytes: x.memory.buffer.byteLength, liveAllocs: Number(x.metric(4)), liveBytes: Number(x.metric(5)) });
  return x;
}

// The imports the module asks for, from the task imports above. An import
// the platform does not define is the module speaking another protocol.
function taskImportsFor(module) {
  const env = {};
  for (const imp of WebAssembly.Module.imports(module)) {
    if (imp.module !== "env") continue;
    const f = taskImports[imp.name];
    if (typeof f !== "function") throw new Error(`the module imports env.${imp.name}, which this worker script does not provide`);
    env[imp.name] = f;
  }
  return env;
}

const memOf = (x) => [x.memory.buffer.byteLength, Number(x.metric(4)), Number(x.metric(5))];

function measure(program, start, end) {
  if (measures >= 1024) {
    performance.clearMeasures();
    measures = 0;
  }
  performance.measure(`roc:work.compute ${program}`, { start, end, detail: { devtools: { dataType: "track-entry", track: "compute", trackGroup: "roc workers", color: "primary" } } });
  measures += 1;
}

function faultOf(x, error) {
  if (error && typeof error.code === "number" && typeof error.message === "string") return { type: "fault", code: error.code, message: error.message };
  let code = 0;
  let message = String(error && error.message ? error.message : error);
  try {
    code = x ? x.fault() : 0;
    if (code !== 0) message = new TextDecoder().decode(new Uint8Array(x.memory.buffer, x.err_ptr(), x.err_len()));
  } catch (_) {
    code = 0;
  }
  return { type: "fault", code, message };
}

self.onmessage = async (event) => {
  const m = event.data;
  if (m.type === "init") {
    userTiming = !!m.userTiming;
    ready = start(m.module, m.version);
    ready.catch(() => {});
    return;
  }
  if (m.type === "forget") {
    let x = null;
    try {
      x = await ready;
      x.forget();
      drainReleased(x);
      self.postMessage({ type: "forgot", mem: memOf(x) });
    } catch (e) {
      self.postMessage(faultOf(x, e));
    }
    return;
  }
  if (m.type !== "job") return;
  const recv = performance.now();
  let x = null;
  try {
    if (ready === null) throw new Error("job before init");
    x = await ready;
  } catch (e) {
    self.postMessage({ type: "fault", code: 0, message: `worker could not start: ${e && e.message ? e.message : e}` });
    return;
  }
  const begin = performance.now();
  let r;
  try {
    r = runJob(x, m);
  } catch (e) {
    self.postMessage(faultOf(x, e));
    return;
  }
  if (userTiming && typeof m.program === "string") measure(m.program, r.call, r.ret);
  const output = r.output;
  self.postMessage({ type: "done", output: output.buffer, objects: r.objects, t: [recv, begin, r.call, r.ret, performance.now()], mem: memOf(x), prepareMs: r.prepareMs, held: x.metric(8) === 1n, handles: Number(x.metric(6)) }, [output.buffer]);
};
