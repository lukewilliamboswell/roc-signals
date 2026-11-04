// conduit-bench.mjs ENGINE APP_WASM N RUNS -- Conduit in headless Chrome,
// spike (ENGINE=spike: platform/runtime.mjs, manual effects) or current
// (ENGINE=current: www/static/signals.mjs with a deferred fetchImpl that the
// bench answers). Same steps as the native bench (apps/conduit/Bench.roc):
// mount (signed in as kim, home), tags, feed (N articles), favorite (Article
// N/2), favorite-response, tag-click ("signals").
//
// Timing, identical for both engines: performance.now() before the action
// (answering a pending request, or a click), and the later of the action's
// synchronous return and the last DOM mutation (MutationObserver) once the
// page has been quiet for 50 ms. So each step includes Wasm, JS decode, the
// effect-result promise hops (current engine) and DOM application, not layout.
// Mount: instantiate is excluded; "mount" times runtime.mount() alone, and
// "first-paint" times module fetch+compile+instantiate+mount. One fresh
// browser context (page) per run. Prints one JSON line per run.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, "../../..");
const puppeteer = createRequire(path.join(process.env.NODE_PATH ?? ".", "x.js"))("puppeteer-core");
const [engine, wasm, nArg, runsArg] = process.argv.slice(2);
const N = Number(nArg);
const RUNS = Number(runsArg ?? 7);
const M = Math.floor(N / 2);
const K = M % 5;

const article = (i, fav = false, count = null, body = false) => {
  const a = {
    slug: `article-${i}`, title: `Article ${i}`, description: `Description ${i}.`, tagList: ["roc"],
    createdAt: "2026-06-01T08:00:00.000Z", favorited: fav, favoritesCount: count ?? i % 5,
    author: { username: i % 2 === 0 ? "anna" : "max", bio: "", image: "https://example.test/a.png", following: false },
  };
  if (body) a.body = "unused";
  return a;
};
const stubs = {
  tags: { url: "/api/tags", body: JSON.stringify({ tags: ["signals", "roc", "webdev"] }) },
  feed: { url: "/api/articles?limit=20&offset=0", body: JSON.stringify({ articles: Array.from({ length: N }, (_, i) => article(i)), articlesCount: N }) },
  fav: { url: `/api/articles/article-${M}/favorite`, body: JSON.stringify({ article: article(M, true, K + 1, true) }) },
};

const pageFor = (engine) => engine === "spike"
  ? `<!doctype html><html><body><div id="app"></div><script type="module">
import { RocEngineRuntime } from "./runtime.mjs";
const t0 = performance.now();
const bytes = await (await fetch("app.wasm")).arrayBuffer();
const { instance } = await WebAssembly.instantiate(bytes, { env: {} });
const root = document.getElementById("app");
const rt = new RocEngineRuntime(instance.exports, root, { manualEffects: true });
const t1 = performance.now();
rt.mount();
const t2 = performance.now();
window.__rt = rt;
window.__mount = { mount: t2 - t1, firstPaint: t2 - t0 };
window.__answer = (url, body) => {
  const id = rt.issued.find((i) => rt.live.has(i) && rt.live.get(i).req && rt.live.get(i).req.url === url);
  if (id === undefined) throw new Error("no pending " + url);
  rt.runEffect(id, { status: 200, body, headers: [["content-type", "application/json"]] });
};
window.__ready = true;
</script></body></html>`
  : `<!doctype html><html><body><div id="app"></div><script type="module">
import { instantiateSignalsWasm, SignalsRuntime } from "./signals.mjs";
window.__pending = [];
const fetchImpl = (uri, init) => new Promise((resolve, reject) => window.__pending.push({ uri: String(uri), init, resolve, reject }));
const t0 = performance.now();
const instance = await instantiateSignalsWasm("app.wasm", { fetchImpl, localStorage: window.localStorage, sessionStorage: window.sessionStorage });
const root = document.getElementById("app");
const rt = new SignalsRuntime(instance.exports, root, { localStorage: window.localStorage, sessionStorage: window.sessionStorage });
const t1 = performance.now();
rt.mount();
const t2 = performance.now();
window.__rt = rt;
window.__mount = { mount: t2 - t1, firstPaint: t2 - t0 };
window.__answer = (url, body) => {
  const i = window.__pending.findIndex((p) => p.uri === url);
  if (i < 0) throw new Error("no pending " + url + " in " + window.__pending.map((p) => p.uri).join(","));
  const p = window.__pending.splice(i, 1)[0];
  p.resolve(new Response(body, { status: 200, headers: { "content-type": "application/json" } }));
};
window.__ready = true;
</script></body></html>`;

