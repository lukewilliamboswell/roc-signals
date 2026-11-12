// soak.mjs --wasm APP.wasm --runtime runtime.mjs --chrome PATH --app APP [--events N]
// -- long session in headless Chrome.
// 1. A seeded random walk of EVENTS user events (default 3000) chosen from
//    the live DOM (elements carrying engine handlers, disabled ones skipped):
//    clicks, typed values with input events, checkbox/select changes.
//    Conduit runs with automatic effects against the RealWorld mock backend.
//    The instance must never fault.
// 2. On a fresh page, an app round trip (back to the initial state) 30 times:
//    Wasm memory pages must be flat and the host's live allocation count and
//    live bytes (metrics 4, 5) must not grow after 3 warm-up cycles.
// An app with ports (PORT_APPS) mounts with its own handlers, served beside
// it, against real browser services (the Reading List's IndexedDB) or a
// simulation of its own (the Status Page's seeded latency stream).
// A worker app (WORKER_APPS) mounts with one worker and `manualWork`: after
// every event the soak runs each pending job in issue order and waits for
// its result, so results arrive in a fixed order and no timeout fires. Its
// round trips must also leave the one long-lived worker instance flat (its
// memory, live allocations and live bytes, from `runtime.monitor.snapshot()`)
// and the pool settled: that instance only, never respawned, idle, nothing
// queued or busy, and every job answered.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, "../..");
const opts = parseArgs(process.argv.slice(2), ["app", "events", "cycles"]);
const app = opts.app;
const EVENTS = Number(opts.events ?? 3000);
// Apps with a simulated service run against the example's own module (its
// `backend` in www/data/examples.toml), served over HTTP below: Conduit's
// RealWorld API, Field Notes' sync endpoint (every third sync fails) and the
// status page's scripted checks and incidents (an outage, a failed check,
// recovery).
const BACKENDS = {
  conduit: "examples/conduit/backend.mjs",
  "field-notes": "examples/field-notes/backend.mjs",
  "status-page": "examples/status-page/backend.mjs",
};
// Apps whose only requests are for static files served below (the
// converter's sample).
const FETCHES_FILES = ["csv-converter"];
const backendModule = BACKENDS[app] ?? null;
const handle = backendModule ? (await import(path.join(repo, backendModule))).default() : null;
// Apps whose effects include worker jobs.
const WORKER_APPS = ["worker-search", "csv-converter", "log-explorer", "million-row-explorer"];
// Apps where a response that arrives while a held job runs may supersede
// it (the converter's sample, fetched during the walk, replaces the file
// being converted): stopping a running job ends its worker, so the walk
// allows respawns there. Round trips still require one long-lived worker.
const ASYNC_SUPERSEDE = ["csv-converter"];
const workers = WORKER_APPS.includes(app);
// Apps whose page passes port handlers: the module that holds them. Their
// answers and messages arrive on their own time, like a backend's.
const PORT_APPS = { "reading-list": "examples/reading-list/ports.mjs", "status-page": "examples/status-page/ports.mjs", "million-row-explorer": "examples/million-row-explorer/ports.mjs" };
const portsModule = PORT_APPS[app] ?? null;
const served = handle !== null || portsModule !== null || FETCHES_FILES.includes(app);

