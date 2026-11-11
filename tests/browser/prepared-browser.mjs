// prepared-browser.mjs --wasm APP.wasm --runtime runtime.mjs --chrome PATH --
// browser contract test of prepared state with tests/apps/prepared in
// headless Chrome (design.md, "Prepared state"). Through the app's own
// controls and `runtime.monitor` it shows that one preparation backs three
// tasks (one prepare, then reuses on the same worker, answers equal to an
// independent count), and covers the pool's transitions: a changed input
// prepares on another worker and the first state is reused when the input
// comes back; a job waits behind the worker preparing its state rather than
// preparing again; a cancelled job under `Stop` ends its worker and under
// `Finish` completes and leaves the state for the next job; a holder lost
// while a job waits for it sends that job to prepare elsewhere; releasing
// the file lets the state go and the worker's live allocations return to
// what they were before its first job; `maxWorkers: 1` replaces states; a
// worker over `maxWorkerBytes` is retired after its job; unmounting ends
// workers that hold states; a preparation that fails (a document that is
// not UTF-8, or one deleted from disk) answers every task with its error;
// and with `workers: "inline"` a preparation that reads its file is
// unavailable and the page goes on. It prints the
// measurements the pull request reports (prepare once against every time,
// cancel policies).
import http from "node:http";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";

