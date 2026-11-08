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
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { launch } from "./cdp.mjs";
import { parseArgs } from "./args.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, "../..");
const opts = parseArgs(process.argv.slice(2), ["app", "events", "cycles"]);
const app = opts.app;
const EVENTS = Number(opts.events ?? 3000);
const conduit = app === "conduit";
// Apps with effects run against a backend: Conduit's RealWorld mock, and
// small stand-ins for the field-notes sync endpoint (it echoes the token, a
// successful sync) and the status-page checks (every service operational, no
// incidents).
const BACKENDS = {
  "field-notes": async (req) => (req.uri === "/api/notes/sync" ? { status: 200, body: req.body } : null),
  "status-page": async (req) =>
    req.uri === "/api/status/incidents" ? { status: 200, body: "" } : req.uri.startsWith("/api/status/") ? { status: 200, body: "operational|99.99" } : null,
};
let handle = BACKENDS[app] ?? null;
if (conduit) handle = (await import(path.join(repo, "www/static/conduit_backend.mjs"))).createConduitHandler({});
const served = handle !== null;

const files = {
  "index.html": path.join(here, "index.html"),
  "locate.js": path.join(here, "locate.js"),
  "runtime.mjs": opts.runtime,
  "app.wasm": opts.wasm,
};
const server = http.createServer(async (req, res) => {
  const u = new URL(req.url, "http://x");
  if (handle && u.pathname.startsWith("/api/")) {
    let body = "";
    for await (const c of req) body += c;
    const r = await handle({ method: req.method, uri: u.pathname + u.search, headers: req.headers, body });
    res.writeHead(r ? r.status : 404, { "content-type": "application/json" });
    res.end(r ? r.body : "");
    return;
  }
  const f = u.pathname.endsWith("/") ? files["index.html"] : files[path.basename(u.pathname)];
  if (!f) {
    res.writeHead(404);
    res.end();
    return;
  }
  res.writeHead(200, { "content-type": f.endsWith(".wasm") ? "application/wasm" : f.endsWith("html") ? "text/html" : "text/javascript" });
  res.end(fs.readFileSync(f));
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${server.address().port}/roc-signals/examples/conduit/#/`;
const browser = await launch({ executablePath: opts.chrome });

async function open() {
  const ctx = await browser.createBrowserContext();
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  await page.evaluateOnNewDocument(fs.readFileSync(files["locate.js"], "utf8"));
  await page.goto(base);
  await page.waitForFunction("window.__ready || window.__error");
  return { ctx, page, errors };
}

const settle = (page) => page.evaluate(() => new Promise((r) => {
  const rt = window.__rt;
  const t0 = performance.now();
  const tick = () => {
    const http = [...rt.live.values()].some((e) => e.kind === "http");
    if ((!http && rt.queue.length === 0) || performance.now() - t0 > 2000) r();
    else setTimeout(tick, 5);
  };
  setTimeout(tick, 0);
}));

let failures = 0;
const check = (name, ok, detail = "") => {
  if (!ok) failures += 1;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok ? "" : " " + detail}`);
};

// 1. Random walk.
{
  const { ctx, page, errors } = await open();
  const t0 = Date.now();
  const done = await page.evaluate(async (n, served) => {
    const POOL = ["", "a", "Ada", "10", "-3", "2x", "x@y.z", "Lorem ipsum dolor", "Node-0007", "# Title", "Renamed"];
    let seed = 7n;
    const rnd = () => {
      seed = (seed * 6364136223846793005n + 1442695040888963407n) & 0xffffffffffffffffn;
      return Number(seed >> 33n);
    };
    const root = document.getElementById("app");
    const rt = window.__rt;
    let fired = 0;
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
      if (served && i % 10 === 9) await new Promise((r) => setTimeout(r, 0));
    }
    return { fired, fault: rt.poisoned };
  }, EVENTS, served);
  if (served) await settle(page);
  const fault = await page.evaluate(() => window.__rt.poisoned);
  check(`random walk: ${done.fired} events in ${Date.now() - t0} ms, no fault`, done.fired >= Math.min(EVENTS, 1000) && fault === null && errors.length === 0, JSON.stringify({ fault, errors: errors.slice(0, 3) }));
  const stats = await page.evaluate(() => ({ pages: window.__rt.x.memory.buffer.byteLength / 65536, live: Number(window.__rt.x.metric(4)) }));
  console.log(`   after walk: ${stats.pages} pages, ${stats.live} live allocations`);
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
  // Every check answered by the backend stand-in.
  "status-page": [["click", ["role", "button", "Refresh now"]]],
};
{
  const { ctx, page } = await open();
  if (served) await settle(page);
  const cycle = CYCLES[app];
  const NCYC = Number(opts.cycles ?? 30);
  const samples = [];
  for (let c = 0; c < NCYC; c += 1) {
    for (const [op, loc, v] of cycle) {
      const r = await page.evaluate((op, loc, v) => {
        const el = window.__loc(loc);
        if (!el) return `no element ${JSON.stringify(loc)}`;
        if (op === "click") el.click();
        else {
          el.value = v;
          el.dispatchEvent(new Event("input", { bubbles: true }));
        }
        return null;
      }, op, loc, v);
      if (r) throw new Error(r);
      if (served) await settle(page);
    }
    samples.push(await page.evaluate(() => [window.__rt.x.memory.buffer.byteLength / 65536, Number(window.__rt.x.metric(4)), Number(window.__rt.x.metric(5))]));
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
  await ctx.close();
}
await browser.close();
server.close();
console.log(failures === 0 ? `== soak ${app}: all pass` : `== soak ${app}: ${failures} failures`);
process.exit(failures === 0 ? 0 : 1);
