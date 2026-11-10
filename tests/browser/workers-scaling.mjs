// workers-scaling.mjs --wasm APP.wasm --runtime runtime.mjs --chrome PATH
//   [--mode smoke|full] [--label NAME] -- how worker jobs scale in headless
// Chrome, driven through the Worker Lab (examples/worker-lab) in real Web
// Workers and measured through the runtime's monitor (`runtime.monitor`:
// its snapshot and its events), never through timers of its own around the
// jobs.
//
// 1. Correctness: one prime run and one tile run give the same answers and
//    checksum as an independent implementation (worker-lab-reference.mjs)
//    with every pool size and with `workers: "inline"`.
// 2. Scaling: a fixed prime run at each pool size, after a warm-up run on
//    the same pool: wall time from the first job issued to the last job
//    ended, speedup against one worker, utilisation, queue-wait
//    percentiles and the overhead ratio.
// 3. Responsiveness: the page's longest gap (a timer loop, animation
//    frames, and long-animation-frame entries) while heavy jobs run in
//    workers and inline.
// 4. Payloads: tiles of increasing size, with their copy-out and transfer
//    spans.
// 5. Robustness, as sequences with the monitor's guarantees as the oracle:
//    a seeded random walk of starts, cancels, resets and parameter changes
//    over primes, tiles, deadlines and the crashing program; then a storm
//    of starts and cancels. Afterwards every issued job has exactly one end,
//    live instances never exceeded the pool, no reply came late, the page
//    never faulted, a clean run is correct, and unmounting terminates every
//    Worker the runtime created.
// 6. Memory: identical runs leave the long-lived instances' memory and
//    live allocations flat after warm-up.
//
// `--mode smoke` (the `check` gate) runs small job sets, two pool sizes and
// a short walk; it asserts correctness, structure (parallelism observed,
// sequences, memory) and responsiveness, and no timing ratio. `--mode full`
// (the `workers-scaling` task) adds the scaling assertions, adapted to
// `navigator.hardwareConcurrency`, and prints the tables to paste into a
// pull request.
import http from "node:http";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";
import { expectedRun } from "./worker-lab-reference.mjs";

const opts = parseArgs(process.argv.slice(2), ["mode", "label"]);
const MODE = opts.mode ?? "smoke";
if (MODE !== "smoke" && MODE !== "full") throw new Error(`--mode must be smoke or full (got ${MODE})`);
const FULL = MODE === "full";
const LABEL = opts.label ?? path.basename(path.dirname(path.resolve(opts.wasm)));

