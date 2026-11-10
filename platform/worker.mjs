// The generic worker script of the roc-signals runtime (design.md, "The
// Effect Channel" and Appendix B). `runtime.mjs` starts it as a module
// worker beside itself; it contains nothing specific to an app.
//
// Messages from the page, in order:
//   { type: "init", module, version, userTiming } — the page's compiled
//     `WebAssembly.Module` (the same module the page runs) and the protocol
//     version the page's runtime implements. The worker instantiates its own
//     instance, which never mounts, and answers
//     { type: "ready", origin, instStart, instEnd, memBytes }: its clock's
//     `performance.timeOrigin`, when instantiation started and ended, and
//     the instance's linear memory, for the page's monitor.
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
// The page runs one job per worker at a time, and stops a job by
// terminating the worker.

let ready = null;
let userTiming = false;
// Measures this worker has added to its own performance timeline; it clears
// them at 1024 (observers and DevTools traces have already seen them).
let measures = 0;

async function start(module, version) {
  const instStart = performance.now();
  const instance = await WebAssembly.instantiate(module, { env: {} });
  const instEnd = performance.now();
  const x = instance.exports;
  const got = typeof x.protocol_version === "function" ? x.protocol_version() : 0;
  if (got !== version) throw new Error(`roc engine protocol ${got} is not the protocol ${version} the page's runtime implements`);
  if (typeof x.work !== "function") throw new Error("the module has no work export");
  self.postMessage({ type: "ready", origin: performance.timeOrigin, instStart, instEnd, memBytes: x.memory.buffer.byteLength });
  return x;
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

// Returns the output and the stamps after staging and after `work()`.
function runJob(x, payload) {
  const bytes = new Uint8Array(payload);
  const ptr = x.payload_reserve(bytes.length);
  // A fresh view: reserving may have grown memory.
  if (bytes.length > 0) new Uint8Array(x.memory.buffer, ptr, bytes.length).set(bytes);
  const call = performance.now();
  x.work();
  const ret = performance.now();
  return { output: new Uint8Array(x.memory.buffer, x.cmd_ptr(), x.cmd_len()).slice(), call, ret };
}

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
  let fileBytes = 0;
  let read = 0;
  if (m.files && m.files.length > 0) {
    try {
      fileBytes = await readFiles(x, m.files);
    } catch (e) {
      if (e && (e.reason === 1 || e.reason === 2)) {
        x.bytes_clear();
        self.postMessage({ type: "filefail", reason: e.reason });
      } else self.postMessage(faultOf(x, e));
      return;
    }
    read = performance.now() - begin;
  }
  let run;
  try {
    run = runJob(x, m.payload);
  } catch (e) {
    self.postMessage(faultOf(x, e));
    return;
  }
  if (userTiming && typeof m.program === "string") measure(m.program, run.call, run.ret);
  const mem = [x.memory.buffer.byteLength, Number(x.metric(4)), Number(x.metric(5))];
  const output = run.output;
  self.postMessage({ type: "done", output: output.buffer, t: [recv, begin, run.call, run.ret, performance.now()], mem, read, fileBytes }, [output.buffer]);
};
