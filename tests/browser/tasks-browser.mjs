// tasks-browser.mjs --wasm APP.wasm --runtime runtime.mjs --chrome PATH
//
// Browser contract test of worker tasks (design.md, "Workers"; Appendix B),
// with tests/apps/tasks in headless Chrome, for what specs cannot reach:
// the handles each side holds, a worker's memory, real downloads and real
// responses, the instances that must never perform an effect, and tasks
// stopped by termination and unmounting.
//
// - Ownership: after every job the worker's instance holds no handle (its
//   input files, its builders and its answer's files were all released and
//   drained), the page holds exactly the files the app keeps, and both
//   return to their baselines when the app lets go.
// - A large file is transformed in chunks with the worker's linear memory
//   bounded by a chunk, not by the file, and the output is exact.
// - `maxOutputBytes` refuses an append with TooLarge, and the job decides.
// - A running job cancelled mid-file is stopped by terminating its worker:
//   no answer, no handle on the page, and the next job runs on a fresh one.
// - A cancelled job of a task that says `on_cancel: Finish` runs on only
//   until its timeout: then its worker is ended with cause `timeout`.
// - Unmounting with a job running terminates it and delivers nothing.
// - The page's instance never performs an effect: its imports are stubs
//   that throw, and `work()` on a mounted instance is a classified contract
//   fault. In inline mode a task that reaches an effect is WorkLost
//   (Unavailable), the inline instance is replaced, and a task that reaches
//   none answers.
// - An answer whose files the page has no room for is WorkLost
//   (ResourceLimit), a download with no room is TooLarge, and the page
//   keeps the files it held.
// - A download becomes a file without the page's memory holding it, and a
//   task reads it; `File.save` starts a real download.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";

const opts = parseArgs(process.argv.slice(2));
const files = { ...runtimeFiles(opts.runtime), "app.wasm": opts.wasm };
// A CSV of 32 MiB served by the test's own server: 2^21 lines of 16 bytes.
const LINE = "1234567,abcdefg\n";
const CSV_LINES = 1 << 21;
const server = http.createServer((req, res) => {
  const u = new URL(req.url, "http://x");
  if (u.pathname === "/data.csv") {
    res.writeHead(200, { "content-type": "text/csv", "content-length": String(LINE.length * CSV_LINES) });
    const chunk = Buffer.from(LINE.repeat(1 << 14));
    let left = CSV_LINES >> 14;
    const pump = () => {
      while (left > 0) {
        left -= 1;
        if (!res.write(chunk)) return res.once("drain", pump);
      }
      res.end();
    };
    pump();
    return;
  }
  if (u.pathname === "/") {
    res.writeHead(200, { "content-type": "text/html" });
    res.end('<!doctype html><html><head><meta charset="utf-8"><title>tasks</title></head><body></body></html>');
    return;
  }
  const f = files[path.basename(u.pathname)];
  if (!f || !fs.existsSync(f)) {
    res.writeHead(404);
    res.end();
    return;
  }
  res.writeHead(200, { "content-type": f.endsWith(".wasm") ? "application/wasm" : "text/javascript" });
  res.end(fs.readFileSync(f));
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${server.address().port}`;
const browser = await launch({ executablePath: opts.chrome });

let failures = 0;
const check = (name, got, want) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  if (!ok) failures += 1;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok ? "" : `: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`}`);
};

function install() {
  // Every answer a worker posts, as the pool sees it: the instance's live
  // handles and memory after each job.
  const W = window.Worker;
  window.__answers = [];
  window.Worker = class extends W {
    constructor(url, options) {
      super(url, options);
      this.addEventListener("message", (e) => {
        const m = e.data;
        if (m && m.type === "done") window.__answers.push({ type: m.type, handles: m.handles, mem: m.mem, objects: (m.objects ?? []).length });
      });
    }
  };
  window.__mount = async (options = {}) => {
    const { mountRocEngineApp } = await import("/runtime.mjs");
    const root = document.createElement("div");
    document.body.append(root);
    window.__root = root;
    window.__faults = [];
    window.__rt = await mountRocEngineApp({ wasmUrl: "/app.wasm", root, onFault: () => {}, onWorkerFault: (f) => window.__faults.push(f), ...options });
    return true;
  };
  // Choose one file of `size` bytes, every byte the letter `fill`.
  window.__choose = (name, size, fill = "a") => {
    const dt = new DataTransfer();
    dt.items.add(new File([new Uint8Array(size).fill(fill.charCodeAt(0))], name, { type: "text/plain" }));
    const input = window.__root.querySelector('[aria-label="Upload"]');
    input.files = dt.files;
    input.dispatchEvent(new Event("change", { bubbles: true }));
  };
  window.__click = (label) => [...window.__root.querySelectorAll("button")].find((b) => b.textContent === label).click();
  window.__text = (id) => window.__root.querySelector(`[data-testid=${id}]`).textContent;
  window.__until = (id, pred, ms = 60000) =>
    new Promise((resolve, reject) => {
      const t = setTimeout(() => reject(new Error(`timed out: ${window.__text(id)}`)), ms);
      const tick = () => {
        if (pred(window.__text(id))) {
          clearTimeout(t);
          resolve(window.__text(id));
        } else setTimeout(tick, 5);
      };
      tick();
    });
  window.__pageHandles = () => Number(window.__rt.x.metric(6));
  window.__liveBytes = () => Number(window.__rt.x.metric(5));
  // The page's file named `name`, as the runtime holds it.
  window.__held = (name) => [...window.__rt.files.values()].find((f) => f.name === name);
}

