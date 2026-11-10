// The generic worker script of the roc-signals runtime (design.md, "The
// Effect Channel" and Appendix B). `runtime.mjs` starts it as a module
// worker beside itself; it contains nothing specific to an app.
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
//   { type: "job", payload, program } — one job: `payload` (a transferred
//     ArrayBuffer) is `name:str input:rest`; `program` (its name) is sent
//     only when `userTiming` asked for a `roc:work.compute` measure here.
//     The worker stages it, calls the instance's `work()` export, and answers
//     { type: "done", output, t, mem } with the output bytes (transferred),
//     its stamps `t` = [received, instance ready, staged, returned, posted]
//     in this worker's clock, and `mem` = [linear memory bytes, live
//     allocations, live bytes] (the host's metric 4 and 5), or
//     { type: "fault", code, message } when the instance trapped (`code` is
//     the instance's fault class, 0 when it recorded none) or could not be
//     used. A faulted instance is never called again: the page discards
//     this worker.
//   A job whose request names files carries them as `files` (the browser's
//   `Blob`s, sliced to their ranges, sent by reference): they are read into
//   the instance's memory before the program runs, and a file that cannot
//   be read, or that the instance has no room for, is answered
//   { type: "filefail", reason } (Appendix B, result tag 13: 1 unreadable,
//   2 too large) without running the program. `t` then also counts the
//   read: `read` is how long it took and `fileBytes` how much it read.
//   Prepared programs (design.md, "Prepared programs"): a job's `mode` is
//   "work" (above; the default), "prepare" or "ask". A "prepare" job also
//   carries `prepare` (an ArrayBuffer, `prep:str init:rest`) and
//   `prepareFiles`: the worker lets go of any state it holds, reads those
//   files, calls `prepare()`, which keeps the new state, and then runs the
//   query in `payload` with `ask()`. An "ask" job runs `payload`
//   (`query:str input:rest`) on the state already held. `forget: true` on
//   a "work" job lets go of the held state before the job reads its files.
//   "done" then also carries `prepareMs` (the `prepare()` call, or null)
//   and `held` (whether the instance now holds a state).
//   { type: "forget" } — let go of the held state (eviction); answered
//     { type: "forgot", mem } once it has.
//   Tasks (design.md, "Tasks"): a job's `mode` "task" carries `objects`,
//   the browser's Blobs or Files its request names (whole, by reference),
//   and `maxOutputBytes`. The worker mints a handle for each in its
//   instance (`files_stage`), stages the payload and calls `task()`, during
//   which the task's hosted effects call the imports below: reading a range
//   of a file with FileReaderSync, and building files from parts. Its
//   answer, `n:u32 (token:u64)* output:rest`, names the files it holds: they
//   are posted back as { blob, name, type } in `objects` beside the output,
//   by reference. More than MAX_ANSWER_FILES is { type: "filefail", reason:
//   2 }. "done" also carries `handles`, the live handles left in the
//   instance after the job (0 when the job let go of everything).
// The page runs one job per worker at a time, and stops a job by
// terminating the worker; it sends "forget" only to an idle worker.

let ready = null;
let userTiming = false;
// Measures this worker has added to its own performance timeline; it clears
// them at 1024 (observers and DevTools traces have already seen them).
let measures = 0;

// The most files a task's answer may hold (design.md, "Boundedness").
const MAX_ANSWER_FILES = 16;

// What this instance's handles name, by token (a Number): a file,
// { blob, name, type }, or a builder, { parts, name, type, open }. A
// token's entry goes when the instance's host releases the handle
// (`files_released`, drained after each task job), so a builder's parts
// go with the job that made them, finished or not, and a terminated
// worker takes everything with it.
const held = new Map();

// The bytes a running task's job may still append (its maxOutputBytes).
let outputLeft = 0;

// The instance's exports, for the imports to reach its memory.
let exportsOf = null;

const textDecoder = new TextDecoder();

function readText(ptr, len) {
  return len === 0 ? "" : textDecoder.decode(new Uint8Array(exportsOf.memory.buffer, ptr, len));
}

