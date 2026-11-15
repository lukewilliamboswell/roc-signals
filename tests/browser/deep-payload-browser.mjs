// deep-payload-browser.mjs --wasm APP.wasm --runtime runtime.mjs --chrome PATH
// [--tiers default|liftoff|both] -- browser contract test of the worker
// payload's nesting bound with tests/apps/deep-payload, on a development
// build, in real dedicated workers (design.md, "Workers").
//
// Encoding and decoding a payload are recursive, so the bound of 128 levels
// is only safe while the deepest value it admits fits the stack of a
// dedicated worker, the weakest place it runs. This test is what notices
// the compiler's frames growing until it no longer does: the two worst
// measured shapes (a record holding a list of itself, and a tag holding a
// seven-field record) at exactly 128 levels are encoded by the page,
// decoded and encoded again by a worker and decoded by the page, and must
// answer with no fault. Then, through the app's own controls and
// `runtime.monitor`: an input one level past the bound is refused with no
// job started; an answer past it is `TooDeep` and the next job runs on the
// same worker; and a preparation's task whose answer is past it is `TooDeep`
// and the next job reuses the state on the same worker.
//
// `--tiers liftoff` runs it with V8's baseline Wasm compiler only
// (`--liftoff --no-wasm-tier-up`), whose frames are the largest; `both`, the
// default, runs it with the default tiers and then with Liftoff only.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";

const opts = parseArgs(process.argv.slice(2), ["tiers"]);
const tiers = { default: [["default", []]], liftoff: [["liftoff", ["--js-flags=--liftoff --no-wasm-tier-up"]]] };
const configs = opts.tiers === undefined || opts.tiers === "both" ? [...tiers.default, ...tiers.liftoff] : tiers[opts.tiers];
if (!configs) throw new Error(`--tiers is default, liftoff or both (got ${opts.tiers})`);

const files = { ...runtimeFiles(opts.runtime), "app.wasm": opts.wasm };
const server = http.createServer((req, res) => {
  const u = new URL(req.url, "http://x");
  if (u.pathname === "/") {
    res.writeHead(200, { "content-type": "text/html" });
    res.end('<!doctype html><html><head><meta charset="utf-8"><title>deep payload</title></head><body></body></html>');
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

let failures = 0;
const check = (name, got, want) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  if (!ok) failures += 1;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok ? "" : `: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`}`);
};

function install() {
  window.__mount = async () => {
    const { mountRocEngineApp } = await import("/runtime.mjs");
    const root = document.createElement("div");
    document.body.append(root);
    window.__root = root;
    window.__faults = [];
    window.__workerFaults = [];
    window.__rt = await mountRocEngineApp({
      wasmUrl: "/app.wasm",
      root,
      onFault: (f) => window.__faults.push(String(f?.message ?? f)),
      onWorkerFault: (f) => window.__workerFaults.push(String(f?.message ?? f)),
    });
    return true;
  };
  window.__levels = (n) => {
    const el = window.__root.querySelector('[aria-label="Levels"]');
    el.value = String(n);
    el.dispatchEvent(new Event("input", { bubbles: true }));
  };
  window.__click = (label) => [...window.__root.querySelectorAll("button")].find((b) => b.textContent === label).click();
  window.__text = (id) => window.__root.querySelector(`[data-testid=${id}]`)?.textContent ?? null;
  // The output `id` once it shows neither nothing nor its pending text.
  window.__settled = (id) =>
    new Promise((resolve, reject) => {
      const t = setTimeout(() => reject(new Error(`timed out waiting for ${id}`)), 30000);
      const tick = () => {
        const v = window.__text(id);
        if (v && !["sending", "asking", "growing", "echoing"].includes(v)) {
          clearTimeout(t);
          resolve(v);
        } else setTimeout(tick, 2);
      };
      tick();
    });
  window.__press = async (levels, label, id) => {
    window.__levels(levels);
    window.__click(label);
    return window.__settled(id);
  };
  // The finished jobs, in order: [task, prepared or reused, instance, outcome].
  window.__jobs = () =>
    window.__rt.monitor
      .snapshot()
      .recent.map((r) => [r.task.split("/").pop(), r.prepared, r.instance, r.outcome]);
  window.__health = () => ({ faults: window.__faults, workerFaults: window.__workerFaults, poisoned: !!window.__rt.poisoned, lost: window.__rt.monitor.snapshot().jobs.lost });
}

const healthy = { faults: [], workerFaults: [], poisoned: false, lost: 0 };

for (const [label, args] of configs) {
  const browser = await launch({ executablePath: opts.chrome, args });
  const open = async () => {
    const ctx = await browser.createBrowserContext();
    const page = await ctx.newPage();
    page.on("pageerror", (e) => console.log("pageerror", String(e)));
    await page.evaluateOnNewDocument(install);
    await page.goto(`${base}/`);
    await page.evaluate(() => window.__mount());
    return { page, ctx };
  };

  // At the bound, each worst shape makes the whole round trip.
  {
    const { page, ctx } = await open();
    const r = await page.evaluate(async () => ({
      nested: await window.__press(128, "Echo nested", "nested"),
      fat: await window.__press(128, "Echo fat", "fat"),
      sent: await window.__press(128, "Send", "sent"),
      asked: await window.__press(128, "Ask", "asked"),
      health: window.__health(),
    }));
    check(`${label}: the worst shapes and a chain at 128 levels cross both ways in a dedicated worker`, r, {
      nested: "128 levels",
      fat: "128 levels",
      sent: "128 levels",
      asked: "128 levels",
      health: healthy,
    });
    await ctx.close();
  }

  // An input past the bound starts no job; an answer past it is TooDeep and
  // the next job runs on the same worker.
  {
    const { page, ctx } = await open();
    const r = await page.evaluate(async () => {
      const refused = await window.__press(129, "Send", "sent");
      const jobsAfterRefusal = window.__jobs().length;
      const past = await window.__press(129, "Ask", "asked");
      const next = await window.__press(128, "Ask", "asked");
      return { refused, jobsAfterRefusal, past, next, jobs: window.__jobs(), health: window.__health() };
    });
    check(`${label}: an input past the bound starts no job; an answer past it is TooDeep and the next job runs on the same worker`, r, {
      refused: "too deep",
      jobsAfterRefusal: 0,
      past: "too deep",
      next: "128 levels",
      jobs: [
        ["make", null, 1, "done"],
        ["make", null, 1, "done"],
      ],
      health: healthy,
    });
    await ctx.close();
  }

  // A preparation's task answering past the bound keeps its state: the next
  // job reuses it on the same worker.
  {
    const { page, ctx } = await open();
    const r = await page.evaluate(async () => {
      const past = await window.__press(29, "Grow", "grown");
      const next = await window.__press(28, "Grow", "grown");
      return { past, next, jobs: window.__jobs(), health: window.__health() };
    });
    check(`${label}: a prepared task's answer past the bound is TooDeep, and the next job reuses the state`, r, {
      past: "too deep",
      next: "128 levels",
      jobs: [
        ["grow", "prepare", 1, "done"],
        ["grow", "reuse", 1, "done"],
      ],
      health: healthy,
    });
    await ctx.close();
  }
  await browser.close();
}

server.close();
console.log(failures === 0 ? "deep-payload-browser: passed" : `deep-payload-browser: ${failures} failed`);
process.exit(failures === 0 ? 0 : 1);
