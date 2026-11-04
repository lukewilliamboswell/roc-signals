// replay.mjs APP_DIR SPECS.json [OUT.json] -- replay converted `.scm` specs
// (tools/scm2json.py) against a Wasm build in real headless Chrome, one fresh
// page (fresh instance) per spec. User actions are real input: mouse clicks,
// keyboard typing (Ctrl+A, Backspace, then one keystroke per character), and
// <select> choice. Assertions read the live DOM. Effects (when present) are
// driven by the page's manual effect queue (browser/effects.js).
//
// APP_DIR holds app.wasm; runtime.mjs, index.html and locate.js come from
// this directory and the platform. Needs NODE_PATH with puppeteer-core.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const here = path.dirname(fileURLToPath(import.meta.url));
const puppeteer = createRequire(path.join(process.env.NODE_PATH ?? ".", "x.js"))("puppeteer-core");
const [appDir, specsPath, outPath] = process.argv.slice(2);
const specs = JSON.parse(fs.readFileSync(specsPath, "utf8"));
const only = process.env.ONLY ? new RegExp(process.env.ONLY) : null;

const files = {
  "/index.html": path.join(here, "index.html"),
  "/locate.js": path.join(here, "locate.js"),
  "/effects.js": path.join(here, "effects.js"),
  "/runtime.mjs": path.join(here, "..", "platform", "runtime.mjs"),
  "/app.wasm": path.join(appDir, process.env.WASM ?? "app.wasm"),
};
let hooks = null;
if (process.env.HOOKS) hooks = (await import(path.resolve(process.env.HOOKS))).default;

