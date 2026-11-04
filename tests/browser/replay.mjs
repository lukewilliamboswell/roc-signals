// replay.mjs --wasm APP.wasm --runtime runtime.mjs --steps STEPS.jsonl
//            [--chrome PATH] [--filter REGEX] [--out RESULTS.json] [--pending-phase3]
//
// The browser spec runner. It replays specs in real headless Chrome, one
// fresh browser context (fresh instance, fresh storage) per spec. The steps
// come from the one `.scm` parser (`test-support/Scm.roc`), emitted as JSON
// lines by `TARGET spec --emit-steps`; this file never reads `.scm`.
//
// User actions are real input: mouse clicks at the element's centre, typing
// (select all, Backspace, then one key event per character) and <select>
// choice. Assertions read the live DOM. Effects run in the runtime's manual
// mode when the spec's setup asks for `manual-effects`: `stub-http` stages an
// answer and `run-effect N` answers the N-th awaited request the app issued.
// History, title and storage assertions read the real browser state.
//
// Work assertions (`metric_step` in the step JSON) need engine counters that
// do not exist yet. They fail as unsupported, or with `--pending-phase3` are
// recorded and the spec reports `pending-phase3`. An unknown step fails.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { launch } from "./cdp.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));

function parseArgs(argv) {
  const o = { chrome: process.env.CHROME ?? "chrome", filter: null, out: null, pending: false };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    const val = () => {
      if (i + 1 >= argv.length) throw new Error(`${a} needs a value`);
      i += 1;
      return argv[i];
    };
    if (a === "--wasm") o.wasm = val();
    else if (a === "--runtime") o.runtime = val();
    else if (a === "--steps") o.steps = val();
    else if (a === "--chrome") o.chrome = val();
    else if (a === "--filter") o.filter = new RegExp(val());
    else if (a === "--out") o.out = val();
    else if (a === "--pending-phase3") o.pending = true;
    else throw new Error(`unknown option ${a}`);
  }
  for (const k of ["wasm", "runtime", "steps"]) if (!o[k]) throw new Error(`--${k} is required`);
  return o;
}

const opts = parseArgs(process.argv.slice(2));
const specs = fs
  .readFileSync(opts.steps, "utf8")
  .split("\n")
  .filter((l) => l.trim() !== "")
  .map((l) => JSON.parse(l));

