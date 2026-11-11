// log-explorer-journey.mjs --wasm APP.wasm --runtime runtime.mjs --chrome PATH
// -- the Log Explorer (examples/log-explorer) in headless Chrome, with real
// workers and real files, through the app's own controls and
// `runtime.monitor`:
// 1. A generated log of more than 64 MiB is prepared once: the overview, a
//    listing, two searches (the first superseded while it runs, which its
//    task's `on_cancel: Finish` lets complete so the worker keeps the
//    index), the viewer, and the viewer opened at a minute by the
//    timeline chart's click (its element's value and change event, as
//    `plume-chart` reports a click) are one preparation and reuses on the
//    worker that holds it; going back to the overview asks nothing. The
//    answers, and the timeline's lines for errors and for a search's
//    matches, equal counts made here while generating the log. The
//    example's own `log-timings` element shows the preparation's time as
//    the monitor recorded it. It prints the times (the preparation against
//    later questions), the size of the chart's figure, the page's and the
//    holder's linear memory, and the longest gap in the page's timers: the
//    page's memory must not grow by the file, the worker's must stay below
//    the file's size (it keeps the index, not the text), and the page's
//    thread must stay live.
// 2. A new file prepares afresh, and the first file's state is let go.
// 3. A file the browser can no longer read, and a file that is not a log,
//    each reach the page as the preparation's error, which the app matched;
//    a failed preparation is kept, and the next question reuses it.
import http from "node:http";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";