const files = { ...runtimeFiles(opts.runtime), "app.wasm": opts.wasm };
const server = http.createServer((req, res) => {
  const u = new URL(req.url, "http://x");
  if (u.pathname === "/") {
    res.writeHead(200, { "content-type": "text/html" });
    res.end("<!doctype html><html><head><meta charset=\"utf-8\"><title>worker scaling</title></head><body></body></html>");
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
const browser = await launch({ executablePath: opts.chrome, timeoutMs: 60000 });

let failures = 0;
const check = (name, ok, detail = "") => {
  if (!ok) failures += 1;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok || !detail ? "" : `: ${detail}`}`);
};
const skip = (name, why) => console.log(`skip ${name}: ${why}`);
const same = (name, got, want) => check(name, JSON.stringify(got) === JSON.stringify(want), `got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);

// Page-side helpers. `__events` holds every monitor event since the mount;
// `__workers` counts the Worker objects created and terminated (the
// runtime's own constructor, wrapped before it loads).
function install() {
  const Real = window.Worker;
  const workers = { created: 0, terminated: 0 };
  window.__workers = workers;
  if (Real) {
    window.Worker = class extends Real {
      constructor(...args) {
        super(...args);
        workers.created += 1;
      }
      terminate() {
        workers.terminated += 1;
        super.terminate();
      }
    };
  }
  window.__faults = [];
  window.__events = [];
  window.__mount = async (options) => {
    const { mountRocEngineApp } = await import("/runtime.mjs");
    const root = document.createElement("div");
    document.body.append(root);
    window.__root = root;
    window.__rt = await mountRocEngineApp({ wasmUrl: "/app.wasm", root, onWorkerFault: (f) => window.__faults.push(f), monitor: { history: 1024 }, ...options });
    window.__rt.monitor.subscribe((e) => window.__events.push(e));
    return true;
  };
  const control = (label) => window.__root.querySelector(`input[aria-label="${label}"], select[aria-label="${label}"]`);
  window.__set = (label, value) => {
    const el = control(label);
    el.value = String(value);
    el.dispatchEvent(new Event(el.tagName === "SELECT" ? "change" : "input", { bubbles: true }));
  };
  window.__click = (label) => [...window.__root.querySelectorAll("button")].find((b) => b.textContent === label).click();
  window.__text = (id) => window.__root.querySelector(`[data-testid="${id}"]`)?.textContent ?? null;
  window.__rows = () => [...window.__root.querySelectorAll("[data-testid^='job-']")].map((e) => e.textContent);
  // Resolve `true` once no job of the run is waiting or running, or `false`
  // after `limit` ms (reads no clock).
  window.__settled = (limit = 120000) =>
    new Promise((resolve) => {
      const el = window.__root.querySelector("[data-testid=checksum]");
      let mo = null;
      let timer = null;
      const done = () => {
        if (window.__text("checksum") === "pending") return false;
        mo?.disconnect();
        clearTimeout(timer);
        resolve(true);
        return true;
      };
      if (done()) return;
      mo = new MutationObserver(done);
      mo.observe(el, { childList: true, characterData: true, subtree: true });
      timer = setTimeout(() => {
        mo.disconnect();
        resolve(done());
      }, limit);
    });
  // Set the parameters and start a run; resolve with what the page shows
  // once it settled, and the run's events.
  window.__run = async ({ workload, jobs, weight, deadline = 0 }) => {
    window.__set("Workload", workload);
    window.__set("Jobs", jobs);
    window.__set("Weight", weight);
    window.__set("Deadline (ms)", deadline);
    const from = window.__events.length;
    window.__click("Start");
    if (!(await window.__settled())) throw new Error(`run did not settle; progress ${window.__text("progress")}`);
    return { rows: window.__rows(), checksum: window.__text("checksum"), primes: window.__text("primes"), bytes: window.__text("tile-bytes"), events: window.__events.slice(from) };
  };
  window.__sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  // Gaps on the page's thread while `body` runs: a 1 ms timer loop (Chrome
  // clamps it to about 4 ms), animation frames, and long-animation-frame
  // entries where the browser reports them.
  window.__gaps = async (body) => {
    let stop = false;
    let timerGap = 0;
    let frameGap = 0;
    let last = performance.now();
    const loop = () => {
      const t = performance.now();
      timerGap = Math.max(timerGap, t - last);
      last = t;
      if (!stop) setTimeout(loop, 1);
    };
    setTimeout(loop, 1);
    let lastFrame = null;
    let frames = 0;
    const frame = (t) => {
      if (lastFrame !== null) frameGap = Math.max(frameGap, t - lastFrame);
      lastFrame = t;
      frames += 1;
      if (!stop) requestAnimationFrame(frame);
    };
    requestAnimationFrame(frame);
    const loaf = [];
    let observer = null;
    if (PerformanceObserver.supportedEntryTypes?.includes("long-animation-frame")) {
      observer = new PerformanceObserver((list) => {
        for (const e of list.getEntries()) loaf.push(e.duration);
      });
      observer.observe({ type: "long-animation-frame" });
    }
    const beat0 = Number(window.__text("heartbeat"));
    const result = await body();
    stop = true;
    observer?.disconnect();
    return { result, timerGap, frameGap: frames > 1 ? frameGap : null, loafMax: observer ? Math.max(0, ...loaf) : null, loafCount: observer ? loaf.length : null, beats: Number(window.__text("heartbeat")) - beat0 };
  };
}

async function open(options) {
  const ctx = await browser.createBrowserContext();
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  await page.evaluateOnNewDocument(install);
  await page.goto(`${base}/`);
  await page.evaluate((o) => window.__mount(o), options);
  return { page, ctx, errors };
}

const quantile = (xs, q) => {
  if (xs.length === 0) return NaN;
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.max(0, Math.ceil(q * s.length) - 1))];
};
const median = (xs) => quantile(xs, 0.5);
const f1 = (v) => (v === null || v === undefined || !Number.isFinite(v) ? "–" : v.toFixed(1));
const f2 = (v) => (v === null || v === undefined || !Number.isFinite(v) ? "–" : v.toFixed(2));
const table = (head, rows) => [`| ${head.join(" | ")} |`, `|${head.map(() => "---").join("|")}|`, ...rows.map((r) => `| ${r.join(" | ")} |`)].join("\n");

