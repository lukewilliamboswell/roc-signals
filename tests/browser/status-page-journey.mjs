// status-page-journey.mjs --wasm APP.wasm --runtime runtime.mjs --chrome PATH
//   [--plotly plotly.min.js] [--measure-ms N] [--screenshot FILE]
// -- the Status Page in headless Chrome with its own JavaScript: the
// simulated checks (examples/status-page/backend.mjs, served over HTTP),
// the seeded latency stream (examples/status-page/ports.mjs) and the port
// monitor element (feed-monitor.mjs), which the specs stand in for. What
// only the real stream can show:
// - readings arrive at the stream's pace, each a turn, and what the app
//   counts is what the runtime's monitor counts;
// - a page whose thread was blocked catches up: the stream's backlog meets
//   the subscription's bound (`Every(16)`), the refused emits are offered
//   again on later frames, and no reading is lost;
// - a dropped connection replays what the stream buffered at the page's
//   pace and drops (and counts) only what its own buffer could not hold,
//   which the chart shows as a gap;
// - pausing and hiding end the subscription, and the stream stops;
// - nothing reaches the console as a fault.
// With `--plotly` the charts are really drawn, and `--measure-ms` then
// reports messages and turns a second, the chart's JSON per update and the
// longest gap between frames over that time (reported, never asserted).
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const example = path.resolve(here, "../../examples/status-page");
const opts = parseArgs(process.argv.slice(2), ["plotly", "measure-ms", "screenshot"]);
const handle = (await import(path.join(example, "backend.mjs"))).default();
const PORT = "roc-signals.example/status-page/latency";

const page_html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Status Page</title>
${opts.plotly ? '<script src="plotly.min.js"></script>' : ""}
</head><body><div id="app"></div>
<script type="module">
  import { mountRocEngineApp } from "./runtime.mjs";
  import ports from "./ports.mjs";
  import "./plume-chart.mjs";
  import "./feed-monitor.mjs";
  const root = document.getElementById("app");
  try {
    window.__rt = await mountRocEngineApp({ wasmUrl: "app.wasm", root, ports });
    root.dispatchEvent(new CustomEvent("roc-signals:runtime", { bubbles: true, detail: { runtime: window.__rt } }));
    window.__ready = true;
  } catch (e) {
    window.__error = String(e && e.stack ? e.stack : e);
  }
</script></body></html>`;

const files = {
  "ports.mjs": path.join(example, "ports.mjs"),
  "feed-monitor.mjs": path.join(example, "feed-monitor.mjs"),
  "plume-chart.mjs": path.join(example, "../shared/plume-chart.mjs"),
  ...runtimeFiles(opts.runtime),
  "app.wasm": opts.wasm,
  ...(opts.plotly ? { "plotly.min.js": opts.plotly } : {}),
};
const server = http.createServer(async (req, res) => {
  const u = new URL(req.url, "http://x");
  if (u.pathname.startsWith("/api/")) {
    let r;
    try {
      r = await handle({ method: req.method, uri: u.pathname });
    } catch {
      req.socket.destroy();
      return;
    }
    res.writeHead(r ? r.status : 404, { "content-type": "text/plain" });
    res.end(r ? r.body : "");
    return;
  }
  if (u.pathname.endsWith("/")) {
    res.writeHead(200, { "content-type": "text/html" });
    res.end(page_html);
    return;
  }
  const f = files[path.basename(u.pathname)];
  if (!f) {
    res.writeHead(404);
    res.end();
    return;
  }
  res.writeHead(200, { "content-type": f.endsWith(".wasm") ? "application/wasm" : "text/javascript" });
  res.end(fs.readFileSync(f));
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const browser = await launch({ executablePath: opts.chrome });

let failures = 0;
const check = (name, ok, detail = "") => {
  if (!ok) failures += 1;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok ? "" : `: ${detail}`}`);
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const ctx = await browser.createBrowserContext();
const page = await ctx.newPage();
await page.send("Emulation.setDeviceMetricsOverride", { width: 1100, height: 2200, deviceScaleFactor: 1, mobile: false });
const pageErrors = [];
page.on("pageerror", (e) => pageErrors.push(String(e)));
await page.evaluateOnNewDocument(() => {
  window.__errors = [];
  const error = console.error.bind(console);
  console.error = (...args) => {
    window.__errors.push(args.map(String).join(" "));
    error(...args);
  };
  window.__text = (id) => document.querySelector(`[data-testid="${id}"]`)?.textContent ?? null;
  window.__click = (name) => {
    const b = [...document.querySelectorAll("button")].find((x) => x.textContent === name);
    if (!b) throw new Error(`no button ${name}`);
    b.click();
  };
  window.__figure = () => JSON.parse(document.querySelector('[data-testid="latency-chart"]').dataset.figure);
  window.__monitor = (port) => window.__rt.monitor.snapshot().ports[port] ?? null;
  window.__setVisible = (vis) => {
    Object.defineProperty(document, "visibilityState", { get: () => vis, configurable: true });
    Object.defineProperty(document, "hidden", { get: () => vis === "hidden", configurable: true });
    document.dispatchEvent(new Event("visibilitychange"));
  };
});
await page.goto(`http://127.0.0.1:${server.address().port}/status-page/`);
await page.waitForFunction("window.__ready || window.__error");
const mountError = await page.evaluate(() => window.__error ?? null);
if (mountError) throw new Error(mountError);

