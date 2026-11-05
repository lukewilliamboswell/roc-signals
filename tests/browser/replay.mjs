// replay.mjs --wasm APP.wasm --runtime runtime.mjs --steps STEPS.jsonl
//            [--chrome PATH] [--filter REGEX] [--out RESULTS.json] [--json-lines]
//
// The browser spec runner. It replays specs in real headless Chrome, one
// fresh browser context (fresh instance, fresh storage) per spec. The steps
// come from the one `.scm` parser (`test-support/Scm.roc`), emitted as JSON
// lines by `TARGET spec --emit-steps`; this file never reads `.scm`.
//
// User actions are real input: mouse clicks at the element's centre, fills
// (focus, select all, then one `insertText` input event, as Playwright's
// `fill` does) and <select> choice. Assertions read the live DOM. Effects run in the runtime's manual
// mode when the spec's setup asks for `manual-effects`: `stub-http` stages an
// answer and `run-effect N` answers the N-th awaited request the app issued.
// History, title and storage assertions read the real browser state.
// `local-storage-unavailable` makes `window.localStorage` throw, as a browser
// with site data disabled does; storage assertions then read the real store
// underneath, so they confirm nothing was written.
//
// Intervals tick only through `tick-interval` (the runtime's manual
// intervals), and connectivity and visibility change only through
// `set-online` and `set-visibility`, which override `navigator.onLine` and
// `document.visibilityState` and dispatch the browser's own events.
//
// Work assertions read the engine's work counters through the `metric` export
// (each metric step names the counters it sums; the parser emits them), the
// cleanup runs through the work record, and `expect-updates` counts the DOM
// mutations a MutationObserver saw: an element's creation plus every later
// attribute or text write on it or a text node directly inside it. An
// unknown step fails.
//
// Progress goes to stderr. With `--json-lines`, stdout carries one result
// line per spec in the native runner's `roc-signals/spec-result/v2` shape.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { launch } from "./cdp.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));