// The figures of one measured run, from its monitor events and the
// snapshot taken right after it settled (the window was reset just before).
function figures(events, snapshot) {
  const issues = events.filter((e) => e.kind === "job-issue");
  const ends = events.filter((e) => e.kind === "job-end");
  const recs = ends.map((e) => e.record).filter((r) => r.outcome === "done");
  const compute = recs.map((r) => r.ms.compute);
  const total = recs.map((r) => r.ms.total);
  const sum = (xs) => xs.reduce((a, b) => a + b, 0);
  return {
    jobs: recs.length,
    wall: issues.length && ends.length ? Math.max(...ends.map((e) => e.at)) - Math.min(...issues.map((e) => e.at)) : NaN,
    util: snapshot.pool.aliveMs > 0 ? snapshot.pool.busyMs / snapshot.pool.aliveMs : NaN,
    queueP50: median(recs.map((r) => r.ms.queue)),
    queueP95: quantile(recs.map((r) => r.ms.queue), 0.95),
    computeP50: median(compute),
    computeSum: sum(compute),
    overhead: 1 - sum(compute) / sum(total),
    transit: sum(recs.map((r) => r.ms.total - r.ms.queue - r.ms.compute)) / sum(total),
    peakBusy: snapshot.pool.peak.busy,
  };
}

// Compare a run the page showed with the reference.
function verify(name, shown, params) {
  const want = expectedRun(params);
  const rows = want.answers.map((a) => (a === null ? null : a.text));
  const bad = shown.rows.map((r, i) => (r === rows[i] ? null : `job ${i + 1}: ${r} (want ${rows[i]})`)).filter((x) => x !== null);
  check(`${name}: ${params.jobs} answers and checksum ${want.checksum}`, bad.length === 0 && shown.rows.length === params.jobs && shown.checksum === want.checksum, `${bad.slice(0, 3).join("; ")}; checksum ${shown.checksum}`);
  return want;
}

const loadavg = () => os.loadavg().map((l) => l.toFixed(1)).join(", ");
const cores = await (async () => {
  const { page, ctx } = await open({});
  const n = await page.evaluate(() => navigator.hardwareConcurrency || 1);
  await ctx.close();
  return n;
})();
const POOLS = FULL ? [1, 2, 4, 8] : [1, 2];
const REPEAT = FULL ? 3 : 1;
console.log(`== workers scaling (${MODE}, ${LABEL}): ${cores} cores reported by navigator.hardwareConcurrency; load average ${loadavg()}`);

// Job sets. A prime job's weight sets its compute: in the size-optimised
// build a job of weight 128 takes some tens of milliseconds (more for the
// later, larger numbers), so the full run's 48 jobs keep 8 workers busy far
// longer than any start-up or frame, and a responsiveness job of weight 256
// holds the thread it runs on for a good fraction of a second. The smoke
// sets are small, for the unoptimised build `check` makes; its heavy jobs
// are still long enough that an inline run stalls the page visibly.
const PRIMES = FULL ? { workload: "primes", jobs: 48, weight: 128 } : { workload: "primes", jobs: 8, weight: 2 };
const TILES = FULL ? { workload: "tiles", jobs: 9, weight: 32 } : { workload: "tiles", jobs: 4, weight: 4 };
const HEAVY = FULL ? { workload: "primes", jobs: 8, weight: 256 } : { workload: "primes", jobs: 3, weight: 96 };