const files = {
  "index.html": path.join(here, "index.html"),
  "locate.js": path.join(here, "locate.js"),
  ...runtimeFiles(opts.runtime),
  "app.wasm": opts.wasm,
  // Data an example downloads at run time.
  ...(app === "csv-converter" ? { "sample.csv": path.join(repo, "examples/csv-converter/sample.csv") } : {}),
  ...(portsModule ? { "ports.mjs": path.join(repo, portsModule) } : {}),
};
const server = http.createServer(async (req, res) => {
  const u = new URL(req.url, "http://x");
  if (handle && u.pathname.startsWith("/api/")) {
    let body = "";
    for await (const c of req) body += c;
    let r;
    try {
      r = await handle({ method: req.method, uri: u.pathname + u.search, headers: req.headers, body });
    } catch {
      // The service's network failure: the browser's fetch rejects.
      req.socket.destroy();
      return;
    }
    res.writeHead(r ? r.status : 404, { "content-type": r?.headers?.["content-type"] ?? "text/plain" });
    res.end(r ? r.body : "");
    return;
  }
  const f = u.pathname.endsWith("/") ? files["index.html"] : files[path.basename(u.pathname)];
  if (!f) {
    res.writeHead(404);
    res.end();
    return;
  }
  res.writeHead(200, { "content-type": f.endsWith(".wasm") ? "application/wasm" : f.endsWith("html") ? "text/html" : f.endsWith(".csv") ? "text/csv" : "text/javascript" });
  res.end(fs.readFileSync(f));
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
// The query an app is opened with, where its address sets what it starts
// with: the explorer generates 1,000 orders, not two million, for a walk on
// one held worker, and starts with its live feed paused so a round trip
// returns to where it began (the walk switches the feed on and off).
const QUERIES = { "million-row-explorer": "?orders=1000&feed=paused" };
const base = `http://127.0.0.1:${server.address().port}/roc-signals/examples/conduit/${QUERIES[app] ?? ""}#/`;
const browser = await launch({ executablePath: opts.chrome });

async function open() {
  const ctx = await browser.createBrowserContext();
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  await page.evaluateOnNewDocument(fs.readFileSync(files["locate.js"], "utf8"));
  if (portsModule) await page.evaluateOnNewDocument(() => (window.__portsModule = "./ports.mjs"));
  if (workers) {
    await page.evaluateOnNewDocument(() => {
      window.__mountOptions = { maxWorkers: 1, manualWork: true };
      // Run every held job in issue order, each to its result turn; a
      // result may issue more.
      window.__runWork = async () => {
        const rt = window.__rt;
        let ran = 0;
        for (;;) {
          const next = rt.pendingEffects().find((r) => r.op === "work");
          if (next === undefined || rt.poisoned) return ran;
          await rt.runEffect(next.id);
          ran += 1;
        }
      };
    });
  }
  await page.goto(base);
  await page.waitForFunction("window.__ready || window.__error");
  return { ctx, page, errors };
}

// Quiet once nothing awaited is in flight and no event waits. A port
// app's commands and messages are not awaited requests, so it must also
// stay quiet for QUIET consecutive checks (a write, then the read that
// reports it).
const QUIET = portsModule ? 10 : 0;
const settle = (page) => page.evaluate((quiet) => new Promise((r) => {
  const rt = window.__rt;
  const t0 = performance.now();
  let calm = 0;
  const tick = () => {
    // A held job is not waited for: the soak runs it (`__runWork`).
    const busy = [...rt.live.values()].some((e) => e.kind === "http" || e.kind === "fetch" || e.kind === "file" || e.kind === "portcall" || (e.kind === "work" && e.running));
    calm = !busy && rt.queue.length === 0 ? calm + 1 : 0;
    if (calm > quiet || performance.now() - t0 > 2000) r();
    else setTimeout(tick, 5);
  };
  setTimeout(tick, 0);
}), QUIET);

let failures = 0;
const check = (name, ok, detail = "") => {
  if (!ok) failures += 1;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok ? "" : " " + detail}`);
};

// 1. Random walk.
{
  const { ctx, page, errors } = await open();
  const t0 = Date.now();
  const done = await page.evaluate(async (n, served, workers) => {
    const POOL = ["", "a", "Ada", "10", "-3", "2x", "x@y.z", "Lorem ipsum dolor", "Node-0007", "# Title", "Renamed"];
    let seed = 7n;
    const rnd = () => {
      seed = (seed * 6364136223846793005n + 1442695040888963407n) & 0xffffffffffffffffn;
      return Number(seed >> 33n);
    };
    const root = document.getElementById("app");
    const rt = window.__rt;
    let fired = 0;
    let jobs = 0;
    for (let i = 0; i < n; i += 1) {
      if (rt.poisoned) return { fired, fault: rt.poisoned };
      const cands = [];
      const walk = (el) => {
        for (let c = el.firstElementChild; c; c = c.nextElementSibling) {
          if (c.__h !== undefined && !c.disabled) cands.push(c);
          walk(c);
        }
      };
      walk(root);
      if (cands.length === 0) break;
      const el = cands[rnd() % cands.length];
      const h = el.__h;
      // A control that takes files (a file input, a drop target) has no
      // text to type; the walk gives the app none.
      if ((h.change !== undefined && h.change.files) || (h.drop !== undefined && h.drop.files)) continue;
      if (h.input !== undefined) {
        el.focus();
        el.value = POOL[rnd() % POOL.length];
        el.dispatchEvent(new Event("input", { bubbles: true }));
      } else if (h.change !== undefined) {
        if (el.type === "checkbox" || el.type === "radio") el.click();
        else {
          if (el.tagName === "SELECT" && el.options.length > 0) el.value = el.options[rnd() % el.options.length].value;
          else el.value = POOL[rnd() % POOL.length];
          el.dispatchEvent(new Event("change", { bubbles: true }));
        }
      } else if (h.click !== undefined) {
        el.click();
      } else {
        continue;
      }
      fired += 1;
      if (workers) jobs += await window.__runWork();
      if (served && i % 10 === 9) await new Promise((r) => setTimeout(r, 0));
    }
    return { fired, jobs, fault: rt.poisoned };
  }, EVENTS, served, workers);
  if (served) await settle(page);
  if (served && workers) {
    await page.evaluate(() => window.__runWork());
    await settle(page);
  }
  const fault = await page.evaluate(() => window.__rt.poisoned);
  check(`random walk: ${done.fired} events in ${Date.now() - t0} ms, no fault`, done.fired >= Math.min(EVENTS, 1000) && fault === null && errors.length === 0, JSON.stringify({ fault, errors: errors.slice(0, 3) }));
  const stats = await page.evaluate(() => ({ pages: window.__rt.x.memory.buffer.byteLength / 65536, live: Number(window.__rt.x.metric(4)) }));
  console.log(`   after walk: ${stats.pages} pages, ${stats.live} live allocations`);
  if (workers) {
    const s = await page.evaluate(() => window.__rt.monitor.snapshot());
    check(`random walk: ${done.jobs} worker jobs run, every one answered`, done.jobs > 0 && s.jobs.inFlight === 0 && s.pool.instances === 1 && (s.instances.respawns === 0 || ASYNC_SUPERSEDE.includes(app)), JSON.stringify({ jobs: s.jobs, pool: s.pool, instances: s.instances.live }));
  }
  await ctx.close();
}

// 2. Round trips.
const CYCLES = {
  "form-builder": [["fill", ["label", "Answer f1"], "Ada"], ["fill", ["label", "Answer f1"], ""], ["click", ["role", "button", "Move up f2"]], ["click", ["role", "button", "Move up f1"]]],
  "kanban-board": [["fill", ["label", "New card title"], "Soak card"], ["click", ["role", "button", "Add card"]], ["click", ["role", "button", "Delete: Soak card"]]],
  "data-grid": [["fill", ["label", "Filter"], "Node-0007"], ["fill", ["label", "Filter"], ""], ["click", ["role", "button", "Next page"]], ["click", ["role", "button", "Previous page"]]],
  // Append + remove a section is not an exact inverse in this app (one more
  // trailing newline per trip): load two fixed documents instead.
  "markdown-editor": [["click", ["role", "button", "Load heading drill"]], ["click", ["role", "button", "Load document without headings"]]],
  conduit: [["click", ["role", "link", "Sign in"]], ["click", ["role", "link", "Home"]]],
  "field-notes": [
    ["fill", ["label", "Note body"], "Soak note"],
    ["fill", ["label", "Note body"], ""],
    ["click", ["label", "Hide synced notes"]],
    ["click", ["label", "Hide synced notes"]],
    ["click", ["label", "Sync automatically"]],
    ["click", ["label", "Sync automatically"]],
  ],
  "spreadsheet-lite": [
    ["fill", ["label", "B2"], "1500"],
    ["fill", ["label", "B2"], "1200"],
    ["click", ["role", "button", "Reverse row order"]],
    ["click", ["role", "button", "Top to bottom"]],
    ["click", ["role", "button", "Hide empty rows"]],
    ["click", ["role", "button", "Show all rows"]],
  ],
  // Every check answered by the example's service, which settles on a
  // healthy board after its scripted incident.
  "status-page": [["click", ["role", "button", "Refresh now"]]],
  // A run and a drawing, each started and reset at once, so their jobs are
  // stopped in the workers; then the initial parameters again.
  "worker-lab": [["click", ["role", "button", "Start"]], ["click", ["role", "button", "Reset"]], ["fill", ["label", "Workload"], "draw"], ["fill", ["label", "Jobs"], "2"], ["fill", ["label", "Weight"], "1"], ["click", ["role", "button", "Start"]], ["click", ["role", "button", "Reset"]], ["fill", ["label", "Workload"], "primes"], ["fill", ["label", "Jobs"], "8"], ["fill", ["label", "Weight"], "4"]],
  // A search run in the worker, a cleared query (a pure cancel), and the
  // report's job run, then its panel closed.
  "worker-search": [["fill", ["label", "Search"], "roc"], ["fill", ["label", "Search"], ""], ["click", ["role", "button", "Report"]], ["click", ["role", "button", "Report"]]],
  // The sample downloaded into a file, converted in the task's worker and
  // previewed: each answer replaces the last, whose files are let go.
  "csv-converter": [["click", ["role", "button", "Load the sample"]]],
  // A sample log written by its task, then prepared for the overview: each
  // new log replaces the last, whose file and prepared state are let go.
  "log-explorer": [["fill", ["label", "Entries"], "300"], ["click", ["role", "button", "Generate a sample log"]]],
  // A book added (the store answers it) and removed (a command), each write
  // followed by the store's copy.
  "reading-list": [["fill", ["label", "Title"], "Soak book"], ["click", ["role", "button", "Add book"]], ["click", ["role", "button", "Remove Soak book"]]],
  // A category cleared and restored, each question answered by every shard, while live orders arrive.
  "million-row-explorer": [["click", ["label", "Toys"]], ["click", ["label", "Toys"]]],
};
// Steps run once before an app's first cycle, to reach a steady state. The
// Status Page pauses its live feed, whose window would otherwise grow with
// the clock, and fills its uptime history, which keeps 60 refreshes.
const SCENES = { "status-page": [["click", ["role", "button", "Pause the feed"]], ...Array(60).fill(["click", ["role", "button", "Refresh now"]])] };
{
  const { ctx, page } = await open();
  if (served) await settle(page);
  const cycle = CYCLES[app];
  const NCYC = Number(opts.cycles ?? 30);
  const samples = [];
  const workerSamples = [];
  for (let c = 0; c < NCYC; c += 1) {
    for (const [op, loc, v] of c === 0 ? (SCENES[app] ?? []).concat(cycle) : cycle) {
      const r = await page.evaluate((op, loc, v) => {
        const el = window.__loc(loc);
        if (!el) return `no element ${JSON.stringify(loc)}`;
        if (op === "click") el.click();
        else {
          el.value = v;
          // A select reports a choice with `change`, a text field with `input`.
          el.dispatchEvent(new Event(el.tagName === "SELECT" ? "change" : "input", { bubbles: true }));
        }
        return null;
      }, op, loc, v);
      if (r) throw new Error(r);
      // A response may issue a job (a fetched file sent to a task), and a
      // job's answer may issue a request (a read of the file it built).
      if (served) await settle(page);
      if (workers) await page.evaluate(() => window.__runWork());
      if (served) await settle(page);
    }
    samples.push(await page.evaluate(() => [window.__rt.x.memory.buffer.byteLength / 65536, Number(window.__rt.x.metric(4)), Number(window.__rt.x.metric(5))]));
    if (workers) {
      workerSamples.push(
        await page.evaluate(() => {
          const s = window.__rt.monitor.snapshot();
          const w = s.instances.live[0] ?? {};
          return { mem: w.memBytes, allocs: w.liveAllocs, bytes: w.liveBytes, jobs: w.jobs, state: w.state, instances: s.pool.instances, spawns: s.instances.spawns, busy: s.pool.busy, queued: s.pool.queued, inFlight: s.jobs.inFlight };
        }),
      );
    }
  }
  // Flat: identical pages; live allocations with no growth (the later half
  // never exceeds the earlier half). Exact equality is also reported: an
  // async effect app may jitter by an allocation depending on timing.
  const tail = samples.slice(3);
  const half = Math.floor(tail.length / 2);
  const maxOf = (xs, i) => Math.max(...xs.map((s) => s[i]));
  const pagesFlat = tail.every((s) => s[0] === tail[0][0]);
  // live allocation count (1) and live bytes (2): no growth
  const noGrowth = [1, 2].every((i) => maxOf(tail.slice(half), i) <= maxOf(tail.slice(0, half), i));
  const exact = tail.every((s) => s[1] === tail[0][1] && s[2] === tail[0][2]);
  check(`${NCYC} round trips: pages flat, no growth in live allocations or live bytes after 3 warm-up cycles (exactly equal: ${exact})`, pagesFlat && noGrowth && !(await page.evaluate(() => window.__rt.poisoned)), JSON.stringify(samples));
  console.log(`   cycles (pages, live): ${JSON.stringify(samples.slice(0, 5))} ... ${JSON.stringify(samples.slice(-2))}`);
  if (workers) {
    // The worker instance runs the same jobs every cycle: after warm-up its
    // memory is identical and its live allocations and bytes never grow; the
    // pool is that one instance, idle, with every job answered.
    const wt = workerSamples.slice(3);
    const wh = Math.floor(wt.length / 2);
    const wmax = (xs, k) => Math.max(...xs.map((s) => s[k]));
    const memFlat = wt.every((s) => s.mem === wt[0].mem);
    const wNoGrowth = ["allocs", "bytes"].every((k) => wmax(wt.slice(wh), k) <= wmax(wt.slice(0, wh), k));
    const wExact = wt.every((s) => s.allocs === wt[0].allocs && s.bytes === wt[0].bytes);
    const settled = workerSamples.every((s) => s.instances === 1 && s.spawns === 1 && s.state === "idle" && s.busy === 0 && s.queued === 0 && s.inFlight === 0);
    const ran = workerSamples.every((s, i) => i === 0 || s.jobs === workerSamples[i - 1].jobs + workerSamples[0].jobs);
    check(`${NCYC} round trips: the worker instance's memory flat, no growth in its live allocations or bytes (exactly equal: ${wExact}); one idle instance, never respawned, every job answered`, memFlat && wNoGrowth && settled && ran, JSON.stringify(workerSamples));
    console.log(`   worker (mem, allocs, bytes, jobs): ${JSON.stringify(workerSamples.slice(0, 4).map((s) => [s.mem, s.allocs, s.bytes, s.jobs]))} ... ${JSON.stringify(workerSamples.slice(-2).map((s) => [s.mem, s.allocs, s.bytes, s.jobs]))}`);
  }
  await ctx.close();
}
await browser.close();
server.close();
console.log(failures === 0 ? `== soak ${app}: all pass` : `== soak ${app}: ${failures} failures`);
process.exit(failures === 0 ? 0 : 1);