const files = {
  "runtime.mjs": path.join(here, "..", "platform", "runtime.mjs"),
  "app.wasm": wasm,
  "locate.js": path.join(here, "locate.js"),
};
const staticDir = path.join(repo, "www", "static");
const server = http.createServer((req, res) => {
  const u = new URL(req.url, "http://x");
  if (u.pathname.endsWith("/")) {
    res.writeHead(200, { "content-type": "text/html" });
    res.end(pageFor(engine));
    return;
  }
  const name = path.basename(u.pathname);
  let f = files[name];
  if (!f && engine === "current" && fs.existsSync(path.join(staticDir, name))) f = path.join(staticDir, name);
  if (!f) {
    res.writeHead(404);
    res.end();
    return;
  }
  res.writeHead(200, { "content-type": f.endsWith(".wasm") ? "application/wasm" : "text/javascript" });
  res.end(fs.readFileSync(f));
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const url = `http://127.0.0.1:${server.address().port}/roc-signals/examples-web/conduit/#/`;
// JS_FLAGS (e.g. "--no-wasm-lazy-compilation") are passed to V8.
const browser = await puppeteer.launch({
  executablePath: "/usr/bin/google-chrome",
  headless: true,
  args: ["--no-sandbox", ...(process.env.JS_FLAGS ? [`--js-flags=${process.env.JS_FLAGS}`] : [])],
});

// In-page: run `action` (a string naming a page function) and time it.
async function timed(page, action, arg) {
  return page.evaluate(async (action, arg) => {
    const root = document.getElementById("app");
    let last = 0;
    const mo = new MutationObserver(() => {
      last = performance.now();
    });
    mo.observe(root, { subtree: true, childList: true, characterData: true, attributes: true });
    const t0 = performance.now();
    if (action === "answer") window.__answer(arg.url, arg.body);
    else {
      const el = window.__loc(arg);
      if (!el) throw new Error("no element " + JSON.stringify(arg));
      el.click();
    }
    const tSync = performance.now();
    let quietSince = performance.now();
    let seen = last;
    const deadline = t0 + 10000;
    while (performance.now() < deadline) {
      await new Promise((r) => setTimeout(r, 10));
      if (last !== seen) {
        seen = last;
        quietSince = performance.now();
      } else if (performance.now() - quietSince >= 50) break;
    }
    mo.disconnect();
    return Math.max(last, tSync) - t0;
  }, action, arg);
}

for (let run = 0; run < RUNS; run += 1) {
  const ctx = await browser.createBrowserContext();
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  if (process.env.PEEK) page.on("console", (m) => console.log("console:", m.text()));
  await page.evaluateOnNewDocument(fs.readFileSync(files["locate.js"], "utf8"));
  await page.evaluateOnNewDocument(() => {
    localStorage.setItem("conduit.jwt", "jwt.conduit.kim");
    // The current-engine bench build stores the token under a 17-byte key:
    // its browser storage import misreads keys that are Roc small strings
    // (<= 11 bytes on wasm32), so "conduit.jwt" never restores there.
    localStorage.setItem("conduit.jwt.token", "jwt.conduit.kim");
    localStorage.setItem("conduit.username", "kim");
  });
  await page.goto(url);
  await page.waitForFunction("window.__ready", { timeout: 30000 });
  await new Promise((r) => setTimeout(r, 100));
  const out = { engine, n: N, run, ...(await page.evaluate(() => window.__mount)) };
  out.tags = await timed(page, "answer", stubs.tags);
  out.feed = await timed(page, "answer", stubs.feed);
  const rows = await page.evaluate(() => document.querySelectorAll("article").length);
  if (process.env.PEEK) console.log(await page.evaluate(() => [JSON.stringify(localStorage), location.href,window.__pending && window.__pending.map((p) => p.uri), [...document.querySelectorAll("button")].map((b) => b.getAttribute("aria-label") || b.textContent).slice(0, 5), document.getElementById("app").textContent.slice(0, 400)]));
  out.favorite = await timed(page, "click", ["role", "button", `Favorite Article ${M} (${K})`]);
  out["favorite-response"] = await timed(page, "answer", stubs.fav);
  const unfav = await page.evaluate((l) => window.__loc(l) !== null, ["role", "button", `Unfavorite Article ${M} (${K + 1})`]);
  out["tag-click"] = await timed(page, "click", ["role", "link", "signals"]);
  out.check = { rows, unfav, loc: await page.evaluate(() => location.hash), errors };
  console.log(JSON.stringify(out));
  await ctx.close();
}
await browser.close();
server.close();