// -- 1. Correctness, and 2. scaling -----------------------------------------
const scaling = [];
for (const mode of [...POOLS.map((n) => ({ maxWorkers: n })), { workers: "inline" }]) {
  const name = mode.workers === "inline" ? "inline" : `${mode.maxWorkers} worker${mode.maxWorkers === 1 ? "" : "s"}`;
  const { page, ctx, errors } = await open(mode);
  const tiles = await page.evaluate((p) => window.__run(p), TILES);
  verify(`correct, ${name}, tiles`, tiles, TILES);
  // The prime run once to warm the pool (cold starts, compilation), then
  // measured from a fresh monitor window.
  const warm = await page.evaluate((p) => window.__run(p), PRIMES);
  verify(`correct, ${name}, primes`, warm, PRIMES);
  // REPEAT measured runs, each in a fresh monitor window; the one with the
  // median wall time is reported, with the spread of all of them.
  const runs = [];
  for (let k = 0; k < REPEAT; k += 1) {
    const r = await page.evaluate(async (p) => {
      window.__rt.monitor.reset();
      const run = await window.__run(p);
      return { run, s: window.__rt.monitor.snapshot() };
    }, PRIMES);
    verify(`correct, ${name}, measured run ${k + 1}`, r.run, PRIMES);
    runs.push(figures(r.run.events, r.s));
  }
  runs.sort((a, b) => a.wall - b.wall);
  const fig = runs[Math.floor(runs.length / 2)];
  scaling.push({ name, workers: mode.maxWorkers ?? null, ...fig, walls: runs.map((x) => x.wall) });
  if (mode.maxWorkers) check(`${name}: the pool ran ${Math.min(mode.maxWorkers, PRIMES.jobs)} jobs at once at its peak`, fig.peakBusy === Math.min(mode.maxWorkers, PRIMES.jobs), `peak busy ${fig.peakBusy}`);
  check(`${name}: no page errors`, errors.length === 0, errors.join("; "));
  await ctx.close();
}
{
  const one = scaling.find((s) => s.workers === 1);
  const rows = scaling.map((s) => [s.name, f1(s.wall), s.walls.map((w) => w.toFixed(0)).join(" / "), f2(one.wall / s.wall), f2(s.util), f1(s.queueP50), f1(s.queueP95), f1(s.computeP50), f1(s.computeSum), f2(s.overhead), f2(s.transit)]);
  console.log(`\nScaling (${LABEL}; ${PRIMES.jobs} prime jobs of weight ${PRIMES.weight}; after a warm-up run, the median of ${REPEAT} measured run${REPEAT === 1 ? "" : "s"}):\n`);
  console.log(table(["pool", "wall ms", "all walls ms", "speedup", "utilisation", "queue p50 ms", "queue p95 ms", "compute p50 ms", "compute sum ms", "overhead", "non-queue overhead"], rows));
  console.log("");
  // Thresholds. A pool of k workers needs k cores for them and one for the
  // page, so a speedup is asserted only where navigator.hardwareConcurrency
  // is at least k + 1; elsewhere the machine cannot show it, and the
  // assertion is skipped and says so. Where it applies, the speedup must
  // be at least 0.55k: under that, more than half of the added workers'
  // capacity was lost, which no warm, CPU-bound, evenly sized job set
  // explains, while a healthy pool stays well above it (the 15-job
  // admission window keeps 8 workers fed; the tail of the last jobs and
  // the logical-core count reported by the browser are the slack). A pool
  // that serialises its jobs reaches about 1 and fails every case.
  //
  // The same jobs cost the same CPU time on any pool size, unless the
  // machine is not giving the workers their cores (other processes, power
  // limits). So when the run's summed compute exceeds 1.6 times the
  // one-worker run's, the machine was contended and a speedup says nothing
  // about the pool: the assertion is skipped, naming the inflation and the
  // load average, rather than failed or passed.
  for (const s of scaling.filter((x) => x.workers && x.workers > 1)) {
    const want = 0.55 * s.workers;
    const inflation = s.computeSum / one.computeSum;
    if (!FULL) skip(`speedup with ${s.name}`, "smoke mode asserts no timing ratio");
    else if (cores < s.workers + 1) skip(`speedup with ${s.name} >= ${f2(want)}`, `the machine reports ${cores} cores; ${s.workers} workers and the page need ${s.workers + 1}`);
    else if (inflation > 1.6) skip(`speedup with ${s.name} >= ${f2(want)} (got ${f2(one.wall / s.wall)})`, `the machine was contended: the same jobs took ${f2(inflation)} times the one-worker run's compute (load average ${loadavg()})`);
    else check(`speedup with ${s.name} >= ${f2(want)}`, one.wall / s.wall >= want, `got ${f2(one.wall / s.wall)}`);
  }
}

