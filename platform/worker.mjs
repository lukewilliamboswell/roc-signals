// The generic worker script of the roc-signals runtime (design.md, "The
// Effect Channel" and Appendix B). `runtime.mjs` starts it as a module
// worker beside itself; it contains nothing specific to an app.
//
// Messages from the page, in order:
//   { type: "init", module, version } — the page's compiled
//     `WebAssembly.Module` (the same module the page runs) and the protocol
//     version the page's runtime implements. The worker instantiates its own
//     instance, which never mounts.
//   { type: "job", payload } — one job: `payload` (a transferred
//     ArrayBuffer) is `name:str input:rest`. The worker stages it, calls the
//     instance's `work()` export, and answers
//     { type: "done", output } with the output bytes (transferred), or
//     { type: "fault", code, message } when the instance trapped (`code` is
//     the instance's fault class, 0 when it recorded none) or could not be
//     used. A faulted instance is never called again: the page discards
//     this worker.
// The page runs one job per worker at a time, and stops a job by
// terminating the worker.

let ready = null;

async function start(module, version) {
  const instance = await WebAssembly.instantiate(module, { env: {} });
  const x = instance.exports;
  const got = typeof x.protocol_version === "function" ? x.protocol_version() : 0;
  if (got !== version) throw new Error(`roc engine protocol ${got} is not the protocol ${version} the page's runtime implements`);
  if (typeof x.work !== "function") throw new Error("the module has no work export");
  return x;
}

function runJob(x, payload) {
  const bytes = new Uint8Array(payload);
  const ptr = x.payload_reserve(bytes.length);
  // A fresh view: reserving may have grown memory.
  if (bytes.length > 0) new Uint8Array(x.memory.buffer, ptr, bytes.length).set(bytes);
  x.work();
  return new Uint8Array(x.memory.buffer, x.cmd_ptr(), x.cmd_len()).slice();
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
    ready = start(m.module, m.version);
    ready.catch(() => {});
    return;
  }
  if (m.type !== "job") return;
  let x = null;
  try {
    if (ready === null) throw new Error("job before init");
    x = await ready;
  } catch (e) {
    self.postMessage({ type: "fault", code: 0, message: `worker could not start: ${e && e.message ? e.message : e}` });
    return;
  }
  let output;
  try {
    output = runJob(x, m.payload);
  } catch (e) {
    self.postMessage(faultOf(x, e));
    return;
  }
  self.postMessage({ type: "done", output: output.buffer }, [output.buffer]);
};
