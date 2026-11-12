// million-row-explorer-journey.mjs --wasm APP.wasm --runtime runtime.mjs --chrome PATH [--plotly plotly.min.js]
// -- the Million-Row Explorer (examples/million-row-explorer) in headless
// Chrome, at its real size (two million orders in four shards), with real
// workers, the example's own feed (`ports.mjs`) and the shared chart element,
// through the app's own controls and `runtime.monitor`:
// 1. The mount generates the four shards once, one per worker; each worker
//    keeps its shard (2 MB of packed orders) and the page never holds the
//    orders. Every later question reuses them: no shard is generated again
//    and no state is replaced. Each chart receives a figure of at most 366
//    points. It prints the cold question, warm questions and the shards'
//    memory.
// 2. Dragging a value slider, one step a frame: the slider asks at most
//    every 100 ms (its sampling timer), so it asks for no more than it can
//    use; the page's frames keep coming, no shard is generated again and no
//    worker is ended, and the drag's last value is answered by every shard
//    after it stops. How many questions are answered while the drag goes on
//    depends on the machine and the build, so that is printed, not asserted.
// 3. The live feed at 20,000 orders a second: the page folds every batch in,
//    the feed's backlog stays within its bound, and the page's live bytes do
//    not grow with the orders.
// 4. One worker for four shards, and jobs on the page's thread: the same
//    answers, but every question generates shards again; the times are
//    printed beside the pool's.
// Without `--plotly` the chart element draws nothing (as the site would
// without its CDN script), so `check` needs no network; with it, the frame
// gaps include Plotly's redraws.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, "../..");
const opts = parseArgs(process.argv.slice(2), ["plotly"]);
const files = {
  ...runtimeFiles(opts.runtime),
  "app.wasm": opts.wasm,
  "ports.mjs": path.join(repo, "examples/million-row-explorer/ports.mjs"),
  "plume-chart.mjs": path.join(repo, "examples/shared/plume-chart.mjs"),
  ...(opts.plotly ? { "plotly.min.js": opts.plotly } : {}),
};
const server = http.createServer((req, res) => {
  const u = new URL(req.url, "http://x");
  if (u.pathname === "/") {
    const plotly = opts.plotly ? '<script src="/plotly.min.js"></script>' : "";
    res.writeHead(200, { "content-type": "text/html" });
    res.end(`<!doctype html><html><head><meta charset="utf-8"><title>million-row explorer</title>${plotly}<script type="module" src="/plume-chart.mjs"></script></head><body style="width:1200px"></body></html>`);
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
const measured = [];
const TASK = "roc-signals.example/million-row-explorer/summary";
const PORT = "roc-signals.example/million-row-explorer/orders";

function install() {
  window.__mount = async (options = {}) => {
    const { mountRocEngineApp } = await import("/runtime.mjs");
    const ports = (await import("/ports.mjs")).default;
    const root = document.createElement("div");
    document.body.append(root);
    window.__root = root;
    window.__events = [];
    window.__mountedAt = performance.now();
    window.__rt = await mountRocEngineApp({ wasmUrl: "/app.wasm", root, ports, onFault: (f) => (window.__fault = f), ...options });
    window.__rt.monitor.subscribe((e) => window.__events.push(e));
    return true;
  };
  const control = (label) => window.__root.querySelector(`[aria-label="${label}"]`);
  window.__click = (label) => control(label).click();
  window.__slide = (label, value) => {
    const el = control(label);
    el.value = String(value);
    el.dispatchEvent(new Event("input", { bubbles: true }));
  };
  window.__select = (label, value) => {
    const el = control(label);
    el.value = String(value);
    el.dispatchEvent(new Event("change", { bubbles: true }));
  };
  window.__text = (id) => window.__root.querySelector(`[data-testid="${id}"]`)?.textContent ?? null;
  window.__until = (pred, what, ms = 180000) =>
    new Promise((resolve, reject) => {
      const t = setTimeout(() => reject(new Error(`timed out waiting for ${what}`)), ms);
      const tick = () => {
        const v = pred();
        if (v) {
          clearTimeout(t);
          resolve(v);
        } else setTimeout(tick, 1);
      };
      tick();
    });
  // Answered: every shard of the current question has answered.
  window.__answered = () => window.__until(() => window.__text("status") === "4 of 4 shards answered." && window.__rt.monitor.snapshot().jobs.inFlight === 0, "the question to be answered");
  // Ask (a click or a slide), then time it to the answer on the page.
  window.__ask = async (act) => {
    const done = window.__rt.monitor.snapshot().jobs.done;
    const at = performance.now();
    act();
    await window.__until(() => window.__rt.monitor.snapshot().jobs.done >= done + 4, "four answers");
    await window.__answered();
    return performance.now() - at;
  };
  // The longest gap between animation frames, and the longest long task.
  window.__watch = () => {
    const w = { gap: 0, longTask: 0, last: performance.now(), on: true };
    const frame = (t) => {
      w.gap = Math.max(w.gap, t - w.last);
      w.last = t;
      if (w.on) requestAnimationFrame(frame);
    };
    requestAnimationFrame(frame);
    w.observer = new PerformanceObserver((list) => {
      for (const e of list.getEntries()) w.longTask = Math.max(w.longTask, e.duration);
    });
    w.observer.observe({ type: "longtask" });
    return () => {
      w.on = false;
      w.observer.disconnect();
      return { gap: Math.max(w.gap, performance.now() - w.last), longTask: w.longTask };
    };
  };
  window.__figures = () => [...window.__root.querySelectorAll("plume-chart")].map((el) => JSON.parse(el.dataset.figure));
  window.__pageMem = () => ({ mem: window.__rt.x.memory.buffer.byteLength, live: Number(window.__rt.x.metric(5)) });
}

async function open(options) {
  const ctx = await browser.createBrowserContext();
  const page = await ctx.newPage();
  page.on("pageerror", (e) => console.log("pageerror", String(e)));
  await page.evaluateOnNewDocument(install);
  await page.goto(`${base}/`);
  await page.evaluate((o) => window.__mount(o), options);
  return { page, ctx };
}

const MIB = 1 << 20;
const n = (x) => x.toLocaleString("en-US");

// 1-3. Four workers, one shard each.
{
  const { page, ctx } = await open({ maxWorkers: 4 });
  const r = await page.evaluate(async (TASK) => {
    const rt = window.__rt;
    await window.__answered();
    const cold = performance.now() - window.__mountedAt;
    const s = rt.monitor.snapshot();
    const prepared = s.recent.filter((j) => j.prepared === "prepare");
    const shards = [1, 2, 3, 4].map((i) => window.__text(`shard-${i}`));
    const figures = window.__figures();
    const drawn = [...window.__root.querySelectorAll("plume-chart")].map((el) => el.querySelector("svg.main-svg") !== null);
    const points = figures.map((f) => f.data.reduce((sum, t) => sum + (t.x ?? t.labels ?? []).length, 0));
    // Warm questions: categories cleared and restored, and a range.
    const warm = [];
    for (const act of [() => window.__click("Toys"), () => window.__click("Toys"), () => window.__click("Electronics"), () => window.__slide("Lowest value", 3), () => window.__slide("Lowest value", 0), () => window.__click("Electronics")]) {
      warm.push(await window.__ask(act));
    }
    const sw = rt.monitor.snapshot();
    const warmCompute = sw.recent.filter((j) => j.outcome === "done" && j.prepared === "reuse").slice(-8).map((j) => j.ms.compute);
    const memory = sw.instances.live.map((i) => ({ held: i.held, mem: i.memBytes, live: i.liveBytes }));
    const pageAfterQuestions = window.__pageMem();
    // 2. A drag: 60 steps, one a frame.
    const stop = window.__watch();
    const before = rt.monitor.snapshot();
    for (let i = 0; i < 60; i += 1) {
      window.__slide("Highest value", 39 - (i % 30));
      await new Promise((r) => requestAnimationFrame(r));
    }
    const settle = await window.__ask(() => window.__slide("Highest value", 25));
    const drag = stop();
    const after = rt.monitor.snapshot();
    // 3. The live feed at its fastest pace for three seconds.
    window.__select("Live orders a second", 20000);
    const live0 = Number(window.__text("live").match(/([\d,]+) live orders/)[1].replace(/,/g, ""));
    const stopFeed = window.__watch();
    const t0 = performance.now();
    await new Promise((r) => setTimeout(r, 1000));
    const memAt1 = window.__pageMem();
    let backlog = 0;
    const sampler = setInterval(() => (backlog = Math.max(backlog, Object.values(rt.monitor.snapshot().ports)[0]?.backlog ?? 0)), 20);
    await new Promise((r) => setTimeout(r, 2000));
    clearInterval(sampler);
    const memAt3 = window.__pageMem();
    const feedMs = performance.now() - t0;
    const live1 = Number(window.__text("live").match(/([\d,]+) live orders/)[1].replace(/,/g, ""));
    const feed = stopFeed();
    window.__click("Live orders");
    const port = rt.monitor.snapshot().ports;
    return {
      cold,
      prepareMs: prepared.map((j) => j.prepareMs),
      coldCompute: prepared.map((j) => j.ms.compute),
      shards,
      points,
      drawn,
      warm,
      warmCompute,
      counts: { prepared: sw.jobs.prepared, replaced: sw.instances.evicted.replaced, retired: sw.instances.ended.retired, lost: sw.jobs.lost },
      memory,
      pageAfterQuestions,
      drag: { ...drag, settle, issued: after.jobs.done + after.jobs.cancelled - before.jobs.done - before.jobs.cancelled, answered: after.jobs.done - before.jobs.done, finished: after.recent.filter((j) => j.finished).length, endedByCancel: after.instances.ended.cancel, prepared: after.jobs.prepared - before.jobs.prepared },
      feed: { ...feed, orders: live1 - live0, ms: feedMs, memAt1, memAt3, backlog, port: port },
      fault: window.__fault ?? null,
    };
  }, TASK);
  const portStats = r.feed.port[PORT] ?? {};
  check("the mount answers from four shards of 500,000 orders each", r.shards, ["500,000 match", "500,000 match", "500,000 match", "500,000 match"]);
  check("each shard was generated once, in its own worker, and every later question reused it", [r.prepareMs.length, r.counts, r.memory.filter((m) => m.held !== null).length], [4, { prepared: 4, replaced: 0, retired: 0, lost: 0 }, 4]);
  check("every chart receives a figure of at most 366 points", r.points.map((p) => p > 0 && p <= 366), [true, true, true, true]);
  check("the page never holds the orders (its live bytes stay under 1 MiB; the orders are 8 MiB)", r.pageAfterQuestions.live < MIB, true);
  // The four shards answer the drag's last question on any machine. How many
  // earlier questions they also answer is a rate, printed with the timings.
  check("a drag one step a frame (sampled every 100 ms) ends answered by every shard, with no worker ended and no shard generated again", [r.drag.answered >= 4, r.drag.issued <= 4 * 20, r.drag.endedByCancel, r.drag.prepared], [true, true, 0, 0]);
  if (opts.plotly) check("with Plotly loaded, every chart is drawn", r.drawn, [true, true, true, true]);
  check("the page's frames keep coming during the drag (no gap over 250 ms)", r.drag.gap < 250, true);
  check("the live feed's orders are all folded in, its backlog within its bound, and the page's live bytes do not grow with them", [r.feed.orders > 20000, r.feed.backlog <= 4, r.feed.memAt3.live <= r.feed.memAt1.live + 64 * 1024, r.feed.memAt3.mem === r.feed.memAt1.mem], [true, true, true, true]);
  check("no fault", r.fault, null);
  measured.push(
    ["cold question: mount to every shard answered (ms)", r.cold],
    ["generating one shard of 500,000 orders, per shard (ms)", r.prepareMs.map((x) => x.toFixed(0)).join(" / ")],
    ["first summary on each worker, compiling included (ms)", r.coldCompute.map((x) => x.toFixed(0)).join(" / ")],
    ["warm questions, ask to answer on the page (ms)", r.warm.map((x) => x.toFixed(0)).join(" / ")],
    ["warm summaries, one shard each (ms)", r.warmCompute.map((x) => x.toFixed(0)).join(" / ")],
    ["each worker's linear memory / live bytes (MiB)", r.memory.map((m) => `${(m.mem / MIB).toFixed(1)}/${(m.live / MIB).toFixed(1)}`).join(" ")],
    ["page linear memory / live bytes after the questions (MiB)", `${(r.pageAfterQuestions.mem / MIB).toFixed(1)}/${(r.pageAfterQuestions.live / MIB).toFixed(2)}`],
    ["drag of 60 steps: jobs asked / answered / superseded jobs finished", `${r.drag.issued} / ${r.drag.answered} / ${r.drag.finished}`],
    ["drag: longest frame gap / longest long task (ms)", `${r.drag.gap.toFixed(1)} / ${r.drag.longTask.toFixed(0)}`],
    ["drag: last step to its answer on the page, sampling timer included (ms)", r.drag.settle],
    ["feed at 20,000 a second: orders folded in per second", (r.feed.orders * 1000) / r.feed.ms],
    ["feed: messages / refused emits / largest backlog", `${portStats.messages} / ${portStats.refusedEmits} / ${r.feed.backlog}`],
    ["feed: longest frame gap / longest long task (ms)", `${r.feed.gap.toFixed(1)} / ${r.feed.longTask.toFixed(0)}`],
    ["feed: page live bytes after 1 s / 3 s (KiB)", `${(r.feed.memAt1.live / 1024).toFixed(0)} / ${(r.feed.memAt3.live / 1024).toFixed(0)}`],
  );
  await ctx.close();
}

// 4. One worker for four shards, then the page's thread.
for (const [label, options] of [
  ["one worker", { maxWorkers: 1 }],
  ["inline", { workers: "inline" }],
]) {
  const { page, ctx } = await open(options);
  const r = await page.evaluate(async () => {
    const rt = window.__rt;
    window.__click("Live orders");
    await window.__answered();
    const shards = [1, 2, 3, 4].map((i) => window.__text(`shard-${i}`));
    const stop = window.__watch();
    const times = [];
    for (const act of [() => window.__click("Toys"), () => window.__click("Toys"), () => window.__click("Electronics"), () => window.__click("Electronics")]) times.push(await window.__ask(act));
    const gaps = stop();
    const s = rt.monitor.snapshot();
    return { shards, times, gaps, prepared: s.jobs.prepared, reused: s.jobs.reused, replaced: s.instances.evicted.replaced, fault: window.__fault ?? null };
  });
  check(`${label}: the same answers`, r.shards, ["500,000 match", "500,000 match", "500,000 match", "500,000 match"]);
  check(`${label}: an instance keeps one shard, so questions generate shards again`, [r.prepared > 8, r.fault], [true, null]);
  measured.push(
    [`${label}: questions, ask to answer (ms)`, r.times.map((x) => x.toFixed(0)).join(" / ")],
    [`${label}: shards generated / reused / replaced`, `${r.prepared} / ${r.reused} / ${r.replaced}`],
    [`${label}: longest frame gap / long task (ms)`, `${r.gaps.gap.toFixed(0)} / ${r.gaps.longTask.toFixed(0)}`],
  );
  await ctx.close();
}

for (const [name, v] of measured) console.log(`measured ${name}: ${typeof v === "number" ? v.toFixed(1) : v}`);
await browser.close();
server.close();
console.log(failures === 0 ? "million-row-explorer-journey: passed" : `million-row-explorer-journey: ${failures} failed`);
process.exit(failures === 0 ? 0 : 1);