const state = () =>
  page.evaluate((port) => {
    const m = window.__monitor(port);
    const api = window.__figure().data[0].y;
    return {
      received: Number(window.__text("live-received")),
      dropped: Number(window.__text("live-dropped")),
      rejected: Number(window.__text("live-rejected")),
      status: window.__text("live-status"),
      gaps: api.filter((y) => y === null).length,
      points: api.filter((y) => y !== null).length,
      messages: m?.messages ?? 0,
      refused: m?.refusedEmits ?? 0,
      coalesced: m?.coalesced ?? 0,
      subscriptions: m?.subscriptions ?? 0,
      backlog: m?.backlog ?? 0,
      monitorShown: document.querySelector("latency-feed-monitor")?.shadowRoot?.querySelector('[data-field="messages"]')?.textContent ?? null,
    };
  }, PORT);

// 1. The stream runs at its pace; the app keeps what the monitor delivered.
await sleep(2200);
let s = await state();
check("readings arrive at the stream's pace (about four a second)", s.received >= 6 && s.received <= 12, JSON.stringify(s));
check("the app kept every message the runtime delivered", s.received + 1 === s.messages && s.rejected === 0, JSON.stringify(s));
check("one live subscription, nothing refused, nothing replaced, nothing dropped", s.subscriptions === 1 && s.refused === 0 && s.coalesced === 0 && s.dropped === 0 && s.gaps === 0, JSON.stringify(s));
await sleep(300);
s = await state();
check("the monitor element shows the runtime's count", s.monitorShown !== null && Math.abs(Number(s.monitorShown) - s.messages) <= 2, JSON.stringify(s));
const checks = await page.evaluate(() => window.__text("overall-rollup"));
check("the checks answered through the example's backend", checks !== "Checking services", checks);

// 2. A blocked thread: five seconds of readings wait, more than the bound.
const before = await state();
await page.evaluate(() => {
  const t = performance.now();
  while (performance.now() - t < 5000);
});
await sleep(1500);
s = await state();
check("after a 5 s stall the stream caught up: emits were refused and offered again", s.refused > before.refused, JSON.stringify({ before, after: s }));
check("no reading was lost: no gap, nothing dropped", s.gaps === 0 && s.dropped === 0 && s.received + 1 === s.messages && s.received - before.received >= 20, JSON.stringify({ before, after: s }));

// 3. A real ended subscription retries in Roc after its seeded backoff.
const offline = await state();
await page.evaluate(() => window.__click("Drop the connection"));
const during = await state();
check("a dropped connection ends its subscription and displays a bounded backoff", during.subscriptions === 0 && /^Connection lost: reconnecting in 1(?:\.[0-9]+)? s \(attempt 1\)$/.test(during.status), JSON.stringify(during));
await sleep(1800);
s = await state();
check("Roc opened one new connection and resumed without a gap", s.subscriptions === 1 && s.received > offline.received && s.rejected === 0 && s.gaps === 0 && s.dropped === 0, JSON.stringify(s));