// -- 3. Responsiveness ------------------------------------------------------
const responsive = {};
for (const mode of [{ maxWorkers: Math.max(1, Math.min(8, cores - 1)) }, { workers: "inline" }]) {
  const key = mode.workers === "inline" ? "inline" : "workers";
  const { page, ctx } = await open(mode);
  await page.evaluate((p) => window.__run(p), HEAVY);
  const g = await page.evaluate(async (p) => {
    window.__rt.monitor.reset();
    const r = await window.__gaps(() => window.__run(p));
    return { ...r, s: window.__rt.monitor.snapshot(), result: { rows: r.result.rows, checksum: r.result.checksum, events: r.result.events } };
  }, HEAVY);
  verify(`correct, responsiveness run ${key}`, g.result, HEAVY);
  const fig = figures(g.result.events, g.s);
  responsive[key] = { ...g, fig, label: key === "inline" ? "inline" : `${mode.maxWorkers} workers` };
  await ctx.close();
}
{
  const w = responsive.workers;
  const i = responsive.inline;
  console.log(`\nResponsiveness (${LABEL}; ${HEAVY.jobs} prime jobs of weight ${HEAVY.weight}; one run each):\n`);
  console.log(
    table(
      ["mode", "wall ms", "compute p50 ms", "longest timer gap ms", "longest frame gap ms", "long animation frames", "longest LoAF ms", "heartbeats (every 200 ms)"],
      [w, i].map((x) => [x.label, f1(x.fig.wall), f1(x.fig.computeP50), f1(x.timerGap), f1(x.frameGap), x.loafCount ?? "–", f1(x.loafMax), String(x.beats)]),
    ),
  );
  console.log("");
  // Inline, each job holds the page's thread for its whole compute, so the
  // longest gap is at least most of one job; in workers the page only
  // applies result turns, so its longest gap stays below half the inline
  // one and below one job's compute.
  check("inline: the page stalls for most of a job (longest gap >= 0.8 x compute p50)", i.timerGap >= 0.8 * i.fig.computeP50, `gap ${f1(i.timerGap)}, compute ${f1(i.fig.computeP50)}`);
  check("workers: the page stays responsive (longest gap < 0.5 x the inline gap and < compute p50)", w.timerGap < 0.5 * i.timerGap && w.timerGap < w.fig.computeP50, `workers ${f1(w.timerGap)}, inline ${f1(i.timerGap)}, compute ${f1(w.fig.computeP50)}`);
  check("workers: the heartbeat kept counting", w.beats >= Math.floor(w.fig.wall / 200) - 2, `${w.beats} beats in ${f1(w.fig.wall)} ms`);
}