function parseArgs(argv) {
  const o = { chrome: process.env.CHROME ?? "chrome", filter: null, out: null, jsonLines: false };
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
    else if (a === "--json-lines") o.jsonLines = true;
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

async function click(page, loc, real = false) {
  await need(page, loc);
  const box = await onEl(page, loc, (e) => {
    e.scrollIntoView({ block: "center", inline: "center" });
    const r = e.getBoundingClientRect();
    return { x: r.left + r.width / 2, y: r.top + r.height / 2, disabled: e.disabled === true };
  });
  // A browser delivers no click to a disabled control; a real click on one
  // is a failed step.
  if (box.disabled) {
    if (real) throw new Error(`${showLoc(loc)} is disabled`);
    return;
  }
  await page.clickAt(box);
}

// Sum of the engine work counters `ks` (metric(16 + k)).
const counters = (page) => page.evaluate(() => window.__rt.workRecord().counters.map((c) => c.toString()));
const sumOf = (cs, ks) => ks.reduce((n, k) => n + BigInt(cs[k] ?? "0"), 0n);

const stats = { typed: 0, typedFallback: 0, fallbacks: [] };

// `fill` as Playwright defines it: focus the control, select its contents
// and replace them with the value in one real input event (`insertText`; a
// Backspace when the value is empty), so the app sees one `input` with the
// whole value, exactly as the native runner delivers it.
async function fill(page, loc, v) {
  await need(page, loc);
  await onEl(page, loc, (e) => {
    e.focus();
    if (typeof e.select === "function") e.select();
  });
  if (v === "") await page.key("Backspace");
  else await page.insertText(v);
  const got = await onEl(page, loc, (e) => (e ? e.value : null));
  if (got === v) {
    stats.typed += 1;
    return;
  }
  // The control cannot hold the value (an <input type=number> refuses
  // "abc") or was replaced mid-edit: fall back to one value assignment and
  // input event, and count it.
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
      // As the native runner (SpecRunner.encode_reject): a timeout, or a
      // network failure whose message is the detail.
      state.stub = s.kind === "timeout" ? { timeout: true } : { network: s.detail };
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
    case "real-click":
      return click(page, loc, true);
    case "focus":
      await need(page, loc);
      await onEl(page, loc, (e) => e.focus());
      return settle(page);
    case "blur":
      await need(page, loc);
      await onEl(page, loc, (e) => e.blur());
      return settle(page);
    case "change": {
      await need(page, loc);
      const r = await onEl(
        page,
        loc,
        (e, v) => {
          if (e.type === "radio" || e.type === "checkbox") {
            if (e.value !== v) return `has value ${JSON.stringify(e.value)}, not ${JSON.stringify(v)}`;
            e.checked = true;
          } else e.value = v;
          e.dispatchEvent(new Event("change", { bubbles: true }));
          return null;
        },
        s.text,
      );
      if (r) throw new Error(`${showLoc(loc)} ${r}`);
      return settle(page);
    }
    case "submit": {
      await need(page, loc);
      const r = await onEl(page, loc, (e) => {
        if (e.tagName !== "FORM") return "is not a <form>";
        e.requestSubmit();
        return null;
      });
      if (r) throw new Error(`${showLoc(loc)} ${r}`);
      return settle(page);
    }
    case "set-online":
      await page.evaluate((on) => {
        Object.defineProperty(navigator, "onLine", { get: () => on, configurable: true });
        window.dispatchEvent(new Event(on ? "online" : "offline"));
      }, s.text === "online");
      return settle(page);
    case "set-visibility":
      await page.evaluate((vis) => {
        Object.defineProperty(document, "visibilityState", { get: () => vis, configurable: true });
        Object.defineProperty(document, "hidden", { get: () => vis === "hidden", configurable: true });
        document.dispatchEvent(new Event("visibilitychange"));
      }, s.text);
      return settle(page);
    case "tick-interval":
    case "tick-interval-if-active": {
      const n = await page.evaluate((ms) => {
        const ids = window.__rt.intervals(ms);
        for (const id of ids) window.__rt.tick(id);
        return ids.length;
      }, s.period_ms);
      if (n === 0 && s.op === "tick-interval") throw new Error(`no live interval with period ${s.period_ms} ms`);
      return settle(page);
    }
    case "expect-interval": {
      const n = await page.evaluate((ms) => window.__rt.intervals(ms).length, s.period_ms);
      if (n !== s.count) throw new Error(`${n} live intervals with period ${s.period_ms} ms, expected ${s.count}`);
      return;
    }
    case "expect-cleanup": {
      const n = await page.evaluate((name) => (window.__rt.workRecord().cleanups.get(name) ?? 0n).toString(), s.name);
      if (BigInt(n) !== BigInt(s.count)) throw new Error(`cleanup ${JSON.stringify(s.name)} ran ${n} times, expected ${s.count}`);
      return;
    }
    case "expect-updates": {
      await need(page, loc);
      const n = await onEl(page, loc, (e) => {
        window.__mo.flush();
        return 1 + (e.__w ?? 0);
      });
      if (n !== s.count) throw new Error(`${showLoc(loc)} was written ${n} times (its creation and every later update), expected ${s.count}`);
      return;
    }
    case "mark-metrics":
      state.mark = await counters(page);
      return;
    case "expect-metric-delta":
    case "expect-metric-delta-at-most": {
      if (state.mark === null) throw new Error("no mark-metrics before this step");
      const now = await counters(page);
      const got = sumOf(now, s.counters) - sumOf(state.mark, s.counters);
      const want = BigInt(s.delta);
      if (s.op === "expect-metric-delta" ? got !== want : got > want) {
        throw new Error(`${s.metric} changed by ${got}, expected ${s.op === "expect-metric-delta" ? "" : "at most "}${want}`);
      }
      return;
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
      const got = await page.evaluate((k) => (window.__localStorage ?? localStorage).getItem(k), s.key);
      if (got !== s.text) throw new Error(`local storage ${s.key} = ${JSON.stringify(got)}, expected ${JSON.stringify(s.text)}`);
      return;
    }
    case "expect-no-local-storage": {
      const got = await page.evaluate((k) => (window.__localStorage ?? localStorage).getItem(k), s.key);
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
  const out = { location: "/index.html", storage: [], storageAvailable: true, manual: false, online: true, visibility: "visible" };
  for (const s of spec.setup) {
    if (s.op === "initial-location") out.location = s.text;
    else if (s.op === "local-storage") out.storage.push([s.key, s.text]);
    else if (s.op === "local-storage-unavailable") out.storageAvailable = false;
    else if (s.op === "manual-effects") out.manual = true;
    else if (s.op === "initial-online") out.online = s.text === "online";
    else if (s.op === "initial-visibility") out.visibility = s.text;
    else throw new Unsupported(`setup ${s.op}: unsupported in this runner yet`);
  }
  if (!out.storageAvailable && out.storage.length) throw new Error("local-storage seeds storage that local-storage-unavailable says the app cannot read");
  return out;
}

// The page-side half of `expect-updates`: count, per node, the attribute and
// text mutations after the callback that inserted it. Installed before the
// app mounts.
function observeWrites() {
  let cb = 0;
  const born = (n) => {
    n.__born = cb;
    for (let c = n.firstChild; c; c = c.nextSibling) born(c);
  };
  const take = (records) => {
    cb += 1;
    for (const r of records) if (r.type === "childList") for (const n of r.addedNodes) born(n);
    for (const r of records) {
      if (r.type === "childList") continue;
      const t = r.target;
      if (t.__born === cb) continue;
      t.__w = (t.__w ?? 0) + 1;
      if (r.type === "characterData" && t.parentNode && t.parentNode.__born !== cb) t.parentNode.__w = (t.parentNode.__w ?? 0) + 1;
    }
  };
  const mo = new MutationObserver(take);
  window.__mo = { flush: () => take(mo.takeRecords()) };
  document.addEventListener("DOMContentLoaded", () => {
    mo.observe(document.getElementById("app"), { subtree: true, childList: true, attributes: true, characterData: true });
  });
}

const browser = await launch({ executablePath: opts.chrome });
const results = [];
for (const spec of specs) {
  if (opts.filter && !opts.filter.test(spec.id)) continue;
  if (spec.status === "error") {
    // The parser refused the spec (the native runner's error line): it fails
    // here too, with the parser's message.
    results.push({ id: spec.id, name: spec.name, status: "failed", ms: 0, failure: spec.failure });
    console.error(`FAILED         ${spec.id}\n     ${spec.failure.message}`);
    if (opts.jsonLines) process.stdout.write(`${JSON.stringify({ ...spec, status: "failed" })}\n`);
    continue;
  }
  const page = await browser.newPage();
  const t0 = Date.now();
  let failed = null;
  let i = 0;
  try {
    const setup = setupOf(spec);
    await page.evaluateOnNewDocument(fs.readFileSync(files["locate.js"], "utf8"));
    await page.evaluateOnNewDocument(
      (storage, storageAvailable, manual, online, visibility) => {
        if (!sessionStorage.getItem("__seeded")) {
          for (const [k, v] of storage) localStorage.setItem(k, v);
          sessionStorage.setItem("__seeded", "1");
        }
        if (!storageAvailable) {
          window.__localStorage = localStorage;
          Object.defineProperty(window, "localStorage", {
            get: () => {
              throw new DOMException("The operation is insecure.", "SecurityError");
            },
            configurable: true,
          });
        }
        if (manual) window.__manualFx = true;
        if (!online) Object.defineProperty(navigator, "onLine", { get: () => false, configurable: true });
        if (visibility !== "visible") {
          Object.defineProperty(document, "visibilityState", { get: () => visibility, configurable: true });
          Object.defineProperty(document, "hidden", { get: () => true, configurable: true });
        }
      },
      setup.storage,
      setup.storageAvailable,
      setup.manual,
      setup.online,
      setup.visibility,
    );
    await page.evaluateOnNewDocument(observeWrites);
    await page.goto(`http://127.0.0.1:${port}${setup.location}`);
    await page.waitForFunction("window.__ready || window.__error");
    const err = await page.evaluate(() => window.__error ?? null);
    if (err) throw new Error(`mount failed: ${err}`);
    const state = { stub: null, mark: null };
    for (; i < spec.steps.length; i += 1) {
      const s = spec.steps[i];
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
  const status = failed ? "failed" : "passed";
  const ms = Date.now() - t0;
  results.push({ id: spec.id, name: spec.name, status, ms, failure: failed });
  console.error(`${status.toUpperCase().padEnd(14)} ${spec.id} (${spec.steps.length} steps, ${ms} ms)${failed ? `\n     ${failed.message}` : ""}`);
  if (opts.jsonLines) {
    const failure = failed && { phase: "step", ...failed };
    const line = { protocol: "roc-signals/spec-result/v2", id: spec.id, name: spec.name, status, duration_ns: ms * 1e6, failure };
    process.stdout.write(`${JSON.stringify(line)}\n`);
  }
  await page.close();
}
await browser.close();
server.close();
const count = (st) => results.filter((r) => r.status === st).length;
console.error(`== ${count("passed")} passed, ${count("failed")} failed; fills typed=${stats.typed} fallback=${stats.typedFallback}`);
for (const f of stats.fallbacks) console.error(`   fallback: ${f}`);
if (opts.out) fs.writeFileSync(opts.out, JSON.stringify({ results, stats }, null, 1));
process.exit(count("failed") === 0 && results.length > 0 ? 0 : 1);
