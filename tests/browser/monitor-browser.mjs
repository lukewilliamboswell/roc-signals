// monitor-browser.mjs --wasm APP.wasm --runtime runtime.mjs --chrome PATH --
// browser contract test of the work monitor (`runtime.monitor`) with
// tests/apps/workers in headless Chrome: every event kind and its ordering
// guarantees, the job timeline and its spans, the pool gauges and peaks,
// terminations by cause and respawns, per-instance memory, inline, manual and
// unavailable modes, containment and unmount, payloads only on request, a
// throwing listener, the history bound, the engine counters' decoding, User
// Timing entries with their details, and what the monitor costs when nobody
// observes it (counted clock reads, not timed).
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";

const opts = parseArgs(process.argv.slice(2));
const files = { ...runtimeFiles(opts.runtime), "app.wasm": opts.wasm };
const server = http.createServer((req, res) => {
  const u = new URL(req.url, "http://x");
  if (u.pathname === "/") {
    res.writeHead(200, { "content-type": "text/html" });
    res.end("<!doctype html><html><head><meta charset=\"utf-8\"><title>monitor</title></head><body></body></html>");
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

// Page-side helpers. `__events` records every monitor event (subscribed
// right after mount, so the mount's own `runtime` event is not in it);
// `__measures` every User Timing measure the page sees.
function install() {
  window.__faults = [];
  window.__events = [];
  window.__measures = [];
  new PerformanceObserver((list) => {
    for (const e of list.getEntries()) if (e.name.startsWith("roc:")) window.__measures.push({ name: e.name, detail: e.detail, duration: e.duration });
  }).observe({ type: "measure" });
  window.__mount = async (options, subscribe = true) => {
    const { mountRocEngineApp } = await import("/runtime.mjs");
    const root = document.createElement("div");
    document.body.append(root);
    window.__root = root;
    window.__rt = await mountRocEngineApp({ wasmUrl: "/app.wasm", root, onWorkerFault: (f) => window.__faults.push(f), ...options });
    if (subscribe) window.__rt.monitor.subscribe((e) => window.__events.push(e));
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
  // Resolve once `pred(entries)` holds; reads no clock (the overhead case
  // counts the runtime's clock reads).
  window.__until = (pred) =>
    new Promise((resolve, reject) => {
      const log = window.__root.querySelector("[data-testid=log]");
      const done = () => {
        if (!pred(window.__entries())) return false;
        mo.disconnect();
        clearTimeout(timer);
        resolve(true);
        return true;
      };
      const mo = new MutationObserver(done);
      mo.observe(log, { childList: true, characterData: true, subtree: true });
      const timer = setTimeout(() => {
        if (!done()) {
          mo.disconnect();
          reject(new Error(`timed out; log ${window.__log()}`));
        }
      }, 20000);
      done();
    });
  window.__sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  // Strip the events to what the ordering checks look at.
  window.__kinds = (events) => events.map((e) => (e.kind === "job-end" ? `job-end:${e.outcome}` : e.kind === "instance-end" ? `instance-end:${e.cause}` : e.kind === "runtime" ? `runtime:${e.state}` : e.kind));
  // Anything that is a byte array, anywhere in `v`.
  window.__hasBytes = (v) => {
    if (v instanceof Uint8Array || v instanceof ArrayBuffer) return true;
    if (v && typeof v === "object") return Object.values(v).some((x) => window.__hasBytes(x));
    return false;
  };
}

async function open(options, { subscribe = true, before = null } = {}) {
  const ctx = await browser.createBrowserContext();
  const page = await ctx.newPage();
  page.on("pageerror", (e) => console.log("pageerror", String(e)));
  await page.evaluateOnNewDocument(install);
  if (before) await page.evaluateOnNewDocument(before);
  await page.goto(`${base}/`);
  await page.evaluate((o, s) => window.__mount(o, s), options, subscribe);
  return { page, ctx };
}

// The ordering guarantees over one session's events.
function ordered(events) {
  const problems = [];
  let at = -Infinity;
  const jobs = new Map();
  const insts = new Map();
  for (const e of events) {
    if (e.at < at) problems.push(`${e.kind} at ${e.at} before ${at}`);
    at = Math.max(at, e.at);
    if (e.kind === "job-issue") jobs.set(e.id, "issued");
    else if (e.kind === "job-start") {
      if (jobs.get(e.id) !== "issued") problems.push(`job-start ${e.id} without issue`);
      if (insts.get(e.instance) === undefined) problems.push(`job-start ${e.id} on unknown instance ${e.instance}`);
      jobs.set(e.id, "started");
    } else if (e.kind === "job-end") {
      if (!["issued", "started"].includes(jobs.get(e.id))) problems.push(`job-end ${e.id} twice or unissued`);
      jobs.set(e.id, "ended");
    } else if (e.kind === "instance-spawn") insts.set(e.instance, "spawned");
    else if (e.kind === "instance-ready") {
      if (insts.get(e.instance) !== "spawned") problems.push(`instance-ready ${e.instance} out of order`);
      insts.set(e.instance, "ready");
    } else if (e.kind === "instance-end") {
      if (!["spawned", "ready"].includes(insts.get(e.instance))) problems.push(`instance-end ${e.instance} twice`);
      insts.set(e.instance, "ended");
    }
  }
  return problems;
}

// One cold and one warm job: events, timeline, record, snapshot.
{
  const { page, ctx } = await open({});
  const r = await page.evaluate(async () => {
    window.__click("Upper");
    await window.__until((l) => l.length === 1);
    window.__click("Upper");
    await window.__until((l) => l.length === 2);
    const s = window.__rt.monitor.snapshot();
    return { kinds: window.__kinds(window.__events), events: window.__events, s, json: JSON.stringify(s) === JSON.stringify(JSON.parse(JSON.stringify(s))) };
  });
  check("events of a cold then a warm job", r.kinds, ["job-issue", "instance-spawn", "job-start", "instance-ready", "job-end:done", "job-issue", "job-start", "job-end:done"]);
  check("ordering guarantees hold", ordered(r.events), []);
  const [cold, warm] = r.s.recent;
  check("the first job is cold and first on its instance; the second warm", [cold.cold, cold.firstJobOnInstance, warm.cold, warm.firstJobOnInstance], [true, true, false, false]);
  check("both ran off the page's thread on instance 1", [cold.thread, warm.thread, cold.instance, warm.instance], ["worker", "worker", 1, 1]);
  check("sizes, not bytes", [cold.program, cold.inputBytes, cold.outputBytes, r.s.jobs.inputBytes, r.s.jobs.outputBytes], ["test.roc-signals/upper", 5, 5, 10, 10]);
  const t = warm.t;
  const seq = [t.issue, t.submit, t.post, t.reply, t.turnStart, t.turnEnd];
  check("the page's stamps are in order", seq.every((v, i) => i === 0 || v >= seq[i - 1]), true);
  // Worker stamps are converted to the page clock: within the clock's
  // coarsening (0.1 ms per stamp) of the page's stamps around them.
  const slack = 0.25;
  check("converted worker stamps fall between post and reply", [t.recv >= t.post - slack, t.sent <= t.reply + slack, t.call <= t.ret], [true, true, true]);
  const parts = ["held", "queue", "toWorker", "cold", "stage", "compute", "copyOut", "fromWorker", "resultWait", "resultTurn"].reduce((a, k) => a + (warm.ms[k] ?? 0), 0);
  check("the spans partition the total", Math.abs(parts - warm.ms.total) < 1e-6, true);
  check("a cold job has no transit span, a warm one no cold time", [cold.ms.toWorker, cold.ms.cold > 0, warm.ms.cold], [null, true, 0]);
  check("the snapshot is plain data", r.json, true);
  check("pool after: one idle instance", [r.s.pool.instances, r.s.pool.idle, r.s.pool.busy, r.s.pool.queued, r.s.pool.peak.busy], [1, 1, 0, 0, 1]);
  const inst = r.s.instances.live[0];
  check("instance facts", [inst.thread, inst.state, inst.jobs, inst.memBytes > 0, inst.liveAllocs > 0, inst.instantiateMs >= 0, inst.scriptAt > 0], ["worker", "idle", 2, true, true, true, true]);
  check("histograms counted both", [r.s.hist.total.n, r.s.hist.compute.n, r.s.hist.cold.n, r.s.programs["test.roc-signals/upper"].done], [2, 2, 1, 2]);
  check("mode, generation, and the engine's effect counters from the work record", [r.s.mode, r.s.generation, r.s.state, r.s.engine, r.s.page.turns > 0], ["workers", 1, "mounted", { issued: 2, delivered: 2, stale: 0, refused: 0, cancelled: 0, reparented: 0, skipped: 0, live: 0 }, true]);
  check("no late replies", r.s.jobs.lateReplies, 0);
  check("no User Timing entries by default", await page.evaluate(() => window.__measures.length), 0);
  check("no bytes anywhere by default", await page.evaluate(() => window.__hasBytes(window.__events) || window.__hasBytes(window.__rt.monitor.snapshot())), false);

  // The engine counters are read from indices 32-39, whatever they hold
  // (synthesised values, so each index is told apart).
  const e = await page.evaluate(() => {
    const real = window.__rt.workRecord.bind(window.__rt);
    window.__rt.workRecord = () => {
      const r = real();
      const counters = [...r.counters];
      while (counters.length < 32) counters.push(0n);
      counters.length = 32;
      for (let i = 0; i < 8; i += 1) counters.push(BigInt(100 + i));
      return { counters, cleanups: r.cleanups };
    };
    const engine = window.__rt.monitor.snapshot().engine;
    window.__rt.workRecord = real;
    return engine;
  });
  check("engine counters decoded from indices 32-39", e, { issued: 100, delivered: 101, stale: 102, refused: 103, cancelled: 104, reparented: 105, skipped: 106, live: 107 });
  await ctx.close();
}

// Queueing: one worker, four jobs.
{
  const { page, ctx } = await open({ maxWorkers: 1 });
  const r = await page.evaluate(async () => {
    window.__click("Batch");
    const during = window.__rt.monitor.snapshot().pool;
    await window.__until((l) => l.length === 4);
    return { during, s: window.__rt.monitor.snapshot(), events: window.__events };
  });
  check("one busy, three queued, peaks", [r.during.busy, r.during.queued, r.s.pool.peak.queued, r.s.pool.peak.instances], [1, 3, 3, 1]);
  const waits = r.s.recent.map((j) => j.ms.queue);
  check("later jobs waited longer in the queue", waits.every((w, i) => i === 0 || w >= waits[i - 1]), true);
  check("the queue integral and its histogram", [r.s.pool.queuedMs > 0, r.s.hist.queue.n], [true, 4]);
  check("utilisation figures", [r.s.pool.busyMs > 0, r.s.pool.aliveMs >= r.s.pool.busyMs], [true, true]);
  check("ordering guarantees hold", ordered(r.events), []);
  await ctx.close();
}

// Cancel, deadline, crash, memory.
{
  const { page, ctx } = await open({});
  const c = await page.evaluate(async () => {
    window.__click("Panel");
    await window.__sleep(50);
    const n = window.__events.length;
    window.__click("Panel");
    const ended = window.__kinds(window.__events.slice(n));
    const job = window.__events.slice(n).find((e) => e.kind === "job-end").record;
    window.__click("Upper");
    await window.__until((l) => l.includes("upper:JOB 1"));
    return { ended, job, s: window.__rt.monitor.snapshot() };
  });
  check("cancel: the instance ends, then the job", c.ended, ["instance-end:cancel", "job-end:cancelled"]);
  check("the cancelled job: running, by the engine, its time wasted", [c.job.phase, c.job.cancelledBy, c.s.jobs.wastedMs > 0], ["running", "engine", true]);
  check("the replacement is a respawn", [c.s.instances.spawns, c.s.instances.respawns, c.s.instances.ended.cancel], [2, 1, 1]);

  const d = await page.evaluate(async () => {
    window.__rounds(4000000000);
    const n = window.__events.length;
    window.__click("Slow");
    await window.__until((l) => l.some((e) => e.startsWith("slow:")));
    return { kinds: window.__kinds(window.__events.slice(n)), rec: window.__rt.monitor.snapshot().recent.at(-1), s: window.__rt.monitor.snapshot() };
  });
  check("deadline: the instance ends, then the job times out", d.kinds.filter((k) => k.includes("end")), ["instance-end:deadline", "job-end:timeout"]);
  check("its record", [d.rec.outcome, d.rec.deadlineMs, d.rec.ms.total >= 50, d.s.instances.ended.deadline], ["timeout", 50, true, 1]);

  const f = await page.evaluate(async () => {
    const n = window.__events.length;
    window.__click("Crash");
    await window.__until((l) => l.some((e) => e.startsWith("crash:")));
    const evs = window.__events.slice(n);
    return { end: evs.find((e) => e.kind === "instance-end"), job: evs.find((e) => e.kind === "job-end"), fault: window.__faults[0] };
  });
  check("crash: the instance ends with its fault", [f.end.cause, f.end.fault.class, f.end.fault.message === f.fault.message], ["fault", "app_crash", true]);
  check("crash: the job is lost", [f.job.outcome, f.job.record.fault], ["lost", "app_crash"]);

  const m = await page.evaluate(async () => {
    window.__click("Grow");
    await window.__until((l) => l.some((e) => e.startsWith("grow:")));
    const rec = window.__rt.monitor.snapshot().recent.at(-1);
    const inst = window.__rt.monitor.snapshot().instances.live.find((i) => i.seq === rec.instance);
    return { entry: window.__entries().find((e) => e.startsWith("grow:")), inst };
  });
  check("grow: 16 MiB allocated", m.entry, "grow:16777216");
  check("its instance's memory grew past it", [m.inst.memBytes >= 16777216, m.inst.peakMemBytes >= m.inst.memBytes], [true, true]);
  check("ordering guarantees hold over the session", ordered(await page.evaluate(() => window.__events)), []);
  await ctx.close();
}

// Inline mode: the same events on the page's thread.
{
  const { page, ctx } = await open({ workers: "inline" });
  const r = await page.evaluate(async () => {
    window.__click("Upper");
    await window.__until((l) => l.length === 1);
    return { kinds: window.__kinds(window.__events), s: window.__rt.monitor.snapshot() };
  });
  check("inline: the same events", r.kinds, ["job-issue", "instance-spawn", "job-start", "instance-ready", "job-end:done"]);
  check("inline: on the page's thread", [r.s.mode, r.s.recent[0].thread, r.s.instances.live[0].scriptAt], ["inline", "page", null]);
  await ctx.close();
}

// No Worker: unavailable, no instance.
{
  const { page, ctx } = await open({}, {
    before: () => {
      window.Worker = undefined;
    },
  });
  const r = await page.evaluate(async () => {
    window.__click("Upper");
    await window.__until((l) => l.length === 1);
    return { kinds: window.__kinds(window.__events), s: window.__rt.monitor.snapshot() };
  });
  check("unavailable: answered without an instance", [r.kinds, r.s.mode, r.s.jobs.unavailable, r.s.instances.spawns], [["job-issue", "job-end:unavailable"], "unavailable", 1, 0]);
  await ctx.close();
}

// Manual mode: held until runEffect; a held job cancelled.
{
  const { page, ctx } = await open({ manualEffects: true });
  const r = await page.evaluate(async () => {
    window.__click("Upper");
    await window.__sleep(30);
    const id = window.__rt.pendingEffects()[0].id;
    await window.__rt.runEffect(id);
    const ran = window.__rt.monitor.snapshot().recent[0];
    window.__click("Panel");
    window.__click("Panel");
    return { ran, held: window.__rt.monitor.snapshot().recent[1] };
  });
  check("manual: held until runEffect", [r.ran.outcome, r.ran.ms.held >= 30, r.ran.t.submit > r.ran.t.issue], ["done", true, true]);
  check("manual: a held job cancelled", [r.held.outcome, r.held.phase, r.held.cancelledBy], ["cancelled", "held", "engine"]);
  await ctx.close();
}

// Containment: a running job's instance ends `contained`, then the job,
// then the runtime event; nothing after. Unmount the same with `unmount`.
{
  const { page, ctx } = await open({});
  const r = await page.evaluate(async () => {
    window.__click("Panel");
    await window.__sleep(50);
    const n = window.__events.length;
    window.__click("Missing");
    const tail = window.__kinds(window.__events.slice(n));
    const evs = window.__events.slice(n);
    await window.__sleep(50);
    return { tail, by: evs.find((e) => e.kind === "job-end").record.cancelledBy, fault: evs.at(-1).fault, after: window.__events.length - n, s: window.__rt.monitor.snapshot() };
  });
  check("poison: the instance, then its job, then the runtime", r.tail, ["instance-end:contained", "job-end:cancelled", "runtime:poisoned"]);
  check("poison: attributed to containment, with the fault", [r.by, r.fault.class, r.after, r.s.state, r.s.pool.instances], ["contained", "contract", 3, "poisoned", 0]);
  await ctx.close();
}
{
  const { page, ctx } = await open({});
  const r = await page.evaluate(async () => {
    window.__click("Panel");
    await window.__sleep(50);
    const n = window.__events.length;
    window.__rt.unmount();
    return { tail: window.__kinds(window.__events.slice(n)), s: window.__rt.monitor.snapshot() };
  });
  check("unmount: the instance, then its job, then the runtime", r.tail, ["instance-end:unmount", "job-end:cancelled", "runtime:unmounted"]);
  check("the final snapshot stays readable", [r.s.state, r.s.jobs.cancelled, r.s.instances.ended.unmount], ["unmounted", 1, 1]);
  await ctx.close();
}

// Opt-ins: payloads, User Timing; a throwing listener; the history bound.
{
  const { page, ctx } = await open({ monitor: { payloads: true, userTiming: true, history: 2 } });
  const r = await page.evaluate(async () => {
    const errors = [];
    const err = console.error;
    console.error = (m) => errors.push(String(m));
    window.__rt.monitor.subscribe(() => {
      throw new Error("observer bug");
    });
    for (let i = 1; i <= 5; i += 1) {
      window.__click("Upper");
      await window.__until((l) => l.length === i);
    }
    console.error = err;
    await window.__sleep(20);
    const issue = window.__events.find((e) => e.kind === "job-issue");
    const end = window.__events.find((e) => e.kind === "job-end");
    const s = window.__rt.monitor.snapshot();
    return {
      input: new TextDecoder().decode(issue.input),
      output: new TextDecoder().decode(end.output),
      recordBytes: window.__hasBytes(s),
      errors: errors.filter((e) => e.includes("observer bug")).length,
      log: window.__entries().length,
      recent: s.recent.map((j) => j.id),
      dropped: s.recentDropped,
      measures: window.__measures,
    };
  });
  check("payloads: copies in the events only", [r.input, r.output, r.recordBytes], ["job 1", "JOB 1", false]);
  check("a throwing listener is reported once and dropped; jobs still delivered", [r.errors, r.log], [1, 5]);
  check("history bound: the last 2 of 5", [r.recent.length, r.dropped], [2, 3]);
  const names = [...new Set(r.measures.map((m) => m.name))].sort();
  check("User Timing spans seen by a PerformanceObserver", names, ["roc:work test.roc-signals/upper", "roc:work.cold", "roc:work.queue", "roc:work.result", "roc:work.run", "roc:worker 1 spawn"]);
  const job = r.measures.find((m) => m.name === "roc:work test.roc-signals/upper");
  check("a job span carries its detail and DevTools track", [job.detail.outcome, job.detail.inputBytes, job.detail.devtools.trackGroup, job.detail.devtools.track, job.duration > 0], ["done", 5, "roc workers", "jobs", true]);
  await ctx.close();
}

// Cost when nobody observes: count the runtime's clock reads (the page's
// `performance.now`; the worker's are on its own thread) and measures.
{
  const { page, ctx } = await open({}, { subscribe: false });
  const r = await page.evaluate(async () => {
    window.__click("Upper");
    await window.__until((l) => l.length === 1);
    let now = 0;
    let measures = 0;
    const realNow = performance.now.bind(performance);
    const realMeasure = performance.measure.bind(performance);
    performance.now = () => {
      now += 1;
      return realNow();
    };
    performance.measure = (...a) => {
      measures += 1;
      return realMeasure(...a);
    };
    window.__rounds(7);
    const domTurn = now;
    window.__click("Upper");
    await window.__until((l) => l.length === 2);
    const job = now - domTurn;
    window.__rt.monitor.subscribe(() => {}, { turns: true });
    const before = now;
    window.__rounds(8);
    const observedTurn = now - before;
    performance.now = realNow;
    performance.measure = realMeasure;
    return { domTurn, job, measures, observedTurn };
  });
  check("unobserved: a DOM turn reads no clock", r.domTurn, 0);
  check("unobserved: a warm job reads the clock at most 8 times, no measures", [r.job <= 8, r.measures], [true, 0]);
  check("a turn subscriber times every turn (3 reads)", r.observedTurn, 3);
  console.log(`     clock reads per warm job, unobserved: ${r.job}`);
  await ctx.close();
}

await browser.close();
server.close();
console.log(failures === 0 ? "== monitor browser contract: all pass" : `== monitor browser contract: ${failures} failures`);
process.exit(failures === 0 ? 0 : 1);