// -- 4. Payloads ------------------------------------------------------------
{
  const weights = FULL ? [16, 32, 64, 128, 256] : [8, 64];
  const { page, ctx } = await open({ maxWorkers: 4 });
  await page.evaluate(() => window.__run({ workload: "tiles", jobs: 4, weight: 4 }));
  const rows = [];
  for (const weight of weights) {
    const params = { workload: "tiles", jobs: 4, weight };
    // Each size once to warm every worker's compiled code for it, then
    // measured.
    await page.evaluate((p) => window.__run(p), params);
    const r = await page.evaluate(async (p) => {
      window.__rt.monitor.reset();
      return window.__run(p);
    }, params);
    verify(`correct, tiles of ${weight * 4} pixels`, r, params);
    const recs = r.events.filter((e) => e.kind === "job-end").map((e) => e.record);
    const m = (k) => median(recs.map((x) => x.ms[k]));
    rows.push([String(weight * 4), String(recs[0].outputBytes), f1(m("compute")), f2(m("copyOut")), f2(m("fromWorker")), f2(m("resultWait")), f1(m("resultTurn")), f1(m("total"))]);
  }
  await ctx.close();
  console.log(`\nPayloads (${LABEL}; 4 tiles per size on 4 workers; medians over the tiles of one measured run per size, after a warm-up run):\n`);
  console.log(table(["tile side px", "output bytes", "compute ms", "copy-out ms", "transfer back ms", "result wait ms", "result turn ms", "total ms"], rows));
  console.log("");
}

// -- 5. Robustness ----------------------------------------------------------
// Every issued job has exactly one end (a start, if any, between them), and
// live instances never exceed `max`.
function sequenceProblems(events, max) {
  const problems = [];
  const jobs = new Map();
  let live = 0;
  let peak = 0;
  for (const e of events) {
    if (e.kind === "job-issue") {
      if (jobs.has(e.id)) problems.push(`job ${e.id} issued twice`);
      jobs.set(e.id, "issued");
    } else if (e.kind === "job-start") {
      if (jobs.get(e.id) !== "issued") problems.push(`job ${e.id} started while ${jobs.get(e.id)}`);
      jobs.set(e.id, "started");
    } else if (e.kind === "job-end") {
      if (!["issued", "started"].includes(jobs.get(e.id))) problems.push(`job ${e.id} ended while ${jobs.get(e.id)}`);
      jobs.set(e.id, "ended");
    } else if (e.kind === "instance-spawn") {
      live += 1;
      peak = Math.max(peak, live);
    } else if (e.kind === "instance-end") live -= 1;
  }
  const open = [...jobs].filter(([, s]) => s !== "ended").map(([id]) => id);
  if (open.length > 0) problems.push(`${open.length} jobs never ended (${open.slice(0, 5).join(", ")})`);
  if (peak > max) problems.push(`${peak} instances live at once, more than ${max}`);
  return { problems, jobs: jobs.size, peak, live };
}

async function quiesce(page) {
  return page.evaluate(async () => {
    window.__click("Cancel");
    for (let i = 0; i < 2000 && window.__rt.monitor.snapshot().jobs.inFlight > 0; i += 1) await window.__sleep(5);
    return window.__rt.monitor.snapshot().jobs.inFlight;
  });
}

async function unmountChecks(page, name) {
  const u = await page.evaluate(async () => {
    window.__rt.unmount();
    await window.__sleep(20);
    const s = window.__rt.monitor.snapshot();
    return { workers: window.__workers, live: s.instances.live.length, state: s.state, spawns: window.__events.filter((e) => e.kind === "instance-spawn").length, ends: window.__events.filter((e) => e.kind === "instance-end").length };
  });
  check(`${name}: unmount terminates every Worker the runtime created (${u.workers.created})`, u.workers.created === u.workers.terminated, JSON.stringify(u.workers));
  check(`${name}: after unmount no instance is live, and every spawn has its end`, u.live === 0 && u.spawns === u.ends && u.state === "unmounted", JSON.stringify(u));
}