const opts = parseArgs(process.argv.slice(2));
const here = path.dirname(new URL(import.meta.url).pathname);
// The example's own element, which the example's page loads.
const timings = path.resolve(here, "../../examples/log-explorer/timings.mjs");
const files = { ...runtimeFiles(opts.runtime), "app.wasm": opts.wasm, "timings.mjs": timings };
const server = http.createServer((req, res) => {
  const u = new URL(req.url, "http://x");
  if (u.pathname === "/") {
    res.writeHead(200, { "content-type": "text/html" });
    res.end('<!doctype html><html><head><meta charset="utf-8"><title>log explorer</title></head><body></body></html>');
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

const TASK = "roc-signals.example/log-explorer/";

function install() {
  // The task a monitor job record or job event names.
  window.__taskOf = (record) => record.task;
  window.__mount = async (options = {}) => {
    const { mountRocEngineApp } = await import("/runtime.mjs");
    await import("/timings.mjs");
    const root = document.createElement("div");
    document.body.append(root);
    window.__root = root;
    window.__events = [];
    window.__rt = await mountRocEngineApp({ wasmUrl: "/app.wasm", root, onFault: () => {}, ...options });
    window.__rt.monitor.subscribe((e) => window.__events.push(e));
    // As the site's page does once the app is mounted.
    root.dispatchEvent(new CustomEvent("roc-signals:runtime", { bubbles: true, detail: { runtime: window.__rt } }));
    return true;
  };
  // The timeline chart's figure, parsed, and its size.
  window.__figure = () => {
    const text = window.__root.querySelector("[data-testid=timeline]")?.dataset.figure ?? "";
    return { bytes: text.length, figure: text === "" ? null : JSON.parse(text) };
  };
  // A trace's counts, summed.
  window.__traceSum = (figure, name) => (figure?.data.find((t) => t.name === name)?.y ?? []).reduce((a, b) => a + b, 0);
  // What `plume-chart` does when a point is clicked: its x as its value,
  // and a change event.
  window.__pick = (x) => {
    const el = window.__root.querySelector("[data-testid=timeline]");
    el.value = x;
    el.dispatchEvent(new Event("change", { bubbles: true }));
  };
  window.__shadowText = (tag, id) => document.querySelector(tag)?.shadowRoot?.querySelector(`[data-testid=${id}]`)?.textContent ?? null;
  window.__chooseFile = (file) => {
    const dt = new DataTransfer();
    dt.items.add(file);
    const el = window.__root.querySelector('[aria-label="Log file"]');
    el.files = dt.files;
    el.dispatchEvent(new Event("change", { bubbles: true }));
  };
  window.__click = (label) => [...window.__root.querySelectorAll("button")].find((b) => b.textContent === label).click();
  window.__type = (text) => {
    const el = window.__root.querySelector('[aria-label="Text to find"]');
    el.value = text;
    el.dispatchEvent(new Event("input", { bubbles: true }));
  };
  window.__text = (id) => {
    const el = window.__root.querySelector(`[data-testid=${id}]`);
    return el ? el.textContent : null;
  };
  window.__until = (pred, what, ms = 120000) =>
    new Promise((resolve, reject) => {
      const t = setTimeout(() => reject(new Error(`timed out waiting for ${what}`)), ms);
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
      .recent.filter((r) => r.outcome === "done")
      .map((r) => [window.__taskOf(r).split("/").pop(), r.prepared, r.instance]);
  // A log of at least `bytes` bytes, made of 1 MiB parts so no one string
  // holds it, and the counts an independent reader gives it.
  window.__generate = (bytes) => {
    const levels = ["INFO ", "DEBUG", "INFO ", "WARN ", "INFO ", "TRACE", "INFO ", "DEBUG"];
    const sources = ["api", "db", "auth", "cache", "billing", "mailer"];
    const pad = (n, w) => String(n).padStart(w, "0");
    const parts = [];
    let part = "";
    let size = 0;
    let lines = 0;
    let entries = 0;
    let errors = 0;
    let resets = 0;
    let x = 12345;
    // The line (from 1) of the first entry of each minute.
    const minuteLines = [];
    while (size < bytes) {
      x = (x * 1103515245 + 12345) >>> 0;
      const ms = entries;
      if (ms % 60000 === 0) minuteLines.push(lines + 1);
      const time = `2026-11-11T${pad(8 + Math.floor(ms / 3600000), 2)}:${pad(Math.floor(ms / 60000) % 60, 2)}:${pad(Math.floor(ms / 1000) % 60, 2)}.${pad(ms % 1000, 3)}Z`;
      let text;
      if (x % 97 === 0) {
        text = `${time} ERROR db: connection reset by peer\n    at Pool.acquire (pool.roc:88)\n`;
        errors += 1;
        resets += 1;
        lines += 2;
      } else if (x % 89 === 0) {
        text = `${time} ERROR billing: card declined for invoice ${x % 10000}\n`;
        errors += 1;
        lines += 1;
      } else {
        text = `${time} ${levels[x % 8]} ${sources[x % 6]}: request ${x % 100000} handled in ${x % 900} ms for customer ${x % 7919}\n`;
        lines += 1;
      }
      entries += 1;
      part += text;
      size += text.length;
      if (part.length >= 1 << 20) {
        parts.push(part);
        part = "";
      }
    }
    parts.push(part);
    return { file: new File(parts, "big.log", { type: "text/x-log" }), size, lines, entries, errors, resets, minuteLines };
  };
  // The longest gap between the page's 5 ms timer ticks, and the longest
  // long task, since `__watch()`.
  window.__watch = () => {
    const w = { gap: 0, longTask: 0, last: performance.now() };
    w.timer = setInterval(() => {
      const now = performance.now();
      w.gap = Math.max(w.gap, now - w.last);
      w.last = now;
    }, 5);
    w.observer = new PerformanceObserver((list) => {
      for (const e of list.getEntries()) w.longTask = Math.max(w.longTask, e.duration);
    });
    w.observer.observe({ type: "longtask" });
    return () => {
      clearInterval(w.timer);
      w.observer.disconnect();
      return { gap: Math.max(w.gap, performance.now() - w.last), longTask: w.longTask };
    };
  };
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

const MIB = 1 << 20;
const BIG = 64 * MIB + 1;

// 1. A large log: prepared once, every later question reuses it.
{
  const { page, ctx } = await open();
  // Made in a turn of its own, so the time it takes is not measured.
  await page.evaluate((bytes) => {
    window.__made = window.__generate(bytes);
  }, BIG);
  const r = await page.evaluate(async (TASK) => {
    const made = window.__made;
    const rt = window.__rt;
    const pageBefore = { mem: rt.x.memory.buffer.byteLength, live: Number(rt.x.metric(5)) };
    const stop = window.__watch();
    const at = performance.now();
    window.__chooseFile(made.file);
    const overview = await window.__answer("overview", `${made.lines.toLocaleString("en-US")} lines`);
    const prepared = performance.now() - at;
    const errors = window.__text("level-error");
    // The timeline, from the overview's answer: a line a level.
    const overviewFigure = window.__figure();
    const timeline = { errors: window.__traceSum(overviewFigure.figure, "ERROR"), points: overviewFigure.figure.data[0].x.length, bytes: overviewFigure.bytes };
    const prepareShown = await window.__until(() => window.__shadowText("log-timings", "prepare-ms"), "the timings element");
    // A listing from the index alone, then a search that reads the file.
    window.__click("Search");
    const listing = await window.__answer("search-status", `${made.lines.toLocaleString("en-US")} matching`);
    let t = performance.now();
    window.__type("Connection Reset");
    const search = await window.__answer("search-status", `${made.resets.toLocaleString("en-US")} matching`);
    const searched = performance.now() - t;
    // A search superseded while it runs: wait for it to start, then type
    // past it.
    const issued = window.__events.length;
    window.__type("card declined");
    const started = await window.__until(() => {
      const issue = window.__events.slice(issued).find((e) => e.kind === "job-issue" && window.__taskOf(e) === `${TASK}search`);
      return issue && window.__events.find((e) => e.kind === "job-start" && e.id === issue.id) && issue;
    }, "the superseded search to start");
    window.__type("reset by peer");
    const again = await window.__answer("search-status", `${made.resets.toLocaleString("en-US")} matching`);
    // The search's matches, a line on the timeline.
    const searchFigure = window.__figure();
    const matched = { matches: window.__traceSum(searchFigure.figure, "Matches"), bytes: searchFigure.bytes };
    // The viewer reads only the lines it shows.
    window.__click("Viewer");
    await window.__answer("viewer-status", "Lines 1–50");
    t = performance.now();
    window.__click("Last");
    const last = await window.__answer("viewer-status", `Lines ${(made.lines - 49).toLocaleString("en-US")}–`);
    const viewed = performance.now() - t;
    // The overview was asked once, above the tabs: going back asks nothing.
    // A click on its chart opens the viewer at that minute's first line.
    window.__click("Overview");
    const issuedBefore = window.__events.filter((e) => e.kind === "job-issue").length;
    window.__pick("2026-11-11 08:03");
    const picked = await window.__answer("viewer-status", `Lines ${made.minuteLines[3].toLocaleString("en-US")}–`);
    const issuedByPick = window.__events.filter((e) => e.kind === "job-issue").length - issuedBefore;
    await window.__until(() => window.__rt.monitor.snapshot().jobs.done === 7, "the viewer at the picked minute");
    const longest = stop();
    const s = rt.monitor.snapshot();
    const superseded = s.recent.find((x) => x.id === started.id);
    const holder = s.instances.live.find((i) => i.held !== null);
    const done = s.recent.filter((x) => x.outcome === "done");
    const rec = (name) => done.filter((x) => window.__taskOf(x) === `${TASK}${name}`);
    return {
      made: { size: made.size, lines: made.lines, entries: made.entries, errors: made.errors, resets: made.resets, minuteLines: made.minuteLines.length, line3: made.minuteLines[3] },
      answers: { overview, errors, listing, search, again, last, picked },
      timeline,
      matched,
      issuedByPick,
      prepareShown: { text: prepareShown, ms: rec("overview")[0].prepareMs },
      jobs: window.__jobs(),
      counts: { prepared: s.jobs.prepared, reused: s.jobs.reused, endedByCancel: s.instances.ended.cancel },
      superseded: { outcome: superseded.outcome, finished: superseded.finished },
      ms: {
        prepareWall: prepared,
        prepare: rec("overview")[0].prepareMs,
        overviewTask: rec("overview")[0].ms.compute,
        pickTotal: rec("window")[2].ms.total,
        searchWall: searched,
        searchCompute: rec("search")[1].ms.compute,
        viewerWall: viewed,
        viewerCompute: rec("window")[1].ms.compute,
      },
      page: { memBefore: pageBefore.mem, memAfter: rt.x.memory.buffer.byteLength, liveBefore: pageBefore.live, liveAfter: Number(rt.x.metric(5)) },
      worker: { mem: holder.memBytes, peak: holder.peakMemBytes, live: holder.liveBytes },
      longest,
    };
  }, TASK);
  const { made } = r;
  const n = (x) => x.toLocaleString("en-US");
  check(`a ${(made.size / MIB).toFixed(1)} MiB log: the overview counts what the generator wrote`, [r.answers.overview.split(", from")[0], r.answers.errors], [`${n(made.lines)} lines, ${n(made.entries)} entries`, n(made.errors)]);
  check("a listing, two searches and the last page of the viewer answer from the prepared index", [r.answers.listing, r.answers.search, r.answers.again, r.answers.last], [
    `${n(made.lines)} matching lines, page 1 of ${n(Math.ceil(made.lines / 25))}.`,
    `${n(made.resets)} matching lines, page 1 of ${n(Math.ceil(made.resets / 25))}.`,
    `${n(made.resets)} matching lines, page 1 of ${n(Math.ceil(made.resets / 25))}.`,
    `Lines ${n(made.lines - 49)}–${n(made.lines)} of ${n(made.lines)}.`,
  ]);
  const holder = r.jobs[0][2];
  check("the log is prepared once: every later question reuses the state on the worker that holds it", r.jobs, [
    ["overview", "prepare", holder],
    ["search", "reuse", holder],
    ["search", "reuse", holder],
    ["search", "reuse", holder],
    ["window", "reuse", holder],
    ["window", "reuse", holder],
    ["window", "reuse", holder],
  ]);
  check("the timeline counts every error a minute, and a search's matches a minute, from the index", [r.timeline.errors, r.timeline.points, r.matched.matches], [made.errors, made.minuteLines, made.resets]);
  check("a click on the timeline opens the viewer at that minute's first line, asking only the viewer's task", [r.answers.picked.split("–")[0], r.issuedByPick], [`Lines ${n(made.line3)}`, 1]);
  const shownMs = Math.round(r.prepareShown.ms).toLocaleString("en-US");
  check("the example's timings element shows the preparation's time the monitor recorded", r.prepareShown.text.includes(`${r.prepareShown.ms < 10 ? r.prepareShown.ms.toFixed(1) : shownMs} ms`), true);
  check("the superseded search finished (on_cancel: Finish) and no worker was ended by a cancel", [r.superseded, r.counts], [{ outcome: "cancelled", finished: true }, { prepared: 1, reused: 6, endedByCancel: 0 }]);
  check("the page's memory does not hold the file (grows by less than 4 MiB)", r.page.memAfter - r.page.memBefore < 4 * MIB && r.page.liveAfter - r.page.liveBefore < 4 * MIB, true);
  check("the holder keeps the index, not the text (its memory is below the file's size)", r.worker.peak < made.size, true);
  // Relative to the preparation the run measured, so a loaded machine
  // stretches both: a live page's longest gap is a small part of it.
  check("the page's thread stays live while the worker prepares and searches (timer gaps under 200 ms, or a tenth of the preparation)", r.longest.gap < Math.max(200, r.ms.prepareWall / 10), true);
  measured.push(
    ["log size (MiB)", made.size / MIB],
    ["lines", made.lines],
    ["choose to overview, wall (ms)", r.ms.prepareWall],
    ["preparation in the worker (ms)", r.ms.prepare],
    ["overview task after preparing (ms)", r.ms.overviewTask],
    ["viewer opened from the timeline, total (ms)", r.ms.pickTotal],
    ["timeline points a line", r.timeline.points],
    ["timeline figure, overview / with a search (KiB)", `${(r.timeline.bytes / 1024).toFixed(1)} / ${(r.matched.bytes / 1024).toFixed(1)}`],
    ["search with text, wall (ms)", r.ms.searchWall],
    ["search with text, compute (ms)", r.ms.searchCompute],
    ["viewer page, wall (ms)", r.ms.viewerWall],
    ["viewer page, compute (ms)", r.ms.viewerCompute],
    ["page linear memory before / after (MiB)", `${(r.page.memBefore / MIB).toFixed(1)} / ${(r.page.memAfter / MIB).toFixed(1)}`],
    ["page live bytes before / after (KiB)", `${(r.page.liveBefore / 1024).toFixed(0)} / ${(r.page.liveAfter / 1024).toFixed(0)}`],
    ["holder linear memory now / peak (MiB)", `${(r.worker.mem / MIB).toFixed(1)} / ${(r.worker.peak / MIB).toFixed(1)}`],
    ["holder live bytes (MiB)", r.worker.live / MIB],
    ["longest page timer gap (ms)", r.longest.gap],
    ["longest long task on the page (ms)", r.longest.longTask],
  );

  // 2. A new file prepares afresh, and the first file's state goes with
  // the file.
  const c = await page.evaluate(async () => {
    window.__click("Overview");
    window.__chooseFile(new File(["2026-11-12T09:30:00Z WARN cache: miss for user:7\n".repeat(3)], "small.log", { type: "text/x-log" }));
    const overview = await window.__answer("overview", "3 lines");
    await window.__until(() => window.__rt.monitor.snapshot().instances.evicted.released === 1, "the first file's state to be let go");
    const s = window.__rt.monitor.snapshot();
    return { overview, last: window.__jobs().at(-1).slice(0, 2), prepared: s.jobs.prepared, released: s.instances.evicted.released };
  });
  check("a new file is prepared afresh, and the first file's state is let go", c, {
    overview: "3 lines, 3 entries, from 2026-11-12T09:30:00Z to 2026-11-12T09:30:00Z",
    last: ["overview", "prepare"],
    prepared: 2,
    released: 1,
  });
  await ctx.close();
}

// 3. A file the browser can no longer read: deleted from disk after it
// was chosen. Then a file that is not a log, whose failed preparation the
// worker keeps.
{
  const { page, ctx } = await open();
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "roc-signals-log-explorer-"));
  const file = path.join(dir, "gone.log");
  fs.writeFileSync(file, "2026-11-11T08:00:00Z INFO api: started\n");
  const input = await page.evaluateHandle(() => window.__root.querySelector('[aria-label="Log file"]'));
  await page.send("DOM.setFileInputFiles", { files: [file], objectId: input.objectId });
  fs.rmSync(dir, { recursive: true, force: true });
  const r = await page.evaluate(async () => {
    const unreadable = await window.__answer("overview", "The browser");
    const bytes = new Uint8Array(65536);
    for (let i = 0; i < bytes.length; i += 1) bytes[i] = (i * 2654435761) >>> 24;
    const photo = new File([bytes], "photo.log", { type: "text/x-log" });
    window.__chooseFile(photo);
    const binary = await window.__answer("overview", "This does not");
    // A failed preparation is kept like any other: the next question of
    // the same file answers the same error without preparing again, and
    // choosing the file again is a new input, which prepares afresh.
    window.__click("Search");
    const searched = await window.__answer("search-status", "This does not");
    const reused = window.__jobs().at(-1).slice(0, 2);
    window.__click("Overview");
    window.__chooseFile(photo);
    await window.__until(() => window.__rt.monitor.snapshot().jobs.done === 4, "the file chosen again");
    return { unreadable, binary, searched: [searched, reused], again: window.__jobs().at(-1).slice(0, 2), poisoned: !!window.__rt.poisoned, lost: window.__rt.monitor.snapshot().jobs.lost };
  });
  check("an unreadable file and a file that is not a log are errors the app matched, and no job is lost", r, {
    unreadable: "The browser can no longer read this file. Choose it again.",
    binary: "This does not look like a log: no line starts with a timestamp and a level.",
    searched: ["This does not look like a log: no line starts with a timestamp and a level.", ["search", "reuse"]],
    again: ["overview", "prepare"],
    poisoned: false,
    lost: 0,
  });
  await ctx.close();
}

for (const [name, v] of measured) console.log(`measured ${name}: ${typeof v === "number" ? v.toFixed(1) : v}`);
await browser.close();
server.close();
console.log(failures === 0 ? "log-explorer-journey: passed" : `log-explorer-journey: ${failures} failed`);
process.exit(failures === 0 ? 0 : 1);