// A loss longer than the server's 64-reading history reports its gap.
// Block the page before dropping: no old connection can offer its backlog.
await page.evaluate(() => {
  const until = performance.now() + 17000;
  while (performance.now() < until);
  window.__click("Drop the connection");
});
await sleep(2400);
s = await state();
check("a long outage reports the readings beyond bounded history", s.dropped >= 4 && s.dropped <= 20 && s.gaps >= 1 && s.rejected === 0, JSON.stringify(s));
check("replayed history passes through the subscription's bound", s.refused > offline.refused, JSON.stringify(s));
check("the window stays bounded", s.points <= 120, JSON.stringify(s));
if (opts.screenshot) {
  const { data } = await page.send("Page.captureScreenshot", { format: "png", captureBeyondViewport: true });
  fs.writeFileSync(opts.screenshot, Buffer.from(data, "base64"));
  console.log(`   screenshot: ${opts.screenshot}`);
}

// 4. Pausing ends the subscription and the stream stops.
await page.evaluate(() => window.__click("Pause the feed"));
await sleep(300);
const paused = await state();
await sleep(1000);
s = await state();
check("paused: no subscription, and the stream sends nothing", paused.subscriptions === 0 && s.received === paused.received && s.messages === paused.messages, JSON.stringify({ paused, later: s }));
await page.evaluate(() => window.__click("Resume the feed"));
await sleep(1200);
s = await state();
check("resumed: a new subscription replays the short pause without a gap", s.subscriptions === 1 && s.received > paused.received && s.rejected === 0 && s.gaps === paused.gaps, JSON.stringify({ paused, resumed: s }));

// 5. Hiding the page ends the subscription; showing it subscribes again.
await page.evaluate(() => window.__setVisible("hidden"));
await sleep(300);
const hidden = await state();
await sleep(1000);
s = await state();
check("hidden: no subscription, and the stream sends nothing", hidden.subscriptions === 0 && s.messages === hidden.messages, JSON.stringify({ hidden, later: s }));
await page.evaluate(() => window.__setVisible("visible"));
await sleep(1200);
s = await state();
check("shown again: the feed resumes", s.subscriptions === 1 && s.messages > hidden.messages, JSON.stringify(s));

// 6. Measurements, with the charts really drawn.
if (opts.plotly && opts["measure-ms"]) {
  const ms = Number(opts["measure-ms"]);
  const m = await page.evaluate(async (ms, port) => {
    const rt = window.__rt;
    let turns = 0;
    let longest = 0;
    let last = performance.now();
    let sizes = [];
    const un = rt.monitor.subscribe((e) => {
      if (e.kind === "turn") turns += 1;
    }, { turns: true });
    const chart = document.querySelector('[data-testid="latency-chart"]');
    const watch = new MutationObserver(() => sizes.push(chart.dataset.figure.length));
    watch.observe(chart, { attributes: true, attributeFilter: ["data-figure"] });
    let raf = 0;
    const frame = (t) => {
      longest = Math.max(longest, t - last);
      last = t;
      raf = requestAnimationFrame(frame);
    };
    raf = requestAnimationFrame(frame);
    const m0 = rt.monitor.snapshot().ports[port].messages;
    await new Promise((r) => setTimeout(r, ms));
    cancelAnimationFrame(raf);
    un();
    watch.disconnect();
    const m1 = rt.monitor.snapshot().ports[port].messages;
    return { seconds: ms / 1000, messagesPerSecond: (m1 - m0) / (ms / 1000), turnsPerSecond: turns / (ms / 1000), chartUpdates: sizes.length, chartBytesMax: Math.max(...sizes), chartBytesMean: Math.round(sizes.reduce((a, b) => a + b, 0) / sizes.length), longestFrameGapMs: Math.round(longest) };
  }, ms, PORT);
  console.log(`   measured: ${JSON.stringify(m)}`);
}

const errors = await page.evaluate(() => window.__errors);
const poisoned = await page.evaluate(() => window.__rt.poisoned);
check("no fault, no console error, no page error", poisoned === null && errors.length === 0 && pageErrors.length === 0, JSON.stringify({ poisoned, errors, pageErrors }));

await ctx.close();
await browser.close();
server.close();
console.log(failures === 0 ? "== status page journey: all pass" : `== status page journey: ${failures} failures`);
process.exit(failures === 0 ? 0 : 1);