const robustness = [];
{
  const max = 4;
  const steps = FULL ? 600 : 120;
  const { page, ctx, errors } = await open({ maxWorkers: max });
  const t0 = Date.now();
  const walk = await page.evaluate(async (n) => {
    let seed = 0x5eedn;
    const rnd = () => {
      seed = (seed * 6364136223846793005n + 1442695040888963407n) & 0xffffffffffffffffn;
      return Number(seed >> 33n);
    };
    const ops = { params: 0, start: 0, cancel: 0, reset: 0, settle: 0, wait: 0 };
    const workloads = ["primes", "tiles", "faulty"];
    for (let i = 0; i < n; i += 1) {
      if (window.__rt.poisoned) break;
      const r = rnd() % 100;
      if (r < 25) {
        ops.params += 1;
        const which = rnd() % 4;
        if (which === 0) window.__set("Workload", workloads[rnd() % 3]);
        else if (which === 1) window.__set("Jobs", 1 + (rnd() % 24));
        else if (which === 2) window.__set("Weight", 1 + (rnd() % 6));
        else window.__set("Deadline (ms)", rnd() % 3 === 0 ? 1 + (rnd() % 30) : 0);
      } else if (r < 50) {
        ops.start += 1;
        window.__click("Start");
      } else if (r < 62) {
        ops.cancel += 1;
        window.__click("Cancel");
      } else if (r < 68) {
        ops.reset += 1;
        window.__click("Reset");
      } else if (r < 74) {
        // Let the run finish (or a second pass), so answers, crashes and
        // deadlines happen, not only cancellations.
        ops.settle += 1;
        await window.__settled(1000);
      } else {
        ops.wait += 1;
        await window.__sleep(rnd() % 40);
      }
    }
    return { ops, poisoned: window.__rt.poisoned };
  }, steps);
  const inFlight = await quiesce(page);
  const after = await page.evaluate(() => ({ s: window.__rt.monitor.snapshot(), faults: window.__faults.map((f) => f.class), events: window.__events }));
  const seq = sequenceProblems(after.events, max);
  const s = after.s;
  check(`walk: ${steps} steps (${JSON.stringify(walk.ops)}) without a page fault`, walk.poisoned === null && errors.length === 0, JSON.stringify({ poisoned: walk.poisoned, errors }));
  check(`walk: every one of ${seq.jobs} issued jobs has exactly one end; at most ${max} instances live`, seq.problems.length === 0 && inFlight === 0, seq.problems.join("; "));
  check("walk: no late replies, and the pool's peak within its bound", s.jobs.lateReplies === 0 && s.pool.peak.instances <= max, JSON.stringify({ late: s.jobs.lateReplies, peak: s.pool.peak }));
  check("walk: every lost job is a crash of the crash program, reported once", after.faults.length === s.jobs.lost && after.faults.every((c) => c === "app_crash"), JSON.stringify({ faults: after.faults.length, lost: s.jobs.lost }));
  // The oracles above mean something only if the walk reached every
  // outcome; the full walk is long enough to.
  if (FULL) check("walk: it reached answers, deadlines, crashes and cancellations", s.jobs.done > 0 && s.jobs.timeout > 0 && s.jobs.lost > 0 && s.jobs.cancelled > 0, JSON.stringify(s.jobs));
  robustness.push(["random walk", `${steps} steps in ${Date.now() - t0} ms`, String(seq.jobs), String(s.jobs.done), String(s.jobs.cancelled), String(s.jobs.timeout), String(s.jobs.lost), String(s.instances.spawns), String(seq.peak), String(s.jobs.lateReplies)]);
  const clean = await page.evaluate((p) => window.__run(p), PRIMES);
  verify("walk: a clean run afterwards", clean, PRIMES);
  await unmountChecks(page, "walk");
  await ctx.close();
}
{
  const max = 4;
  const cycles = FULL ? 300 : 100;
  const { page, ctx, errors } = await open({ maxWorkers: max });
  const t0 = Date.now();
  await page.evaluate(async (n) => {
    window.__set("Workload", "primes");
    window.__set("Jobs", 16);
    window.__set("Weight", 4);
    window.__set("Deadline (ms)", 0);
    for (let i = 0; i < n; i += 1) {
      window.__click("Start");
      if (i % 3 === 0) await window.__sleep(0);
      window.__click("Cancel");
      if (i % 10 === 0) await window.__sleep(1);
    }
  }, cycles);
  const inFlight = await quiesce(page);
  const after = await page.evaluate(() => ({ s: window.__rt.monitor.snapshot(), events: window.__events, poisoned: window.__rt.poisoned }));
  const seq = sequenceProblems(after.events, max);
  const s = after.s;
  check(`cancel storm: ${cycles} starts and cancels; every issued job (${seq.jobs}) has exactly one end, at most ${max} instances live`, seq.problems.length === 0 && inFlight === 0 && after.poisoned === null && errors.length === 0, seq.problems.join("; "));
  check("cancel storm: the pool is healthy (no late replies, nothing queued or busy)", s.jobs.lateReplies === 0 && s.pool.queued === 0 && s.pool.busy === 0, JSON.stringify(s.pool));
  robustness.push(["cancel storm", `${cycles} cycles in ${Date.now() - t0} ms`, String(seq.jobs), String(s.jobs.done), String(s.jobs.cancelled), String(s.jobs.timeout), String(s.jobs.lost), String(s.instances.spawns), String(seq.peak), String(s.jobs.lateReplies)]);
  const clean = await page.evaluate((p) => window.__run(p), PRIMES);
  verify("cancel storm: a clean run afterwards", clean, PRIMES);
  await unmountChecks(page, "cancel storm");
  await ctx.close();
}
console.log(`\nRobustness (${LABEL}; maxWorkers 4; one run each):\n`);
console.log(table(["sequence", "length", "jobs issued", "done", "cancelled", "timed out", "lost", "instance spawns", "peak live instances", "late replies"], robustness));
console.log("");