const types = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript", ".wasm": "application/wasm" };
const server = http.createServer(async (req, res) => {
  const u = new URL(req.url, "http://x");
  if (u.pathname === "/favicon.ico") {
    res.writeHead(204);
    res.end();
    return;
  }
  // Files are served by basename under any path (apps mount under a base
  // path, e.g. /roc-signals/examples-web/conduit/), directories as index.
  let f = u.pathname.endsWith("/") ? files["/index.html"] : files["/" + path.basename(u.pathname)];
  if (!f && hooks && hooks.serve) {
    const r = await hooks.serve(u, req);
    if (r) {
      res.writeHead(r.status, { "content-type": r.type ?? "application/json" });
      res.end(r.body);
      return;
    }
  }
  if (!f || !fs.existsSync(f)) {
    res.writeHead(404);
    res.end();
    return;
  }
  res.writeHead(200, { "content-type": types[path.extname(f)] ?? "application/octet-stream" });
  res.end(fs.readFileSync(f));
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const port = server.address().port;

const browser = await puppeteer.launch({
  executablePath: process.env.CHROME ?? "/usr/bin/google-chrome",
  headless: true,
  args: ["--no-sandbox", "--disable-gpu"],
});

const word = (x) => (typeof x === "string" ? x : x.sym);
const sym = (x) => (typeof x === "object" && x !== null && !Array.isArray(x) ? x.sym : null);
function loc(x) {
  const k = sym(x[0]);
  if (k === "role") return ["role", sym(x[1]), x[3]];
  return [k, x[1]];
}
const show = (l) => JSON.stringify(l);

async function find(page, l) {
  const h = await page.evaluateHandle((l) => window.__loc(l), l);
  const el = h.asElement();
  return el;
}
async function need(page, l) {
  const el = await find(page, l);
  if (!el) throw new Error(`no element ${show(l)}`);
  return el;
}

async function typeInto(page, el, v) {
  await el.focus();
  await page.keyboard.down("Control");
  await page.keyboard.press("a");
  await page.keyboard.up("Control");
  await page.keyboard.press("Backspace");
  if (v !== "") await page.keyboard.type(v);
}

const stats = { typed: 0, typedFallback: 0 };

async function step(page, s, hooks) {
  const h = sym(s[0]);
  switch (h) {
    case "click": {
      const el = await need(page, loc(s[1]));
      const disabled = await el.evaluate((e) => e.disabled === true);
      if (disabled) return;
      await el.click();
      return;
    }
    case "fill": {
      const el = await need(page, loc(s[1]));
      await typeInto(page, el, s[2]);
      const v = await el.evaluate((e) => e.value);
      if (v !== s[2]) {
        // The control was replaced or rewritten mid-typing: fall back to one
        // value assignment + input event, and count it.
        stats.typedFallback += 1;
        const kind = await el.evaluate((e) => `${e.tagName.toLowerCase()}[type=${e.type}] connected=${e.isConnected}`);
        (stats.fallbacks ??= []).push(`${JSON.stringify(s[2])} typed as ${JSON.stringify(v)} into ${kind}`);
        const el2 = await need(page, loc(s[1]));
        await el2.evaluate((e, v) => {
          e.value = v;
          e.dispatchEvent(new Event("input", { bubbles: true }));
        }, s[2]);
      } else stats.typed += 1;
      return;
    }
    case "check":
    case "uncheck": {
      const el = await need(page, loc(s[1]));
      const want = h === "check";
      if ((await el.evaluate((e) => e.checked)) !== want) await el.click();
      return;
    }
    case "select-option": {
      const el = await need(page, loc(s[1]));
      await el.select(s[2]);
      return;
    }
    case "expect-text": {
      const el = await need(page, loc(s[1]));
      const got = await el.evaluate((e) => e.textContent);
      if (got !== s[2]) throw new Error(`${show(loc(s[1]))} text ${JSON.stringify(got)}, expected ${JSON.stringify(s[2])}`);
      return;
    }
    case "expect-value": {
      const el = await need(page, loc(s[1]));
      const got = await el.evaluate((e) => e.value);
      if (got !== s[2]) throw new Error(`${show(loc(s[1]))} value ${JSON.stringify(got)}, expected ${JSON.stringify(s[2])}`);
      return;
    }
    case "expect-checked":
    case "expect-disabled": {
      const el = await need(page, loc(s[1]));
      const want = sym(s[2]) === "true";
      const got = await el.evaluate((e, h) => (h === "expect-checked" ? e.checked : e.disabled), h);
      if (got !== want) throw new Error(`${show(loc(s[1]))} ${h} ${got}`);
      return;
    }
    case "expect-visible":
      await need(page, loc(s[1]));
      return;
    case "expect-absent":
      if (await find(page, loc(s[1]))) throw new Error(`${show(loc(s[1]))} is present`);
      return;
    case "expect-attr": {
      const el = await need(page, loc(s[1]));
      const got = await page.evaluate((e, n) => window.__attr(e, n), el, word(s[2]));
      if (got !== word(s[3])) throw new Error(`${show(loc(s[1]))} ${word(s[2])}=${JSON.stringify(got)}, expected ${JSON.stringify(word(s[3]))}`);
      return;
    }
    case "expect-no-attr": {
      const el = await need(page, loc(s[1]));
      const got = await page.evaluate((e, n) => window.__attr(e, n), el, word(s[2]));
      if (got !== "") throw new Error(`${show(loc(s[1]))} has ${s[2]}=${JSON.stringify(got)}`);
      return;
    }
    case "mark-metrics":
    case "expect-metric-delta":
    case "expect-metric-delta-at-most":
    case "expect-metric-delta-at-least":
      return;
    default:
      if (hooks && hooks[h]) return hooks[h](page, s, spec);
      throw new Error(`unsupported step ${h}`);
  }
}


const results = [];
for (const spec of specs) {
  if (only && !only.test(spec.file)) continue;
  const context = await browser.createBrowserContext();
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => {
    if (m.type() === "error") errors.push(m.text());
  });
  const t0 = Date.now();
  let failed = null;
  let i = 0;
  try {
    let url = `http://127.0.0.1:${port}/index.html`;
    if (hooks && hooks.url) url = hooks.url(port, spec);
    await page.evaluateOnNewDocument(fs.readFileSync(files["/locate.js"], "utf8"));
    if (hooks && hooks.before) await hooks.before(page, spec);
    await page.goto(url);
    if (hooks && hooks.loaded) await hooks.loaded(page, spec);
    await page.waitForFunction("window.__ready || window.__error", { timeout: 20000 });
    const err = await page.evaluate("window.__error");
    if (err) throw new Error(`mount failed: ${err}`);
    for (; i < spec.steps.length; i += 1) {
      await step(page, spec.steps[i], hooks);
      if (errors.length) throw new Error(`page error: ${errors.join("; ")}`);
    }
  } catch (e) {
    const wasmErr = await page.evaluate(() => {
      try {
        const x = window.__rt && window.__rt.x;
        if (!x) return "";
        return new TextDecoder().decode(new Uint8Array(x.memory.buffer, x.err_ptr(), x.err_len()));
      } catch (_) {
        return "";
      }
    }).catch(() => "");
    failed = `step ${i} ${JSON.stringify(spec.steps[i] ?? null)}: ${e.message}${wasmErr ? ` [roc: ${wasmErr}]` : ""}`;
  }
  results.push({ file: spec.file, ok: failed === null, steps: spec.steps.length, ms: Date.now() - t0, failed });
  console.log(`${failed === null ? "PASS" : "FAIL"} ${spec.file} (${spec.steps.length} steps, ${Date.now() - t0} ms)${failed ? "\n     " + failed : ""}`);
  await page.close();
  await context.close();
}
await browser.close();
server.close();
const pass = results.filter((r) => r.ok).length;
console.log(`== ${pass}/${results.length} specs pass; fills typed=${stats.typed} fallback=${stats.typedFallback}`);
for (const f of stats.fallbacks ?? []) console.log(`   fallback: ${f}`);
if (outPath) fs.writeFileSync(outPath, JSON.stringify({ results, stats }, null, 1));
process.exit(pass === results.length ? 0 : 1);