async function open(options = {}) {
  const ctx = await browser.createBrowserContext();
  const page = await ctx.newPage();
  page.on("pageerror", (e) => console.log("pageerror", String(e)));
  await page.evaluateOnNewDocument(install);
  await page.goto(`${base}/`);
  await page.evaluate((o) => window.__mount(o), options);
  return { page, ctx };
}

// Ownership on both sides: the worker ends every job holding nothing; the
// page holds the input and the answer's file, and nothing once the app
// lets go of them.
{
  const { page, ctx } = await open();
  const r = await page.evaluate(async () => {
    const before = window.__pageHandles();
    window.__choose("small.txt", 1000);
    window.__click("Upper");
    const outcome = await window.__until("outcome", (t) => t !== "running");
    const held = window.__pageHandles();
    const files = window.__rt.files.size;
    const text = await window.__held("small.txt.upper").text();
    window.__click("Forget files");
    await new Promise((r) => setTimeout(r, 0));
    return {
      outcome,
      held: held - before,
      files,
      text: text === "A".repeat(1000),
      worker: window.__answers.map((x) => x.handles),
      after: window.__pageHandles() - before,
      filesAfter: window.__rt.files.size,
    };
  });
  check("a job leaves its worker holding no handle, and the page exactly the files the app keeps", r, { outcome: "built small.txt.upper:1000:text/plain", held: 2, files: 2, text: true, worker: [0], after: 0, filesAfter: 0 });
  await ctx.close();
}

// A 64 MiB file transformed 1 MiB at a time: the worker's memory stays near
// a chunk, and the output is the whole file, upper-cased.
{
  const { page, ctx } = await open({ maxWorkerBytes: 1 << 30 });
  const r = await page.evaluate(async () => {
    window.__choose("big.txt", 64 << 20, "q");
    const pageBytes = window.__liveBytes();
    window.__click("Upper in 1 MiB chunks");
    const outcome = await window.__until("outcome", (t) => t !== "running", 120000);
    const out = window.__held("big.txt.upper");
    const head = await out.slice(0, 4).text();
    const tail = await out.slice(out.size - 4).text();
    const answer = window.__answers[0];
    return {
      outcome,
      head,
      tail,
      workerMemoryUnder16MiB: answer.mem[0] < 16 << 20,
      workerMemory: answer.mem[0],
      pageGrewUnder1MiB: window.__liveBytes() - pageBytes < 1 << 20,
      handles: answer.handles,
    };
  });
  console.log(`     worker linear memory after a 64 MiB transform: ${(r.workerMemory / (1 << 20)).toFixed(1)} MiB`);
  delete r.workerMemory;
  check("a 64 MiB file is transformed with the worker's memory bounded by a chunk", r, { outcome: "built big.txt.upper:67108864:text/plain", head: "QQQQ", tail: "QQQQ", workerMemoryUnder16MiB: true, pageGrewUnder1MiB: true, handles: 0 });
  await ctx.close();
}

// The output bound: an append past maxOutputBytes is refused, the job sees
// TooLarge, and nothing reaches the page.
{
  const { page, ctx } = await open({ maxOutputBytes: 2000 });
  const r = await page.evaluate(async () => {
    window.__choose("k.txt", 1000);
    window.__click("Overflow");
    const outcome = await window.__until("outcome", (t) => t !== "running");
    return { outcome, page: window.__pageHandles(), worker: window.__answers.map((x) => x.handles) };
  });
  check("an append past maxOutputBytes is TooLarge, and the job's builder goes with it", r, { outcome: "error TooLarge", page: 1, worker: [0] });
  await ctx.close();
}