// -- 6. Memory --------------------------------------------------------------
{
  const runs = FULL ? 10 : 6;
  const warmup = 3;
  const { page, ctx } = await open({ maxWorkers: 4 });
  const samples = [];
  for (let i = 0; i < runs; i += 1) {
    samples.push(
      await page.evaluate(async (p) => {
        await window.__run(p);
        const s = window.__rt.monitor.snapshot();
        return { page: s.page, insts: s.instances.live.map((x) => ({ seq: x.seq, mem: x.memBytes, allocs: x.liveAllocs, bytes: x.liveBytes, jobs: x.jobs })) };
      }, PRIMES),
    );
  }
  await ctx.close();
  const after = samples.slice(warmup);
  const seqs = (x) => x.insts.map((i) => i.seq).sort().join(",");
  check(`memory: the same ${after[0].insts.length} instances served every run after warm-up`, after.every((x) => seqs(x) === seqs(after[0])), after.map(seqs).join(" | "));
  const flat = (pick) => after.every((x) => x.insts.every((i) => pick(i) === pick(after[0].insts.find((j) => j.seq === i.seq) ?? i)));
  check("memory: each instance's linear memory is flat after warm-up", flat((i) => i.mem), JSON.stringify(after.map((x) => x.insts.map((i) => i.mem))));
  check("memory: each instance's live allocations are flat after warm-up", flat((i) => i.allocs), JSON.stringify(after.map((x) => x.insts.map((i) => i.allocs))));
  check("memory: each instance's live bytes are flat after warm-up", flat((i) => i.bytes), JSON.stringify(after.map((x) => x.insts.map((i) => i.bytes))));
  check("memory: the page instance's memory and live allocations are flat after warm-up", after.every((x) => x.page.memBytes === after[0].page.memBytes && x.page.liveAllocs === after[0].page.liveAllocs), JSON.stringify(after.map((x) => [x.page.memBytes, x.page.liveAllocs, x.page.liveBytes])));
  console.log(`\nMemory (${LABEL}; ${runs} identical runs of ${PRIMES.jobs} prime jobs on 4 workers, ${warmup} warm-up):\n`);
  console.log(
    table(
      ["run", "page memory bytes", "page live allocations", "page live bytes", ...samples[0].insts.map((_, k) => `worker ${k + 1} memory / allocations / bytes`)],
      samples.map((x, n) => [String(n + 1), String(x.page.memBytes), String(x.page.liveAllocs), String(x.page.liveBytes), ...x.insts.map((i) => `${i.mem} / ${i.allocs} / ${i.bytes}`)]),
    ),
  );
  console.log("");
}

await browser.close();
server.close();
console.log(failures === 0 ? `== workers scaling (${MODE}, ${LABEL}): all pass` : `== workers scaling (${MODE}, ${LABEL}): ${failures} failures`);
process.exit(failures === 0 ? 0 : 1);