const files = {
  "index.html": path.join(here, "index.html"),
  "locate.js": path.join(here, "locate.js"),
  "runtime.mjs": opts.runtime,
  "app.wasm": opts.wasm,
};
const types = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript", ".wasm": "application/wasm" };
// Files are served by basename under any path (apps mount under a base path,
// e.g. /roc-signals/examples-web/conduit/), and a directory as index.html.
const server = http.createServer((req, res) => {
  const u = new URL(req.url, "http://x");
  const f = u.pathname.endsWith("/") ? files["index.html"] : files[path.basename(u.pathname)];
  if (!f || !fs.existsSync(f)) {
    res.writeHead(u.pathname === "/favicon.ico" ? 204 : 404);
    res.end();
    return;
  }
  res.writeHead(200, { "content-type": types[path.extname(f)] ?? "application/octet-stream" });
  res.end(fs.readFileSync(f));
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const port = server.address().port;

const showLoc = (l) => (l.kind === "role" ? `(role ${l.role} :name ${JSON.stringify(l.name)})` : `(${l.kind} ${JSON.stringify(l.value)})`);

class Unsupported extends Error {}

// The element a locator names, as a handle-free description: its centre for
// clicks, or null. `__loc` (locate.js) implements the locator rules.
const find = (page, loc) => page.evaluate((loc) => !!window.__loc(loc), loc);
async function need(page, loc) {
  if (!(await find(page, loc))) throw new Error(`no element ${showLoc(loc)}`);
}
const onEl = (page, loc, fn, ...args) =>
  page.evaluate(
    `((loc, args) => { const e = window.__loc(loc); return (${fn})(e, ...args); })(${JSON.stringify(loc)}, ${JSON.stringify(args)})`,
  );

async function click(page, loc) {
  await need(page, loc);
  const box = await onEl(page, loc, (e) => {
    e.scrollIntoView({ block: "center", inline: "center" });
    const r = e.getBoundingClientRect();
    return { x: r.left + r.width / 2, y: r.top + r.height / 2, disabled: e.disabled === true };
  });
  // A browser delivers no click to a disabled control.
  if (box.disabled) return;
  await page.clickAt(box);
}

const stats = { typed: 0, typedFallback: 0, fallbacks: [] };

async function fill(page, loc, v) {
  await need(page, loc);
  await onEl(page, loc, (e) => e.focus());
  await page.key("a", { modifiers: 2, commands: ["selectAll"] });
  await page.key("Backspace");
  if (v !== "") await page.type(v);
  const got = await onEl(page, loc, (e) => (e ? e.value : null));
  if (got === v) {
    stats.typed += 1;
    return;
  }
  // The control was replaced or rewritten mid-typing: fall back to one value
  // assignment and input event, and count it.
  stats.typedFallback += 1;
  stats.fallbacks.push(`${JSON.stringify(v)} typed as ${JSON.stringify(got)} into ${showLoc(loc)}`);
  await need(page, loc);
  await onEl(
    page,
    loc,
    (e, v) => {
      e.value = v;
      e.dispatchEvent(new Event("input", { bubbles: true }));
    },
    v,
  );
}

const settle = (page) => page.evaluate(() => new Promise((r) => setTimeout(r, 0)));

function popstateAfter(page, action) {
  return page.evaluate(
    `new Promise((r) => { addEventListener("popstate", () => setTimeout(r, 0), { once: true }); ${action}; })`,
  );
}

// Same texts as the native runner (SpecRunner.encode_reject): the app shows them verbatim.
const rejectText = { network: "Network", "invalid-request": "InvalidRequest", "too-large": "TooLarge", unavailable: "Unavailable" };

async function step(page, s, state) {
  const loc = s.loc;
  switch (s.op) {
    case "click":
      return click(page, loc);
    case "fill":
      return fill(page, loc, s.text);
    case "check":
    case "uncheck": {
      await need(page, loc);
      const want = s.op === "check";
      if ((await onEl(page, loc, (e) => e.checked)) !== want) await click(page, loc);
      return;
    }
    case "select-option": {
      await need(page, loc);
      const ok = await onEl(
        page,
        loc,
        (e, v) => {
          if (![...e.options].some((o) => o.value === v)) return false;
          e.value = v;
          e.dispatchEvent(new Event("input", { bubbles: true }));
          e.dispatchEvent(new Event("change", { bubbles: true }));
          return true;
        },
        s.text,
      );
      if (!ok) throw new Error(`${showLoc(loc)} has no option ${JSON.stringify(s.text)}`);
      return;
    }
    case "expect-text": {
      await need(page, loc);
      const got = await onEl(page, loc, (e) => e.textContent);
      if (got !== s.text) throw new Error(`${showLoc(loc)} text ${JSON.stringify(got)}, expected ${JSON.stringify(s.text)}`);
      return;
    }
    case "expect-value": {
      await need(page, loc);
      const got = await onEl(page, loc, (e) => e.value);
      if (got !== s.text) throw new Error(`${showLoc(loc)} value ${JSON.stringify(got)}, expected ${JSON.stringify(s.text)}`);
      return;
    }
    case "expect-checked":
    case "expect-disabled": {
      await need(page, loc);
      const got = await onEl(page, loc, (e, op) => (op === "expect-checked" ? e.checked : e.disabled), s.op);
      if (got !== s.value) throw new Error(`${showLoc(loc)} ${s.op === "expect-checked" ? "checked" : "disabled"} ${got}, expected ${s.value}`);
      return;
    }
    case "expect-visible":
      return need(page, loc);
    case "expect-absent":
      if (await find(page, loc)) throw new Error(`${showLoc(loc)} is present`);
      return;
    case "expect-attr": {
      await need(page, loc);
      const got = await onEl(page, loc, (e, n) => window.__attr(e, n), s.name);
      if (got !== s.text) throw new Error(`${showLoc(loc)} ${s.name}=${JSON.stringify(got)}, expected ${JSON.stringify(s.text)}`);
      return;
    }
    case "expect-no-attr": {
      await need(page, loc);
      const got = await onEl(page, loc, (e, n) => window.__attr(e, n), s.name);
      if (got !== "") throw new Error(`${showLoc(loc)} has ${s.name}=${JSON.stringify(got)}`);
      return;
    }
    case "stub-http":
      state.stub = { url: s.url, status: s.status, body: s.body, headers: s.headers.length ? s.headers : [["content-type", "application/json"]] };
      return;
    case "stub-http-reject":
      state.stub = s.kind === "timeout" ? { timeout: true } : { network: `${rejectText[s.kind]}(${JSON.stringify(s.detail)})` };
      return;
    case "run-effect": {
      if (state.stub === null) throw new Error(`run-effect ${s.count} without a staged answer`);
      const answer = state.stub;
      state.stub = null;
      const r = await page.evaluate(
        (n, answer) => {
          const rt = window.__rt;
          const id = rt.issued[n - 1];
          if (id === undefined) return `effect occurrence ${n} was never issued (${rt.issued.length} issued)`;
          const e = rt.live.get(id);
          if (e === undefined) return `effect occurrence ${n} is not pending (cancelled or done)`;
          if (answer.url !== undefined && e.req.url !== answer.url) return `no spec stub for ${e.req.url} (stub is for ${answer.url})`;
          rt.runEffect(id, answer);
          return null;
        },
        s.count,
        answer,
      );
      if (r) throw new Error(r);
      return settle(page);
    }
    case "expect-pending-effects": {
      const got = await page.evaluate(() => window.__rt.pendingEffects().map((r) => r.url ?? r.id));
      if (got.length !== s.count) throw new Error(`expected ${s.count} pending effects, got ${got.length} ${JSON.stringify(got)}`);
      return;
    }
    case "expect-current-location": {
      const got = await page.evaluate(() => location.pathname + location.search + location.hash);
      if (got !== s.text) throw new Error(`location ${JSON.stringify(got)}, expected ${JSON.stringify(s.text)}`);
      return;
    }
    case "expect-document-title": {
      const got = await page.title();
      if (got !== s.text) throw new Error(`title ${JSON.stringify(got)}, expected ${JSON.stringify(s.text)}`);
      return;
    }
    case "expect-local-storage": {
      const got = await page.evaluate((k) => localStorage.getItem(k), s.key);
      if (got !== s.text) throw new Error(`local storage ${s.key} = ${JSON.stringify(got)}, expected ${JSON.stringify(s.text)}`);
      return;
    }
    case "expect-no-local-storage": {
      const got = await page.evaluate((k) => localStorage.getItem(k), s.key);
      if (got !== null) throw new Error(`local storage ${s.key} is present`);
      return;
    }
    case "history-back":
      return popstateAfter(page, "history.back()");
    case "history-forward":
      return popstateAfter(page, "history.forward()");
    case "navigate":
      if (!s.text.includes("#")) {
        // Leaving the hash entirely is a cross-document navigation: the page
        // reloads and the app mounts fresh at that URL.
        await page.evaluate((url) => location.assign(url), s.text);
        await page.waitForFunction("window.__ready || window.__error");
        return;
      }
      // A user navigation within the document: a new history entry and a
      // popstate the app's subscription receives.
      return popstateAfter(page, `location.assign(${JSON.stringify(s.text)})`);
    default:
      throw new Unsupported(`${s.op}: unsupported in this runner yet`);
  }
}

function setupOf(spec) {
  const out = { location: "/index.html", storage: [], manual: false };
  for (const s of spec.setup) {
    if (s.op === "initial-location") out.location = s.text;
    else if (s.op === "local-storage") out.storage.push([s.key, s.text]);
    else if (s.op === "manual-effects") out.manual = true;
    else throw new Unsupported(`setup ${s.op}: unsupported in this runner yet`);
  }
  return out;
}

const browser = await launch({ executablePath: opts.chrome });
const results = [];
for (const spec of specs) {
  if (opts.filter && !opts.filter.test(spec.id)) continue;
  const page = await browser.newPage();
  const t0 = Date.now();
  const pending = [];
  let failed = null;
  let i = 0;
  try {
    const setup = setupOf(spec);
    await page.evaluateOnNewDocument(fs.readFileSync(files["locate.js"], "utf8"));
    await page.evaluateOnNewDocument(
      (storage, manual) => {
        if (!sessionStorage.getItem("__seeded")) {
          for (const [k, v] of storage) localStorage.setItem(k, v);
          sessionStorage.setItem("__seeded", "1");
        }
        if (manual) window.__manualFx = true;
      },
      setup.storage,
      setup.manual,
    );
    await page.goto(`http://127.0.0.1:${port}${setup.location}`);
    await page.waitForFunction("window.__ready || window.__error");
    const err = await page.evaluate(() => window.__error ?? null);
    if (err) throw new Error(`mount failed: ${err}`);
    const state = { stub: null };
    for (; i < spec.steps.length; i += 1) {
      const s = spec.steps[i];
      if (s.metric_step) {
        if (!opts.pending) throw new Unsupported(`${s.op}: unsupported in this engine yet (work counters, intervals and cleanups land in Phase 3)`);
        pending.push({ op: s.op, line: s.line });
        continue;
      }
      await step(page, s, state);
      if (page.errors.length) throw new Error(`page error: ${page.errors.join("; ")}`);
    }
  } catch (e) {
    const wasmErr = await page
      .evaluate(() => {
        const x = window.__rt && window.__rt.x;
        if (!x) return "";
        return new TextDecoder().decode(new Uint8Array(x.memory.buffer, x.err_ptr(), x.err_len()));
      })
      .catch(() => "");
    const s = spec.steps[i];
    failed = {
      kind: e instanceof Unsupported ? "unsupported" : "assertion",
      message: `${spec.id}:${s ? `${s.line}:${s.column}: ${s.op}: ` : " "}${e.message}${wasmErr ? ` [roc: ${wasmErr}]` : ""}`,
      step: i,
    };
  }
  const status = failed ? "failed" : pending.length ? "pending-phase3" : "passed";
  results.push({ id: spec.id, name: spec.name, status, ms: Date.now() - t0, failure: failed, pending_steps: pending });
  console.log(`${status.toUpperCase().padEnd(14)} ${spec.id} (${spec.steps.length} steps, ${Date.now() - t0} ms)${failed ? `\n     ${failed.message}` : ""}`);
  await page.close();
}
await browser.close();
server.close();
const count = (st) => results.filter((r) => r.status === st).length;
const pendingSteps = results.reduce((n, r) => n + r.pending_steps.length, 0);
console.log(
  `== ${count("passed")} passed, ${count("failed")} failed, ${count("pending-phase3")} pending-phase3 (${pendingSteps} work steps pending); fills typed=${stats.typed} fallback=${stats.typedFallback}`,
);
for (const f of stats.fallbacks) console.log(`   fallback: ${f}`);
if (opts.out) fs.writeFileSync(opts.out, JSON.stringify({ results, stats }, null, 1));
process.exit(count("failed") === 0 && results.length > 0 ? 0 : 1);