// The worker halves of a task's hosted effects (`Hosted.roc`; `host.zig`
// calls them only inside `task()`). Tokens arrive as BigInts. Each answers
// a status the Roc side decides with; none throws for a job's mistakes.
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
    held.set(Number(token), { parts, name: readText(namePtr, nameLen), type: readText(mimePtr, mimeLen), open: true });
    return 0;
  },
  // The one copy of a written byte: out of linear memory into a part.
  js_builder_append(token, src, len) {
    const b = held.get(Number(token));
    if (b === undefined || b.open !== true) return 2;
    if (len > outputLeft) return 1;
    outputLeft -= len;
    if (len > 0) b.parts.push(new Blob([new Uint8Array(exportsOf.memory.buffer, src, len)]));
    return 0;
  },
  js_builder_append_file(token, file, start, len) {
    const b = held.get(Number(token));
    const f = held.get(Number(file));
    if (b === undefined || b.open !== true || f === undefined || f.blob === undefined) return 2;
    const s = Number(start);
    b.parts.push(f.blob.slice(s, s + Number(len)));
    return 0;
  },
  // Compose the parts into one immutable Blob (constant time; the parts are
  // referenced) behind the fresh handle `file`.
  js_builder_finish(token, file) {
    const b = held.get(Number(token));
    if (b === undefined || b.open !== true) return 2;
    held.set(Number(file), { blob: new Blob(b.parts, { type: b.type }), name: b.name, type: b.type });
    b.open = false;
    b.parts = [];
    return 0;
  },
};

// Let go of what the instance's host released: after a task's job, its
// input files, the builders it opened and the files of its answer, which
// were posted first.
function drainReleased(x) {
  const n = x.files_released();
  if (n === 0) return;
  const dv = new DataView(x.memory.buffer, x.files_tokens(), 8 * n);
  for (let i = 0; i < n; i += 1) held.delete(dv.getUint32(8 * i, true) + dv.getUint32(8 * i + 4, true) * 0x100000000);
}

// Run a task's job: mint a handle for each object, run the task, and
// return its output and the objects its answer holds, or a file failure.
function runTask(x, m) {
  const objects = m.objects ?? [];
  const n = x.files_stage(objects.length);
  if (n < objects.length) {
    x.files_stage(0);
    return { filefail: 2 };
  }
  const tokens = new DataView(x.memory.buffer, x.files_tokens(), 8 * n);
  for (let i = 0; i < n; i += 1) {
    const o = objects[i];
    held.set(tokens.getUint32(8 * i, true) + tokens.getUint32(8 * i + 4, true) * 0x100000000, { blob: o, name: o.name ?? "", type: o.type ?? "" });
  }
  outputLeft = m.maxOutputBytes ?? 0;
  stage(x, m.payload);
  const call = performance.now();
  x.task();
  const ret = performance.now();
  const answer = new Uint8Array(x.memory.buffer, x.cmd_ptr(), x.cmd_len());
  const dv = new DataView(answer.buffer, answer.byteOffset, answer.byteLength);
  const count = dv.getUint32(0, true);
  if (count > MAX_ANSWER_FILES) {
    drainReleased(x);
    return { filefail: 2, call, ret };
  }
  const out = [];
  for (let i = 0; i < count; i += 1) {
    const at = 4 + 8 * i;
    const entry = held.get(dv.getUint32(at, true) + dv.getUint32(at + 4, true) * 0x100000000);
    if (entry === undefined || entry.blob === undefined) throw new Error("a task's answer names a handle that is not a file");
    out.push({ blob: entry.blob, name: entry.name, type: entry.type });
  }
  const output = answer.slice(4 + 8 * count);
  drainReleased(x);
  return { output, objects: out, call, ret };
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

// Read the files a job names into an instance of the module, each into a
// buffer the instance's host reserves (`bytes_reserve`), streaming it so
// that no copy of the whole file exists outside linear memory. Throws
// { reason: 1 } when a file cannot be read and { reason: 2 } when the host
// has no room for one; `work()` then hands the buffers to the program.
async function readFiles(x, blobs) {
  let bytes = 0;
  for (const blob of blobs) {
    const ptr = x.bytes_reserve(blob.size);
    if (ptr === 0) throw { reason: 2 };
    if (blob.size === 0) continue;
    let at = ptr;
    try {
      const reader = blob.stream().getReader();
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        if (at + value.length > ptr + blob.size) throw new Error("the file grew while it was read");
        // A fresh view per chunk: nothing between them can grow memory, but
        // no view is ever held across an await.
        new Uint8Array(x.memory.buffer, at, value.length).set(value);
        at += value.length;
      }
    } catch (_) {
      throw { reason: 1 };
    }
    if (at !== ptr + blob.size) throw { reason: 1 };
    bytes += blob.size;
  }
  return bytes;
}

