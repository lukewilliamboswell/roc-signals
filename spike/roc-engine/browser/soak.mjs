// soak.mjs APP_DIR APP [EVENTS] -- long session in headless Chrome.
// 1. A seeded random walk of EVENTS user events (default 3000) chosen from
//    the live DOM (elements carrying engine handlers, disabled ones skipped):
//    clicks, typed values with input events, checkbox/select changes.
//    Conduit runs with automatic effects against the RealWorld mock backend.
//    The instance must never fault.
// 2. On a fresh page, an app round trip (back to the initial state) 30 times:
//    Wasm memory pages and the host's live allocation count (metric 4) must
//    be flat after 3 warm-up cycles.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, "../../..");
const puppeteer = createRequire(path.join(process.env.NODE_PATH ?? ".", "x.js"))("puppeteer-core");
const [appDir, app, eventsArg] = process.argv.slice(2);
const EVENTS = Number(eventsArg ?? 3000);
const conduit = app === "conduit";
let handle = null;
if (conduit) handle = (await import(path.join(repo, "www/static/conduit_backend.mjs"))).createConduitHandler({});

const files = {
  "index.html": path.join(here, "index.html"),
  "locate.js": path.join(here, "locate.js"),
  "runtime.mjs": path.join(here, "..", "platform", "runtime.mjs"),
  "app.wasm": path.join(appDir, "app.wasm"),
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
const base = `http://127.0.0.1:${server.address().port}/roc-signals/examples-web/conduit/#/`;
const browser = await puppeteer.launch({ executablePath: "/usr/bin/google-chrome", headless: true, args: ["--no-sandbox"] });

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
  const done = await page.evaluate(async (n, conduit) => {
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
      if (conduit && i % 10 === 9) await new Promise((r) => setTimeout(r, 0));
    }
    return { fired, fault: rt.poisoned };
  }, EVENTS, conduit);
  if (conduit) await settle(page);
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
  "markdown-editor": [["click", ["role", "button", "Append a section"]], ["click", ["role", "button", "Remove the last section"]]],
  conduit: [["click", ["role", "link", "Sign in"]], ["click", ["role", "link", "Home"]]],
};
{
  const { ctx, page } = await open();
  if (conduit) await settle(page);
  const cycle = CYCLES[app];
  const samples = [];
  for (let c = 0; c < 30; c += 1) {
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
      if (conduit) await settle(page);
    }
    samples.push(await page.evaluate(() => [window.__rt.x.memory.buffer.byteLength / 65536, Number(window.__rt.x.metric(4))]));
  }
  // Flat: identical pages; live allocations with no growth (the later half
  // never exceeds the earlier half). Exact equality is also reported: an
  // async effect app may jitter by an allocation depending on timing.
  const tail = samples.slice(3);
  const half = Math.floor(tail.length / 2);
  const maxOf = (xs) => Math.max(...xs.map((s) => s[1]));
  const pagesFlat = tail.every((s) => s[0] === tail[0][0]);
  const noGrowth = maxOf(tail.slice(half)) <= maxOf(tail.slice(0, half));
  const exact = tail.every((s) => s[1] === tail[0][1]);
  check(`30 round trips: pages flat, no live-allocation growth after 3 warm-up cycles (exactly equal: ${exact})`, pagesFlat && noGrowth && !(await page.evaluate(() => window.__rt.poisoned)), JSON.stringify(samples));
  console.log(`   cycles (pages, live): ${JSON.stringify(samples.slice(0, 5))} ... ${JSON.stringify(samples.slice(-2))}`);
  await ctx.close();
}
await browser.close();
server.close();
console.log(failures === 0 ? `== soak ${app}: all pass` : `== soak ${app}: ${failures} failures`);
process.exit(failures === 0 ? 0 : 1);