// A job cancelled while it reads: its worker is terminated (taking the
// builder's parts with it), nothing is delivered, and the next job runs on a
// fresh worker.
{
  const { page, ctx } = await open();
  const r = await page.evaluate(async () => {
    window.__choose("slow.txt", 4 << 20);
    // Four bytes at a time: a million reads, long enough to stop mid-file.
    window.__click("Upper");
    const busy = () => window.__rt.pool !== null && window.__rt.pool.slots.some((s) => s.job !== null);
    const t0 = performance.now();
    while (!busy() && performance.now() - t0 < 10000) await new Promise((r) => setTimeout(r, 5));
    await new Promise((r) => setTimeout(r, 300));
    const running = busy();
    window.__click("Stop");
    await new Promise((r) => setTimeout(r, 200));
    const pool = window.__rt.pool;
    const stopped = { outcome: window.__text("outcome"), built: window.__text("built"), page: window.__pageHandles(), answers: window.__answers.length, terminated: pool.terminated };
    // The next job runs on a fresh worker.
    window.__click("Upper in 1 MiB chunks");
    const next = await window.__until("outcome", (t) => t !== "running", 60000);
    return { running, stopped, next, created: pool.created, handles: window.__answers.map((x) => x.handles) };
  });
  check("a running job cancelled mid-file is stopped by terminating its worker, and delivers nothing", r, {
    running: true,
    stopped: { outcome: "stopped", built: "none", page: 1, answers: 0, terminated: 1 },
    next: "built slow.txt.upper:4194304:text/plain",
    created: 2,
    handles: [0],
  });
  await ctx.close();
}

// A cancelled job of a `Finish` task runs on with its answer dropped, but
// only until its timeout: a job that overruns it has its worker ended
// there, as a timed-out job's is, the monitor says why, and the next job
// runs on a fresh worker. "Linger" reads a 16 MiB file one byte at a time
// with a timeout of 1000 ms, so it overruns by far.
{
  const { page, ctx } = await open();
  const r = await page.evaluate(async () => {
    const events = [];
    window.__rt.monitor.subscribe((e) => events.push(e));
    window.__choose("long.txt", 16 << 20, "\n");
    const t0 = performance.now();
    window.__click("Linger");
    const busy = () => window.__rt.pool !== null && window.__rt.pool.slots.some((s) => s.job !== null);
    while (!busy() && performance.now() - t0 < 10000) await new Promise((r) => setTimeout(r, 5));
    await new Promise((r) => setTimeout(r, 200));
    window.__click("Stop");
    await new Promise((r) => setTimeout(r, 100));
    const finishing = { busy: busy(), terminated: window.__rt.pool.terminated };
    // The bound is the timeout from when the job was performed; allow the
    // loaded machine a few seconds past it.
    while (busy() && performance.now() - t0 < 6000) await new Promise((r) => setTimeout(r, 10));
    const endedAfterMs = performance.now() - t0;
    const s = window.__rt.monitor.snapshot();
    const cancelled = s.recent.find((x) => x.outcome === "cancelled");
    const ends = events.filter((e) => e.kind === "instance-end").map((e) => e.cause);
    window.__click("Square");
    const next = await window.__until("outcome", (t) => t !== "running", 30000);
    return { finishing, ended: { busy: busy(), timeout: s.instances.ended.timeout, ends, finished: cancelled ? cancelled.finished : null, poolBusy: s.pool.busy }, inTime: endedAfterMs < 6000, next, created: window.__rt.pool.created, answers: window.__answers.length };
  });
  check("a cancelled Finish job that overruns its timeout has its worker ended, and the next job runs", r, {
    finishing: { busy: true, terminated: 0 },
    ended: { busy: false, timeout: 1, ends: ["timeout"], finished: true, poolBusy: 0 },
    inTime: true,
    next: "size 49",
    created: 2,
    answers: 1,
  });
  await ctx.close();
}

// Unmounting with a job running terminates its worker and delivers nothing.
{
  const { page, ctx } = await open();
  const r = await page.evaluate(async () => {
    window.__choose("slow.txt", 4 << 20);
    window.__click("Upper");
    const busy = () => window.__rt.pool !== null && window.__rt.pool.slots.some((s) => s.job !== null);
    const t0 = performance.now();
    while (!busy() && performance.now() - t0 < 10000) await new Promise((r) => setTimeout(r, 5));
    await new Promise((r) => setTimeout(r, 300));
    const pool = window.__rt.pool;
    window.__rt.unmount();
    await new Promise((r) => setTimeout(r, 200));
    return { terminated: pool.terminated, answers: window.__answers.length, files: window.__rt.files.size, live: window.__rt.live.size };
  });
  check("unmounting with a job running terminates it and delivers nothing", r, { terminated: 1, answers: 0, files: 0, live: 0 });
  await ctx.close();
}