// `--balance no` skips only the check that a worker's allocations return
// exactly to their baseline: under `--specialize=no` a derived record decode
// leaks on every call (https://github.com/roc-lang/roc/issues/12945), so that
// build is judged by its answers and the eviction alone.
const opts = parseArgs(process.argv.slice(2), ["balance"]);
const balance = opts.balance !== "no";
const files = { ...runtimeFiles(opts.runtime), "app.wasm": opts.wasm };
const server = http.createServer((req, res) => {
  const u = new URL(req.url, "http://x");
  if (u.pathname === "/") {
    res.writeHead(200, { "content-type": "text/html" });
    res.end('<!doctype html><html><head><meta charset="utf-8"><title>prepared</title></head><body></body></html>');
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
const timings = [];

function install() {
  window.__mount = async (options = {}) => {
    const { mountRocEngineApp } = await import("/runtime.mjs");
    const root = document.createElement("div");
    document.body.append(root);
    window.__root = root;
    window.__events = [];
    window.__rt = await mountRocEngineApp({ wasmUrl: "/app.wasm", root, onFault: () => {}, ...options });
    window.__rt.monitor.subscribe((e) => window.__events.push(e));
    return true;
  };
  // A document of `n` copies of two lines: three words, then two.
  window.__doc = (n) => "alpha beta gamma\nBeta alpha\n".repeat(n);
  window.__choose = (text) => {
    const dt = new DataTransfer();
    dt.items.add(new File([text], "doc.txt", { type: "text/plain" }));
    const el = window.__root.querySelector('[aria-label="Document"]');
    el.files = dt.files;
    el.dispatchEvent(new Event("change", { bubbles: true }));
  };
  // A document of raw bytes, which need not be text.
  window.__chooseBytes = (bytes) => {
    const dt = new DataTransfer();
    dt.items.add(new File([new Uint8Array(bytes)], "doc.bin", { type: "application/octet-stream" }));
    const el = window.__root.querySelector('[aria-label="Document"]');
    el.files = dt.files;
    el.dispatchEvent(new Event("change", { bubbles: true }));
  };
  window.__click = (label) => [...window.__root.querySelectorAll("button")].find((b) => b.textContent === label).click();
  window.__toggle = (label) => window.__root.querySelector(`[aria-label="${label}"]`).click();
  window.__type = (text) => {
    const el = window.__root.querySelector('[aria-label="Word"]');
    el.value = text;
    el.dispatchEvent(new Event("input", { bubbles: true }));
  };
  window.__text = (id) => {
    const el = window.__root.querySelector(`[data-testid=${id}]`);
    return el ? el.textContent : null;
  };
  window.__until = (pred, what) =>
    new Promise((resolve, reject) => {
      const t = setTimeout(() => reject(new Error(`timed out waiting for ${what}`)), 30000);
      const tick = () => {
        const v = pred();
        if (v) {
          clearTimeout(t);
          resolve(v);
        } else setTimeout(tick, 2);
      };
      tick();
    });
  window.__answer = (id, prefix) => window.__until(() => (window.__text(id) ?? "").startsWith(prefix) && window.__text(id), `${id} ${prefix}`);
  // The finished jobs, in order: [task, prepared or reused, instance].
  window.__jobs = () =>
    window.__rt.monitor
      .snapshot()
      .recent.filter((r) => r.outcome !== "cancelled")
      .map((r) => [r.task.split("/").pop(), r.prepared, r.instance]);
}

async function open(options = {}) {
  const ctx = await browser.createBrowserContext();
  const page = await ctx.newPage();
  page.on("pageerror", (e) => console.log("pageerror", String(e)));
  const warnings = [];
  page.on("console", (m) => {
    if (m.type() === "warning" || m.type() === "warn") warnings.push(m.text());
  });
  await page.evaluateOnNewDocument(install);
  await page.goto(`${base}/`);
  await page.evaluate((o) => window.__mount(o), options);
  return { page, ctx, warnings };
}

// The same three tasks and a revisit, in a fresh page: one preparation,
// four reuses on one worker, and the answers an independent count gives.
async function threeQueries(page, n) {
  return page.evaluate(async (n) => {
    window.__choose(window.__doc(n));
    const stats = await window.__answer("stats", `${2 * n} lines`);
    window.__click("Top");
    const top = await window.__answer("top", "alpha");
    window.__click("Lookup");
    await window.__answer("lookup", "0 at");
    window.__type("gamma");
    const lookup = await window.__answer("lookup", `${n} at`);
    window.__click("Stats");
    await window.__answer("stats", `${2 * n} lines`);
    const s = window.__rt.monitor.snapshot();
    const rec = s.recent.filter((r) => r.outcome === "done");
    return {
      answers: [stats, top, lookup],
      jobs: window.__jobs(),
      counts: [s.jobs.prepared, s.jobs.reused, s.instances.spawns],
      prepareMs: rec[0].prepareMs,
      firstComputeMs: rec[0].ms.compute,
      reuseComputeMs: rec.slice(1).map((r) => r.ms.compute),
      reuseTotalMs: rec.slice(1).map((r) => r.ms.total),
      firstTotalMs: rec[0].ms.total,
      memMB: s.instances.live[0].memBytes / 1048576,
      liveMB: s.instances.live[0].liveBytes / 1048576,
    };
  }, n);
}

const N = 12000; // about 330 KB of text, 60,000 words
const wantAnswers = [`${2 * N} lines, ${5 * N} words, 4 distinct`, `alpha:${2 * N} Beta:${N} beta:${N}`, `${N} at 1,3,5`];

{
  const { page, ctx } = await open();
  const r = await threeQueries(page, N);
  check("three tasks over one preparation answer as a fresh count does", r.answers, wantAnswers);
  check("one prepare, then every job reuses it on the same worker", r.jobs, [
    ["stats", "prepare", 1],
    ["top", "reuse", 1],
    ["lookup", "reuse", 1],
    ["lookup", "reuse", 1],
    ["stats", "reuse", 1],
  ]);
  check("the monitor counts one preparation and four reuses", r.counts, [1, 4, 1]);
  check("the preparation's time is recorded", typeof r.prepareMs === "number" && r.prepareMs > 0, true);
  timings.push(["prepare, first job (ms)", r.prepareMs], ["first job total (ms)", r.firstTotalMs], ["reused job compute (ms)", Math.max(...r.reuseComputeMs)], ["reused job total, max (ms)", Math.max(...r.reuseTotalMs)], ["holder linear memory (MiB)", r.memMB], ["holder live bytes (MiB)", r.liveMB]);

  // A changed input prepares on a second worker; the first input's state
  // is still held and answers when the input comes back.
  const c = await page.evaluate(async (n) => {
    window.__toggle("Ignore case");
    const folded = await window.__answer("stats", `${2 * n} lines, ${5 * n} words, 3`);
    window.__toggle("Ignore case");
    const back = await window.__answer("stats", `${2 * n} lines, ${5 * n} words, 4`);
    return { folded, back, jobs: window.__jobs().slice(5), spawns: window.__rt.monitor.snapshot().instances.spawns };
  }, N);
  check("a changed input prepares on another worker, and the first state answers again", c, {
    folded: `${2 * N} lines, ${5 * N} words, 3 distinct`,
    back: wantAnswers[0],
    jobs: [
      ["stats", "prepare", 2],
      ["stats", "reuse", 1],
    ],
    spawns: 2,
  });
  await ctx.close();
}

// Two sites asking the same preparation in one turn: the second waits for
// the worker preparing it instead of preparing again elsewhere.
{
  const { page, ctx } = await open();
  const r = await page.evaluate(async (n) => {
    window.__toggle("Summary");
    window.__choose(window.__doc(n));
    await window.__answer("stats", `${2 * n} lines`);
    const summary = await window.__answer("summary", `${2 * n} lines`);
    return { summary, jobs: window.__jobs(), spawns: window.__rt.monitor.snapshot().instances.spawns };
  }, N);
  check("a job waits behind the worker preparing its state", r, {
    summary: `${2 * N} lines`,
    jobs: [
      ["stats", "prepare", 1],
      ["stats", "reuse", 1],
    ],
    spawns: 1,
  });
  await ctx.close();
}

// Cancel policies, on a document large enough that preparing takes a
// while: `Stop` (Stats) ends the worker, and the next job prepares again
// on a new one; `Finish` (Top) lets the run complete, and the next job
// reuses its state.
const BIG = 100000;
{
  const { page, ctx } = await open();
  const r = await page.evaluate(async (n) => {
    window.__choose(window.__doc(n));
    await new Promise((r) => setTimeout(r, 20));
    const t0 = performance.now();
    window.__click("Top");
    const top = await window.__answer("top", "alpha");
    const ms = performance.now() - t0;
    const s = window.__rt.monitor.snapshot();
    return { top, ended: s.instances.ended.cancel, spawns: s.instances.spawns, jobs: window.__jobs(), ms, spawn: s.instances.live.map((i) => [i.readyAt - i.spawnAt, i.instantiateMs])[0] };
  }, BIG);
  check("Stop: a cancelled job ends its worker and the next prepares again", { top: r.top, ended: r.ended, spawns: r.spawns, jobs: r.jobs }, {
    top: `alpha:${2 * BIG} Beta:${BIG} beta:${BIG}`,
    ended: 1,
    spawns: 2,
    jobs: [["top", "prepare", 2]],
  });
  timings.push(["Stop: cancel during preparation, next answer after (ms)", r.ms], ["replacement worker: spawn to ready (ms)", r.spawn[0]], ["replacement worker: instantiate (ms)", r.spawn[1]]);
  await ctx.close();
}
{
  const { page, ctx } = await open();
  const r = await page.evaluate(async (n) => {
    window.__click("Top");
    window.__choose(window.__doc(n));
    await new Promise((r) => setTimeout(r, 20));
    const t0 = performance.now();
    window.__click("Stats");
    const stats = await window.__answer("stats", `${2 * n} lines`);
    const ms = performance.now() - t0;
    const s = window.__rt.monitor.snapshot();
    const cancelled = s.recent.find((x) => x.outcome === "cancelled");
    return { stats, ended: s.instances.ended.cancel, spawns: s.instances.spawns, jobs: window.__jobs(), finished: cancelled.finished, busy: s.pool.busy, ms };
  }, BIG);
  check("Finish: a cancelled job completes and the next reuses its state", { stats: r.stats, ended: r.ended, spawns: r.spawns, jobs: r.jobs, finished: r.finished, busy: r.busy }, {
    stats: `${2 * BIG} lines, ${5 * BIG} words, 4 distinct`,
    ended: 0,
    spawns: 1,
    jobs: [["stats", "reuse", 1]],
    finished: true,
    busy: 0,
  });
  timings.push(["Finish: cancel during preparation, next answer after (ms)", r.ms]);
  await ctx.close();
}

// A holder lost while a job waits for it: the lookup crashes the worker
// that prepared the state, and the summary that waited behind it prepares
// again on another worker.
{
  const { page, ctx } = await open();
  const r = await page.evaluate(async (n) => {
    window.__click("Lookup");
    window.__type("!crash");
    window.__toggle("Summary");
    window.__choose(window.__doc(n));
    const lookup = await window.__answer("lookup", "lost");
    const summary = await window.__answer("summary", `${2 * n} lines`);
    const s = window.__rt.monitor.snapshot();
    return { lookup, summary, fault: s.instances.ended.fault, jobs: window.__jobs() };
  }, N);
  check("a lost holder's waiting job prepares elsewhere", r, {
    lookup: "lost AppCrash",
    summary: `${2 * N} lines`,
    fault: 1,
    jobs: [
      ["lookup", "prepare", 1],
      ["stats", "prepare", 2],
    ],
  });
  await ctx.close();
}

// Releasing the file lets the state go: the worker's live allocations
// return to what they were before its first job.
{
  const { page, ctx } = await open();
  const r = await page.evaluate(async (n, balance) => {
    window.__choose(window.__doc(n));
    await window.__answer("stats", `${2 * n} lines`);
    const ready = window.__events.find((e) => e.kind === "instance-ready");
    const held = window.__rt.monitor.snapshot().instances.live[0];
    window.__click("Forget");
    await window.__until(() => window.__rt.monitor.snapshot().instances.evicted.released === 1, "eviction");
    const live = await window.__until(() => {
      const i = window.__rt.monitor.snapshot().instances.live[0];
      return (balance ? i.liveAllocs === ready.liveAllocs : i.liveAllocs < held.liveAllocs) && i;
    }, "the worker's allocations to return");
    return { heldBefore: held.held, heldAfter: live.held, grewWhileHeld: held.liveAllocs > ready.liveAllocs, files: Number(window.__rt.x.metric(6)) };
  }, N, balance);
  check("releasing the file evicts the state and the worker returns to its baseline", r, { heldBefore: "test.roc-signals/prepared/document", heldAfter: null, grewWhileHeld: true, files: 0 });
  await ctx.close();
}

// One worker: each new input replaces the state it holds.
{
  const { page, ctx } = await open({ maxWorkers: 1 });
  const r = await page.evaluate(async (n) => {
    window.__choose(window.__doc(n));
    await window.__answer("stats", `${2 * n} lines, ${5 * n} words, 4`);
    window.__toggle("Ignore case");
    await window.__answer("stats", `${2 * n} lines, ${5 * n} words, 3`);
    window.__toggle("Ignore case");
    const back = await window.__answer("stats", `${2 * n} lines, ${5 * n} words, 4`);
    const s = window.__rt.monitor.snapshot();
    return { back, jobs: window.__jobs(), replaced: s.instances.evicted.replaced, spawns: s.instances.spawns };
  }, N);
  check("maxWorkers 1: a new input replaces the held state", r, {
    back: wantAnswers[0],
    jobs: [
      ["stats", "prepare", 1],
      ["stats", "prepare", 1],
      ["stats", "prepare", 1],
    ],
    replaced: 2,
    spawns: 1,
  });
  await ctx.close();
}

// A worker grown past maxWorkerBytes is retired after its job, its state
// with it: every job prepares on a fresh worker, with the same answers, and
// the console says so once for the preparation.
{
  const { page, ctx, warnings } = await open({ maxWorkerBytes: 1 });
  const r = await page.evaluate(async (n) => {
    window.__choose(window.__doc(n));
    const stats = await window.__answer("stats", `${2 * n} lines`);
    window.__click("Top");
    const top = await window.__answer("top", "alpha");
    const s = window.__rt.monitor.snapshot();
    return { stats, top, jobs: window.__jobs(), retired: s.instances.ended.retired };
  }, N);
  check("a worker over maxWorkerBytes is retired after its job", r, {
    stats: wantAnswers[0],
    top: wantAnswers[1],
    jobs: [
      ["stats", "prepare", 1],
      ["top", "prepare", 2],
    ],
    retired: 2,
  });
  const oversized = warnings.filter((w) => w.startsWith("roc worker: the state prepared by"));
  check("an oversized state is reported once, naming its preparation", [oversized.length, oversized.length > 0 && oversized[0].includes('"test.roc-signals/prepared/document"')], [1, true]);
  await ctx.close();
}

// Unmounting ends workers that hold states.
{
  const { page, ctx } = await open();
  const r = await page.evaluate(async (n) => {
    window.__toggle("Ignore case");
    window.__choose(window.__doc(n));
    await window.__answer("stats", `${2 * n} lines`);
    window.__rt.unmount();
    return window.__events.filter((e) => e.kind === "instance-end").map((e) => e.cause);
  }, N);
  check("unmounting ends a worker holding a state", r, ["unmount"]);
  await ctx.close();
}

// A preparation that fails reaches the page as its error, in every task
// over it: a file that is not UTF-8 fails `contents_utf8!` with
// InvalidUtf8, and a file deleted from disk after it was chosen cannot be
// read at all. Neither is a lost job, and the worker that failed to prepare
// goes on serving.
{
  const { page, ctx } = await open();
  const r = await page.evaluate(async () => {
    window.__chooseBytes([0x61, 0x6c, 0x70, 0x68, 0x61, 0xff, 0x0a]);
    const stats = await window.__answer("stats", "failed");
    window.__click("Top");
    const top = await window.__answer("top", "failed");
    window.__click("Stats");
    window.__choose(window.__doc(1));
    const after = await window.__answer("stats", "2 lines");
    return { stats, top, after, lost: window.__rt.monitor.snapshot().jobs.lost };
  });
  check("a document that is not UTF-8 fails every task with the preparation's error", r, { stats: "failed Unread(InvalidUtf8)", top: "failed Unread(InvalidUtf8)", after: "2 lines, 5 words, 4 distinct", lost: 0 });
  await ctx.close();
}
{
  const { page, ctx } = await open();
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "roc-signals-prepared-"));
  const file = path.join(dir, "gone.txt");
  fs.writeFileSync(file, "soon gone\n");
  const input = await page.evaluateHandle(() => window.__root.querySelector('[aria-label="Document"]'));
  await page.send("DOM.setFileInputFiles", { files: [file], objectId: input.objectId });
  fs.rmSync(dir, { recursive: true, force: true });
  const r = await page.evaluate(async () => {
    const stats = await window.__answer("stats", "failed");
    window.__click("Top");
    const top = await window.__answer("top", "failed");
    const s = window.__rt.monitor.snapshot();
    return { stats, top, lost: s.jobs.lost, spawns: s.instances.spawns };
  });
  check("an unreadable document fails every task with the preparation's error", r, { stats: "failed Unread(Unreadable)", top: "failed Unread(Unreadable)", lost: 0, spawns: 1 });
  await ctx.close();
}

// Inline, the preparation reads its file through a worker effect the
// page's thread does not have: each job is lost as unavailable, the inline
// instance it left is replaced, and the page goes on.
{
  const { page, ctx } = await open({ workers: "inline" });
  const r = await page.evaluate(async (n) => {
    window.__choose(window.__doc(n));
    const stats = await window.__answer("stats", "lost");
    window.__click("Top");
    const top = await window.__answer("top", "lost");
    const s = window.__rt.monitor.snapshot();
    return { stats, top, poisoned: !!window.__rt.poisoned, spawns: s.instances.spawns };
  }, N);
  check("inline: a preparation that reads its file is unavailable", r, { stats: "lost Unavailable", top: "lost Unavailable", poisoned: false, spawns: 2 });
  await ctx.close();
}

for (const [name, v] of timings) console.log(`measured ${name}: ${v.toFixed(1)}`);
await browser.close();
server.close();
console.log(failures === 0 ? "prepared-browser: passed" : `prepared-browser: ${failures} failed`);
process.exit(failures === 0 ? 0 : 1);
