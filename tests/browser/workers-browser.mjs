// workers-browser.mjs --wasm APP.wasm --runtime runtime.mjs --chrome PATH --
// browser contract test of the work request kind with tests/apps/workers in
// headless Chrome: jobs run in real Web Workers that instantiate the page's
// module (`worker.mjs` beside the runtime). It checks that a job runs off the
// page's thread, its result is one turn, several jobs in flight complete,
// jobs beyond `maxWorkers` queue, disposing the site cancels (CANCEL) and
// terminates the worker, a timeout answers Timeout, a crashing task is
// `WorkLost(AppCrash)` with the page still working, `workers: "inline"`
// gives the same results, a missing worker script is `WorkLost(Executor)`
// and no Worker is `WorkLost(Unavailable)`, an unregistered task is a
// contract fault that also stops the workers, and a protocol mismatch is
// refused by the runtime and by the worker script. In manual mode a job's
// timeout never fires on its own, and the spec hooks answer a pending job
// Timeout or WorkLost. It prints one-run smoke
// timings (`measure` lines); they are not asserted.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";

const opts = parseArgs(process.argv.slice(2));
const files = {
  ...runtimeFiles(opts.runtime),
  "app.wasm": opts.wasm,
};
const server = http.createServer((req, res) => {
  const u = new URL(req.url, "http://x");
  if (u.pathname === "/") {
    res.writeHead(200, { "content-type": "text/html" });
    res.end("<!doctype html><html><head><meta charset=\"utf-8\"><title>workers</title></head><body></body></html>");
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
const measure = (name, ms) => console.log(`measure ${name}: ${ms.toFixed(1)} ms (one run, smoke only)`);

// Page-side helpers, installed before any script runs. Options that are
// functions cannot cross `evaluate`, so `onWorkerFault` is always recorded
// into `__faults`.
function install() {
  window.__faults = [];
  window.__mount = async (options) => {
    const { mountRocEngineApp } = await import("/runtime.mjs");
    const root = document.createElement("div");
    document.body.append(root);
    window.__root = root;
    window.__rt = await mountRocEngineApp({ wasmUrl: "/app.wasm", root, onWorkerFault: (f) => window.__faults.push(f), ...options });
    return true;
  };
  window.__log = () => window.__root.querySelector("[data-testid=log]").textContent;
  window.__entries = () => (window.__log() === "" ? [] : window.__log().split("|"));
  window.__click = (label) => [...window.__root.querySelectorAll("button")].find((b) => b.textContent === label).click();
  window.__rounds = (n) => {
    const input = window.__root.querySelector("[aria-label=Rounds]");
    input.value = String(n);
    input.dispatchEvent(new Event("input", { bubbles: true }));
  };
  // Resolve once `pred(entries)` holds, with the elapsed time. A
  // MutationObserver sees the log's write as it happens (a nested
  // setTimeout poll would be clamped to 4 ms and blur the timings).
  window.__until = (pred, timeout = 20000) =>
    new Promise((resolve, reject) => {
      const t0 = performance.now();
      const log = window.__root.querySelector("[data-testid=log]");
      let timer = null;
      const done = () => {
        if (!pred(window.__entries())) return false;
        const t = performance.now() - t0;
        mo.disconnect();
        clearTimeout(timer);
        resolve(t);
        return true;
      };
      const mo = new MutationObserver(done);
      mo.observe(log, { childList: true, characterData: true, subtree: true });
      timer = setTimeout(() => {
        if (!done()) {
          mo.disconnect();
          reject(new Error(`timed out; log ${window.__log()}`));
        }
      }, timeout);
      done();
    });
  // Click `label` and resolve, once `pred(entries)` holds, with the time from
  // before the click (the issuing turn included).
  window.__timed = async (label, pred) => {
    const t0 = performance.now();
    window.__click(label);
    await window.__until(pred);
    return performance.now() - t0;
  };
  window.__metric = (k) => Number(window.__rt.x.metric(16 + k));
  // The pool's size and history, from the monitor's snapshot.
  window.__stats = () => {
    const s = window.__rt.monitor.snapshot();
    const terminated = Object.values(s.instances.ended).reduce((a, b) => a + b, 0);
    return { workers: s.pool.instances, busy: s.pool.busy, queued: s.pool.queued, created: s.instances.spawns, terminated };
  };
}

async function open(options, before = null) {
  const ctx = await browser.createBrowserContext();
  const page = await ctx.newPage();
  page.on("pageerror", (e) => console.log("pageerror", String(e)));
  await page.evaluateOnNewDocument(install);
  if (before) await page.evaluateOnNewDocument(before);
  await page.goto(`${base}/`);
  await page.evaluate((o) => window.__mount(o), options);
  return { page, ctx };
}

const CANCEL = 14;
const TURNS = 30;

// Rounds of the spin task that take at least about `ms` on this machine,
// measured with inline runs (the same module, on the page's thread) long
// enough that timer jitter does not dominate them. The fastest of three runs
// decides: a run that another process slowed down would choose too few
// rounds, and the jobs below would then be too short to tell anything.
async function calibrate(ms) {
  let per = Infinity;
  for (let i = 0; i < 3; i += 1) {
    const { page, ctx } = await open({ workers: "inline" });
    per = Math.min(
      per,
      await page.evaluate(async () => {
        window.__rounds(20000000);
        window.__click("Spin");
        const t = await window.__until((l) => l.some((e) => e.startsWith("spin:")));
        return t / 20000000;
      }),
    );
    await ctx.close();
  }
  return Math.max(1000, Math.round(ms / Math.max(per, 1e-9)));
}
const long = await calibrate(600);

// Off the page's thread: during a ~400 ms job the page's timers keep firing
// in worker mode; inline, the same job blocks them.
async function liveness(options) {
  const { page, ctx } = await open(options);
  const r = await page.evaluate(async (rounds) => {
    window.__rounds(rounds);
    let last = performance.now();
    let gap = 0;
    const h = setInterval(() => {
      const now = performance.now();
      gap = Math.max(gap, now - last);
      last = now;
    }, 5);
    window.__click("Spin");
    const elapsed = await window.__until((l) => l.some((e) => e.startsWith("spin:")));
    clearInterval(h);
    gap = Math.max(gap, performance.now() - last);
    return { gap, elapsed, entry: window.__entries().find((e) => e.startsWith("spin:")) };
  }, long);
  await ctx.close();
  return r;
}
{
  const inWorker = await liveness({});
  const inline = await liveness({ workers: "inline" });
  check("the job took long enough to tell (> 150 ms)", inWorker.elapsed > 150, true);
  // Both bounds are relative to the job each run measured, so a loaded
  // machine stretches the job and the bound together: a live page's longest
  // timer gap is a small part of the job, a blocked page's is most of it.
  check("worker mode: the page's thread stays live during the job (timer gaps under 100 ms, or under half the job on a loaded machine)", inWorker.gap < Math.max(100, inWorker.elapsed / 2), true);
  check("inline mode: the same job blocks the page's thread for most of the job", inline.gap > 0.6 * inline.elapsed, true);
  check("inline and worker give the same output", inline.entry, inWorker.entry);
  console.log(`     job ${inWorker.elapsed.toFixed(0)} ms; longest page-timer gap ${inWorker.gap.toFixed(0)} ms in a worker, ${inline.gap.toFixed(0)} ms inline`);
}

// One turn, rendered; cold and warm latency; reuse of the idle worker.
{
  const { page, ctx } = await open({});
  const r = await page.evaluate(async () => {
    const t0 = window.__metric(30);
    const c0 = performance.now();
    window.__click("Upper");
    const t1 = window.__metric(30);
    const cold = await window.__until((l) => l.length === 1).then(() => performance.now() - c0);
    const t2 = window.__metric(30);
    const stats = window.__stats();
    const warm = await window.__timed("Upper", (l) => l.length === 2);
    return { turns: [t1 - t0, t2 - t1], log: window.__log(), stats, after: window.__stats(), cold, warm };
  });
  check("the click is one turn and the result one more", r.turns, [1, 1]);
  check("the result renders", r.log, "upper:JOB 1|upper:JOB 2");
  check("one worker made, idle after its job, reused", [r.stats.workers, r.stats.busy, r.after.created], [1, 0, 1]);
  measure("cold pool: first work request to rendered result", r.cold);
  measure("warm worker: trivial job round trip to rendered result", r.warm);
  const lat = await page.evaluate(async () => {
    const times = [];
    for (let i = 0; i < 20; i += 1) {
      const n = window.__entries().length;
      times.push(await window.__timed("Upper", (l) => l.length === n + 1));
    }
    times.sort((a, b) => a - b);
    return times[10];
  });
  measure("warm worker: median of 20 trivial round trips", lat);
  check("no page errors", page.errors, []);
  await ctx.close();
}

// Several in flight, beyond the pool: four jobs, two workers.
{
  const { page, ctx } = await open({ maxWorkers: 2 });
  const r = await page.evaluate(async () => {
    window.__click("Batch");
    const during = window.__stats();
    await window.__until((l) => l.length === 4);
    return { during, after: window.__stats(), entries: window.__entries().sort() };
  });
  check("maxWorkers 2: two running, two queued", [r.during.workers, r.during.busy, r.during.queued], [2, 2, 2]);
  check("all four complete and render", r.entries, ["batch:B1-1", "batch:B1-2", "batch:B1-3", "batch:B1-4"]);
  check("the queue drained into the same two workers", [r.after.created, r.after.queued, r.after.busy], [2, 0, 0]);
  await ctx.close();
}

// Disposal cancels: CANCEL, the worker terminated, no result; the next job
// gets a fresh worker. Then a timeout, a crash and a slice of the input.
{
  const { page, ctx } = await open({});
  const r = await page.evaluate(async () => {
    window.__click("Panel");
    await new Promise((res) => setTimeout(res, 50));
    const running = window.__stats();
    const ids = [...window.__rt.live.keys()];
    const c0 = window.__metric(14);
    window.__click("Panel");
    const c1 = window.__metric(14);
    const after = window.__stats();
    const stillLive = ids.some((id) => window.__rt.live.has(id));
    await new Promise((res) => setTimeout(res, 300));
    const logAfter = window.__log();
    const t0 = performance.now();
    window.__click("Upper");
    await window.__until((l) => l.includes("upper:JOB 1"));
    const replace = performance.now() - t0;
    return { running, cancels: c1 - c0, after, stillLive, logAfter, replace, stats: window.__stats() };
  });
  check("panel job running in one worker", [r.running.workers, r.running.busy], [1, 1]);
  check("closing the panel emits one CANCEL", r.cancels, 1);
  check("its worker is terminated and the job forgotten", [r.after.workers, r.after.terminated, r.stillLive], [0, 1, false]);
  check("no result is delivered for the cancelled job", r.logAfter, "");
  check("the next job starts a fresh worker", [r.stats.created, r.stats.workers], [2, 1]);
  measure("terminate a busy worker and run the next job on a replacement", r.replace);

  const t = await page.evaluate(async (rounds) => {
    window.__rounds(rounds * 10);
    const terminated = window.__stats().terminated;
    const t0 = performance.now();
    window.__click("Slow");
    await window.__until((l) => l.some((e) => e.startsWith("slow:")));
    return { elapsed: performance.now() - t0, entry: window.__entries().find((e) => e.startsWith("slow:")), terminated: window.__stats().terminated - terminated, timers: window.__rt.timers };
  }, long);
  check("a 50 ms timeout delivers Timeout", t.entry, "slow:timeout");
  check("the timeout stopped the job well before it could finish", t.elapsed < 2000, true);
  check("the timeout terminated its worker and cleared its timer", [t.terminated, t.timers], [1, 0]);

  const c = await page.evaluate(async () => {
    window.__click("Crash");
    await window.__until((l) => l.some((e) => e.startsWith("crash:")));
    window.__click("Tail");
    window.__click("Tail");
    window.__click("Upper");
    await window.__until((l) => l.filter((e) => e.startsWith("tail:")).length === 2 && l.includes("upper:JOB 2"));
    return { entries: window.__entries(), faults: window.__faults, poisoned: window.__rt.poisoned };
  });
  check("a crashing task is WorkLost(AppCrash)", c.entries.find((e) => e.startsWith("crash:")), "crash:lost AppCrash");
  check("its diagnostic reaches onWorkerFault, not the result", c.faults.map((f) => [f.task, f.class, f.message]), [["test.roc-signals/crash", "app_crash", "the crash task crashed, as it always does"]]);
  check("the page keeps working after a worker crash", [c.poisoned, c.entries.filter((e) => e.startsWith("tail:")).sort(), c.entries.includes("upper:JOB 2")], [null, ["tail:tail 1", "tail:tail 2"], true]);
  await ctx.close();
}

// Inline mode gives the same results as workers.
async function results(options) {
  const { page, ctx } = await open(options);
  const r = await page.evaluate(async () => {
    window.__rounds(25);
    for (const b of ["Upper", "Batch", "Tail", "Tail", "Spin", "Crash"]) window.__click(b);
    await window.__until((l) => l.length === 9);
    return { entries: window.__entries().sort(), faults: window.__faults.map((f) => f.class) };
  });
  await ctx.close();
  return r;
}
{
  const inWorker = await results({});
  const inline = await results({ workers: "inline" });
  check("workers: the mixed results", inWorker.entries, ["batch:B1-1", "batch:B1-2", "batch:B1-3", "batch:B1-4", "crash:lost AppCrash", "spin:spun 25 841", "tail:tail 1", "tail:tail 2", "upper:JOB 1"]);
  check("inline: identical results and faults", inline, inWorker);
}

// The worker script cannot load: WorkLost(Executor). No Worker at all:
// WorkLost(Unavailable). The page keeps working in both.
{
  const { page, ctx } = await open({ workerUrl: "/missing-worker.mjs" });
  const r = await page.evaluate(async () => {
    window.__click("Upper");
    await window.__until((l) => l.length === 1);
    return { log: window.__log(), faults: window.__faults.map((f) => f.class), poisoned: window.__rt.poisoned };
  });
  check("a worker script that fails to load is WorkLost(Executor)", r, { log: "upper:lost Executor", faults: ["executor"], poisoned: null });
  await ctx.close();
}
{
  const { page, ctx } = await open({}, () => {
    window.Worker = undefined;
  });
  const r = await page.evaluate(async () => {
    window.__click("Upper");
    await window.__until((l) => l.length === 1);
    return { log: window.__log(), faults: window.__faults.map((f) => f.class), poisoned: window.__rt.poisoned };
  });
  check("no Worker constructor: WorkLost(Unavailable)", r, { log: "upper:lost Unavailable", faults: ["unavailable"], poisoned: null });
  await ctx.close();
}

// An unregistered task is a contract fault at issue time, naming the
// site; poisoning the page's runtime terminates its workers.
{
  const { page, ctx } = await open({});
  const r = await page.evaluate(async () => {
    window.__click("Panel");
    await new Promise((res) => setTimeout(res, 50));
    const before = window.__stats();
    window.__click("Missing");
    const p = window.__rt.poisoned;
    return { before, cls: p && p.class, message: p && p.message, after: window.__stats(), live: window.__rt.live.size };
  });
  check("a busy worker before the fault", r.before.busy, 1);
  check("an unregistered task is a contract fault", r.cls, "contract");
  check("the diagnostic names the task, the rule and the site", /^contract: worker task "test\.roc-signals\/missing" is not registered; add its registration to with_workers \(site \/[0-9/]+\)$/.test(r.message), true);
  console.log(`     ${r.message}`);
  check("poisoning the page terminated its workers", [r.after.workers, r.live], [0, 0]);
  await ctx.close();
}

// manualWork (soak walks): work jobs wait for runEffect as in manual mode,
// with no timeout timer and the monitor's `held` phase, while the rest of
// the effect channel runs on its own (here an interval subscription and
// storage reads are not held by it).
{
  const { page, ctx } = await open({ manualWork: true, maxWorkers: 1 });
  const r = await page.evaluate(async (rounds) => {
    const rt = window.__rt;
    window.__rounds(rounds);
    window.__click("Slow");
    window.__click("Upper");
    await new Promise((res) => setTimeout(res, 300));
    const waited = { log: window.__log(), pending: rt.pendingEffects().map((q) => q.task), timers: rt.timers, manual: rt.manual };
    const [slow, upper] = rt.issued;
    await rt.runEffect(slow);
    await rt.runEffect(upper);
    const recent = rt.monitor.snapshot().recent.map((j) => [j.task, j.outcome, j.ms.held > 0]);
    return { waited, log: window.__entries().map((e) => e.split(" ")[0]), recent, pool: rt.monitor.snapshot().pool.instances };
  }, long);
  check("manualWork: jobs wait without a timeout timer, the rest is not manual", [r.waited.log, r.waited.pending, r.waited.timers, r.waited.manual], ["", ["test.roc-signals/slow", "test.roc-signals/upper"], 0, false]);
  check("runEffect runs each past its timeout, in the order asked", r.log, ["slow:spun", "upper:JOB"]);
  check("the monitor saw both held, then answered", r.recent, [["test.roc-signals/slow", "done", true], ["test.roc-signals/upper", "done", true]]);
  check("one worker ran both", r.pool, 1);
  await ctx.close();
}

// Manual mode (spec replays): a job waits until the spec acts, and its
// timeout never fires on its own. runEffect runs it to completion past its
// timeout, expireEffect answers Timeout, loseEffect answers WorkLost with
// the class it names, each reported with the stable `roc worker fault [`
// prefix; none of them answers a job that is not pending or a request that
// is not a job.
{
  const { page, ctx } = await open({ manualEffects: true });
  const errors = [];
  page.on("console", (m) => {
    if (m.type() === "error") errors.push(m.text());
  });
  const r = await page.evaluate(async (rounds) => {
    const rt = window.__rt;
    window.__rounds(rounds);
    window.__click("Slow");
    await new Promise((res) => setTimeout(res, 300));
    const waited = { log: window.__log(), pending: rt.pendingEffects().map((q) => [q.op, q.task, q.timeout]), timers: rt.timers };
    const [slow] = rt.issued;
    const t0 = performance.now();
    await rt.runEffect(slow);
    const ran = { elapsed: performance.now() - t0, log: window.__log(), timers: rt.timers };
    window.__click("Slow");
    window.__click("Upper");
    window.__click("Crash");
    const [, second, upper, crash] = rt.issued;
    const refused = [rt.expireEffect(upper), rt.loseEffect(upper, "invented"), rt.expireEffect(slow), rt.loseEffect(slow, "app_crash")];
    const answered = [rt.expireEffect(second), rt.loseEffect(crash, "out_of_memory"), rt.loseEffect(upper, "executor")];
    return { waited, ran, refused, answered, entries: window.__entries(), faults: window.__faults.map((f) => [f.task, f.class]), pending: rt.pendingEffects().length };
  }, long);
  check("manual mode: a job with a timeout waits, with no timer armed", [r.waited.log, r.waited.pending, r.waited.timers], ["", [["work", "test.roc-signals/slow", 50]], 0]);
  check("runEffect runs it to completion past its timeout", [r.ran.log.startsWith("slow:spun "), r.ran.elapsed > 50, r.ran.timers], [true, true, 0]);
  check("expireEffect and loseEffect refuse a job without a timeout, an unknown class, and a job already answered", r.refused, [false, false, false, false]);
  check("expireEffect answers Timeout, loseEffect the class it names", [r.answered, r.entries.slice(1)], [[true, true, true], ["slow:timeout", "crash:lost OutOfMemory", "upper:lost Executor"]]);
  check("each lost job reaches onWorkerFault with its class", r.faults, [["test.roc-signals/crash", "out_of_memory"], ["test.roc-signals/upper", "executor"]]);
  check("and the console with the stable prefix", errors.map((e) => e.slice(0, e.indexOf("]") + 1)), ["roc worker fault [out_of_memory]", "roc worker fault [executor]"]);
  check("nothing is left pending", r.pending, 0);
  await ctx.close();
}

// Protocol: the runtime refuses a module of another version, and the
// worker script refuses a page of another version.
{
  const { page, ctx } = await open({});
  const r = await page.evaluate(async () => {
    const { RocEngineRuntime } = await import("/runtime.mjs");
    let refused = "";
    try {
      new RocEngineRuntime({ protocol_version: () => 3 }, document.createElement("div")).mount();
    } catch (e) {
      refused = String(e.message);
    }
    const w = new Worker("/worker.mjs", { type: "module" });
    const answer = new Promise((res) => {
      w.onmessage = (e) => res(e.data);
    });
    w.postMessage({ type: "init", module: window.__rt.module, version: 3 });
    const payload = new TextEncoder().encode("xxxx");
    w.postMessage({ type: "job", payload: payload.buffer }, [payload.buffer]);
    const m = await answer;
    w.terminate();
    return { refused, worker: [m.type, m.code, m.message] };
  });
  check("the runtime refuses a protocol 3 module", r.refused, "roc engine protocol 3 is not the protocol 12 this runtime implements");
  check("the worker script refuses a page of another protocol", r.worker, ["fault", 0, "worker could not start: page runtime protocol 3 is not the protocol 12 this worker implements"]);
  await ctx.close();
}

await browser.close();
server.close();
console.log(failures === 0 ? "== workers browser contract: all pass" : `== workers browser contract: ${failures} failures`);
process.exit(failures === 0 ? 0 : 1);