// The page's instance performs no effect: each import is a stub that throws,
// naming it, and work() on a mounted instance is a contract fault.
{
  const { page, ctx } = await open();
  const r = await page.evaluate(async () => {
    const { pageImports } = await import("/runtime.mjs");
    const module = window.__rt.module;
    const env = pageImports(module).env;
    const names = Object.keys(env).sort();
    const thrown = names.map((n) => {
      try {
        env[n]();
        return "returned";
      } catch (e) {
        return e.message.startsWith(`${n} is a worker effect`);
      }
    });
    // A second page instance of the module, mounted, asked to run a job.
    const inst = await WebAssembly.instantiate(module, pageImports(module));
    const x = inst.exports;
    x.boot_keys();
    x.payload_reserve(0);
    x.init();
    // Empty bytes are observationally the same as the complete default
    // sections, whose location is "/" (not an empty URL).
    const commands = (e) => Array.from(new Uint8Array(e.memory.buffer, e.cmd_ptr(), e.cmd_len()));
    const work = (e) => Array.from(new Uint8Array(e.memory.buffer, e.work_ptr(), e.work_len()));
    const defaults = new Uint8Array([
      1, 5, 0, 0, 0, 1, 0, 0, 0, 47,
      2, 5, 0, 0, 0, 1, 0, 0, 0, 0,
      3, 1, 0, 0, 0, 1,
      4, 1, 0, 0, 0, 1,
      6, 0, 0, 0, 0,
      7, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      8, 16, 0, 0, 0, ...new Array(16).fill(0),
      9, 13, 0, 0, 0, 1, 0, 0, 0, 5, 0, 0, 0, 101, 110, 45, 85, 83,
      10, 39, 0, 0, 0, 3, 0, 0, 0, 85, 84, 67,
      0, 0, 0, 0, 0, 0, 0, 128, 255, 255, 255, 255, 255, 255, 255, 127,
      1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 128, 0, 0, 0, 0,
    ]);
    const other = (await WebAssembly.instantiate(module, pageImports(module))).exports;
    other.boot_keys();
    const p = other.payload_reserve(defaults.length);
    new Uint8Array(other.memory.buffer, p, defaults.length).set(defaults);
    other.init();
    const emptyDefault = JSON.stringify([commands(x), work(x)]) === JSON.stringify([commands(other), work(other)]);
    other.drop();
    let trapped = false;
    try {
      x.work();
    } catch (_) {
      trapped = true;
    }
    const err = new TextDecoder().decode(new Uint8Array(x.memory.buffer, x.err_ptr(), x.err_len()));
    return { names, thrown, emptyDefault, trapped, fault: x.fault(), message: err.startsWith("contract: work() was called on the page's instance") };
  });
  check("the page's imports are throwing stubs, and work() on a mounted instance is a contract fault", r, {
    names: ["js_builder_append", "js_builder_append_file", "js_builder_finish", "js_builder_open", "js_file_read", "js_file_size"],
    thrown: [true, true, true, true, true, true],
    emptyDefault: true,
    trapped: true,
    fault: 1,
    message: true,
  });
  await ctx.close();
}

// Inline mode runs jobs on the page's thread, where a job's effects do not
// exist: a task that reaches one is WorkLost(Unavailable) and the inline
// instance it left mid-call is replaced; a task that reaches none answers,
// before and after, and the page is never poisoned.
{
  const { page, ctx } = await open({ workers: "inline" });
  const r = await page.evaluate(async () => {
    window.__click("Square");
    const before = await window.__until("outcome", (t) => t !== "running");
    window.__choose("i.txt", 10);
    window.__click("Upper");
    const effect = await window.__until("outcome", (t) => t !== "running");
    window.__click("Square");
    const after = await window.__until("outcome", (t) => t !== "running");
    const pool = window.__rt.pool;
    return { before, effect, after, faults: window.__faults.map((f) => f.class), page: window.__pageHandles(), poisoned: !!window.__rt.poisoned, created: pool.created, replaced: pool.terminated };
  });
  check("inline: a task reaching an effect is Unavailable, the next answers on a fresh instance", r, {
    before: "size 49",
    effect: "failed Lost(Unavailable)",
    after: "size 49",
    faults: ["unavailable"],
    page: 1,
    poisoned: false,
    created: 2,
    replaced: 1,
  });
  await ctx.close();
}