// Stage `payload` as the next call's payload.
function stage(x, payload) {
  const bytes = new Uint8Array(payload);
  const ptr = x.payload_reserve(bytes.length);
  // A fresh view: reserving may have grown memory.
  if (bytes.length > 0) new Uint8Array(x.memory.buffer, ptr, bytes.length).set(bytes);
}

// Returns the output and the stamps after staging and after the call
// (`work()`, or `ask()` on the held state).
function runJob(x, payload, ask) {
  stage(x, payload);
  const call = performance.now();
  if (ask) x.ask();
  else x.work();
  const ret = performance.now();
  return { output: new Uint8Array(x.memory.buffer, x.cmd_ptr(), x.cmd_len()).slice(), call, ret };
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
  const mode = m.mode ?? "work";
  if (mode === "task") {
    let r;
    try {
      r = runTask(x, m);
    } catch (e) {
      self.postMessage(faultOf(x, e));
      return;
    }
    if (r.filefail !== undefined) {
      self.postMessage({ type: "filefail", reason: r.filefail, held: x.metric(8) === 1n });
      return;
    }
    if (userTiming && typeof m.program === "string") measure(m.program, r.call, r.ret);
    const output = r.output;
    self.postMessage({ type: "done", output: output.buffer, objects: r.objects, t: [recv, begin, r.call, r.ret, performance.now()], mem: memOf(x), read: 0, fileBytes: 0, prepareMs: null, held: x.metric(8) === 1n, handles: Number(x.metric(6)) }, [output.buffer]);
    return;
  }
  let fileBytes = 0;
  let prepareMs = null;
  try {
    // A new state replaces the held one, and a job that reads files may
    // need the buffers a held state keeps: let it go before reading.
    if (mode === "prepare" || m.forget) x.forget();
    if (mode === "prepare") {
      if (m.prepareFiles && m.prepareFiles.length > 0) fileBytes += await readFiles(x, m.prepareFiles);
      stage(x, m.prepare);
      const t = performance.now();
      x.prepare();
      prepareMs = performance.now() - t;
    }
    if (m.files && m.files.length > 0) fileBytes += await readFiles(x, m.files);
  } catch (e) {
    if (e && (e.reason === 1 || e.reason === 2)) {
      x.bytes_clear();
      self.postMessage({ type: "filefail", reason: e.reason, held: x.metric(8) === 1n });
    } else self.postMessage(faultOf(x, e));
    return;
  }
  // Reading counts the files of both calls; the preparation is not reading.
  const read = fileBytes > 0 ? performance.now() - begin - (prepareMs ?? 0) : 0;
  let run;
  try {
    run = runJob(x, m.payload, mode !== "work");
  } catch (e) {
    self.postMessage(faultOf(x, e));
    return;
  }
  if (userTiming && typeof m.program === "string") measure(m.program, run.call, run.ret);
  const output = run.output;
  self.postMessage({ type: "done", output: output.buffer, t: [recv, begin, run.call, run.ret, performance.now()], mem: memOf(x), read, fileBytes, prepareMs, held: x.metric(8) === 1n }, [output.buffer]);
};