// An answer whose files the page has no room for: with 62 of the page's 64
// handles held, a job answering three files is WorkLost(ResourceLimit),
// reported to onWorkerFault like any lost job, and the page still holds
// exactly its 62.
{
  const { page, ctx } = await open();
  const r = await page.evaluate(async () => {
    const dt = new DataTransfer();
    for (let i = 0; i < 62; i += 1) dt.items.add(new File(["x"], `f${i}.txt`, { type: "text/plain" }));
    const input = window.__root.querySelector('[aria-label="Upload"]');
    input.files = dt.files;
    input.dispatchEvent(new Event("change", { bubbles: true }));
    window.__click("Few");
    const outcome = await window.__until("outcome", (t) => t !== "running");
    await new Promise((r) => setTimeout(r, 0));
    return { outcome, faults: window.__faults.map((f) => f.class), page: window.__pageHandles(), files: window.__rt.files.size };
  });
  check("an answer the page has no room for is WorkLost(ResourceLimit)", r, { outcome: "failed Lost(ResourceLimit)", faults: ["resource_limit"], page: 62, files: 62 });
  await ctx.close();
}

// A downloaded file counts among the page's 64 too: with all 64 held, a
// download has no room and is answered TooLarge, and the page still holds
// exactly its 64.
{
  const { page, ctx } = await open();
  const r = await page.evaluate(async () => {
    const dt = new DataTransfer();
    for (let i = 0; i < 64; i += 1) dt.items.add(new File(["x"], `f${i}.txt`, { type: "text/plain" }));
    const input = window.__root.querySelector('[aria-label="Upload"]');
    input.files = dt.files;
    input.dispatchEvent(new Event("change", { bubbles: true }));
    window.__click("Fetch");
    const outcome = await window.__until("outcome", (t) => t.startsWith("fetch"), 120000);
    await new Promise((r) => setTimeout(r, 0));
    return { outcome, fetched: window.__text("fetched"), page: window.__pageHandles(), files: window.__rt.files.size };
  });
  check("a download the page has no room for is TooLarge", r, { outcome: "fetch failed TooLarge", fetched: "none", page: 64, files: 64 });
  await ctx.close();
}

// A 32 MiB download becomes a file without entering the page's memory, and
// a task counts its lines.
{
  const { page, ctx } = await open();
  const r = await page.evaluate(async () => {
    const before = window.__liveBytes();
    window.__click("Fetch");
    const fetched = await window.__until("fetched", (t) => t !== "none", 120000);
    const grew = window.__liveBytes() - before;
    window.__click("Count lines in 1 MiB chunks");
    const outcome = await window.__until("outcome", (t) => t.startsWith("lines") || t.startsWith("failed"), 120000);
    return { fetched, pageGrewUnder1MiB: grew < 1 << 20, outcome, worker: window.__answers.map((x) => x.handles) };
  });
  check("a download becomes a file outside the page's memory, and a task reads it", r, { fetched: `data.csv:${16 << 21}:text/csv`, pageGrewUnder1MiB: true, outcome: `lines ${1 << 21}`, worker: [0] });
  await ctx.close();
}

// File.save starts a real download of the file's bytes under its name.
{
  const { page, ctx } = await open();
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "tasks-save-"));
  const begun = [];
  page.conn.on(page.sessionId, "Page.downloadWillBegin", (p) => begun.push(p.suggestedFilename));
  await page.send("Page.setDownloadBehavior", { behavior: "allow", downloadPath: dir });
  await page.evaluate(async () => {
    window.__choose("s.txt", 5, "x");
    window.__click("Upper");
    await window.__until("outcome", (t) => t !== "running");
    window.__click("Save");
  });
  const t0 = Date.now();
  const target = path.join(dir, "s.txt.upper");
  // The file can be on disk before the browser's notice that the download
  // began has been delivered, so wait for both.
  while (!(begun.length > 0 && fs.existsSync(target) && fs.readFileSync(target, "utf8") === "XXXXX") && Date.now() - t0 < 10000) await new Promise((r) => setTimeout(r, 50));
  check("File.save downloads the file's bytes under its name", { begun, bytes: fs.existsSync(target) ? fs.readFileSync(target, "utf8") : null }, { begun: ["s.txt.upper"], bytes: "XXXXX" });
  fs.rmSync(dir, { recursive: true, force: true });
  await ctx.close();
}

await browser.close();
server.close();
console.log(failures === 0 ? "== tasks-browser: all pass" : `== tasks-browser: ${failures} failed`);
process.exit(failures === 0 ? 0 : 1);
