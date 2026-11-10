// replay.mjs --wasm APP.wasm --runtime runtime.mjs --steps STEPS.jsonl
//            [--chrome PATH] [--filter REGEX] [--out RESULTS.json] [--json-lines]
// replay.mjs --check-grammar GRAMMAR.json
//
// The browser spec runner. It replays specs in real headless Chrome, one
// fresh browser context (fresh instance, fresh storage) per spec. The steps
// come from the one `.scm` parser (`platform/Scm.roc`), emitted as JSON
// lines by the app's native runner (`RUNNER --emit-steps`); this file never reads `.scm`.
//
// Every step and setup form of the grammar has exactly one handler in the
// STEPS and SETUP tables below. `--check-grammar` compares those tables with
// the grammar the parser prints (`RUNNER --grammar`) and fails on any
// difference, so a form the parser accepts can never reach this runner
// without a handler. The native runner (`platform/SpecRunner.roc`)
// implements the same semantics against the `Dom.roc` oracle; the browser is
// the reference for what each step means (design.md, "The `.scm` spec
// language").
//
// User actions are real input: mouse clicks at the element's centre, with
// every default action the browser takes; fills as Playwright's `fill` (focus,
// select all, one `insertText` input event, refused for a value the control
// cannot hold); <select> choice with `input` and `change`. Assertions read the
// live DOM. Effects are always manual: `stub-http` stages one answer and
// `run-effect N` answers the N-th awaited HTTP request, timer or worker job
// the current document issued (a job really runs in a worker, and the step
// waits for its result turn); storage reads answer by themselves from storage. History,
// title and storage assertions read the real browser state.
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
// attribute or text write on it or a text node directly inside it.
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
  const o = { chrome: process.env.CHROME ?? "chrome", filter: null, out: null, jsonLines: false, grammar: null };
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
    else if (a === "--check-grammar") o.grammar = val();
    else throw new Error(`unknown option ${a}`);
  }
  if (o.grammar === null) for (const k of ["wasm", "runtime", "steps"]) if (!o[k]) throw new Error(`--${k} is required`);
  return o;
}

const showLoc = (l) => (l.kind === "role" ? `(role ${l.role} :name ${JSON.stringify(l.name)})` : `(${l.kind} ${JSON.stringify(l.value)})`);

// The element a locator names. `__loc` (locate.js) implements the locator
// rules; a `text` locator names the element holding the text node.
const find = (page, loc) => page.evaluate((loc) => !!window.__loc(loc), loc);
async function need(page, loc) {
  if (!(await find(page, loc))) throw new Error(`no element ${showLoc(loc)}`);
}
const onEl = (page, loc, fn, ...args) =>
  page.evaluate(
    `((loc, args) => { const e = window.__loc(loc); return (${fn})(e, ...args); })(${JSON.stringify(loc)}, ${JSON.stringify(args)})`,
  );

// Let queued work run: the runtime delivers storage reads and queued events
// on a timer of 0 ms.
const settle = (page) => page.evaluate(() => new Promise((r) => setTimeout(r, 0)));

// The current document's token, set before any script runs (see `install`):
// a cross-document navigation replaces it.
const docToken = (page) => page.evaluate(() => window.__doc).catch(() => null);

// Wait for the app of a new document to mount.
async function mounted(page) {
  await page.waitForFunction("window.__ready || window.__error");
  const err = await page.evaluate(() => window.__error ?? null);
  if (err) throw new Error(`mount failed: ${err}`);
}

// Run `act`, which may start a navigation, then wait for its outcome: a
// same-document navigation's popstate has already run; a cross-document one
// mounts the app afresh at the new URL. `__nav` (see `install`) records the
// navigation a click's default action starts, before it commits.
async function navigating(page, state, act, known = undefined) {
  const before = state.doc;
  const loads = state.loads;
  await act();
  const nav = known ?? await page
    .evaluate(() => {
      const n = window.__nav ?? null;
      window.__nav = null;
      return n;
    })
    .catch(() => ({ cross: true, href: "?" }));
  if (nav && nav.cross) {
    if (nav.external) throw new Error(`the click navigates to ${nav.href}, which leaves the app`);
    const t0 = Date.now();
    while (state.loads === loads) {
      if (Date.now() - t0 > 20000) throw new Error(`timed out waiting for the navigation to ${nav.href}`);
      await new Promise((r) => setTimeout(r, 10));
    }
    await mounted(page);
    state.doc = await docToken(page);
    if (state.doc === before) throw new Error("expected a new document after the navigation");
    state.stub = null;
  }
  return settle(page);
}

// A real mouse click at the element's centre, with the browser's default
// actions (a checkbox toggles, a radio checks, a submit button submits its
// form, a link navigates). A browser delivers no click to a disabled
// control: `click` then does nothing, and `real-click` fails.
async function click(page, state, loc, real) {
  await need(page, loc);
  const box = await onEl(page, loc, (e) => {
    e.scrollIntoView({ block: "center", inline: "center" });
    const r = e.getBoundingClientRect();
    return { x: r.left + r.width / 2, y: r.top + r.height / 2, disabled: e.disabled === true };
  });
  if (box.disabled) {
    if (real) throw new Error(`${showLoc(loc)} is disabled`);
    return;
  }
  await navigating(page, state, () => page.clickAt(box));
}

// Sum of the engine work counters `ks` (metric(16 + k)).
const counters = (page) => page.evaluate(() => window.__rt.workRecord().counters.map((c) => c.toString()));
const sumOf = (cs, ks) => ks.reduce((n, k) => n + BigInt(cs[k] ?? "0"), 0n);

// The input types `fill` can type into, as Playwright's `fill` allows.
const FILLABLE = ["", "text", "password", "email", "search", "tel", "url", "number"];

// `fill` as Playwright defines it: the control must be an enabled text
// input or textarea that can hold the value (an <input type=number> holds
// only a valid floating-point number or ""); focus it, select its contents
// and replace them with one real input event (`insertText`; a delete when
// the value is empty and the control is not), so the app sees one `input`
// with the whole value, exactly as the native runner delivers it.
async function fill(page, loc, v) {
  await need(page, loc);
  const r = await onEl(
    page,
    loc,
    (e, v, fillable) => {
      const tag = e.tagName.toLowerCase();
      const type = tag === "input" ? (e.getAttribute("type") ?? "").toLowerCase() : "";
      if (!(tag === "textarea" || (tag === "input" && fillable.includes(type)))) return { error: "cannot be filled" };
      if (e.disabled) return { error: "is disabled" };
      if (type === "number" && v !== "" && !/^-?(\d+(\.\d+)?|\.\d+)([eE][-+]?\d+)?$/.test(v)) return { error: `cannot hold ${JSON.stringify(v)}` };
      e.focus();
      if (typeof e.select === "function") e.select();
      return { empty: e.value === "" };
    },
    v,
    FILLABLE,
  );
  if (r.error) throw new Error(`${showLoc(loc)} ${r.error}`);
  if (v === "") {
    if (!r.empty) await page.evaluate(() => document.execCommand("delete"));
  } else await page.insertText(v);
  const got = await onEl(page, loc, (e) => e.value);
  if (got !== v) throw new Error(`${showLoc(loc)} holds ${JSON.stringify(got)} after filling ${JSON.stringify(v)}`);
  return settle(page);
}

function popstateAfter(page, action) {
  return page.evaluate(
    `new Promise((r) => { addEventListener("popstate", () => setTimeout(r, 0), { once: true }); ${action}; })`,
  );
}

// `check`/`uncheck`: a click on a checkbox or radio that is not in the wanted
// state, which must then be in it.
async function setChecked(page, state, loc, want) {
  await need(page, loc);
  const kind = await onEl(page, loc, (e) => (e.tagName === "INPUT" ? (e.getAttribute("type") ?? "").toLowerCase() : ""));
  if (kind !== "checkbox" && kind !== "radio") throw new Error(`${showLoc(loc)} is not a checkbox or radio button`);
  if (kind === "radio" && !want) throw new Error(`${showLoc(loc)} is a radio button, which cannot be unchecked`);
  if ((await onEl(page, loc, (e) => e.checked)) === want) return;
  await click(page, state, loc, false);
  if ((await onEl(page, loc, (e) => e.checked)) !== want) throw new Error(`clicking ${showLoc(loc)} did not ${want ? "check" : "uncheck"} it`);
}

// The value an assertion reads for an attribute: `checked` and `disabled`
// as "true"/"false" from the live properties, `value` as the live value,
// anything else as the attribute the element holds (null when absent).
const attrOf = (e, n) => {
  if (n === "checked") return e.checked ? "true" : "false";
  if (n === "disabled") return e.disabled ? "true" : "false";
  if (n === "value") return e.value;
  return e.getAttribute(n);
};

async function expectText(page, loc, want) {
  await need(page, loc);
  const got = await onEl(page, loc, (e) => e.textContent);
  if (got !== want) throw new Error(`${showLoc(loc)} text ${JSON.stringify(got)}, expected ${JSON.stringify(want)}`);
}

async function expectProp(page, s, what) {
  await need(page, s.loc);
  const got = await onEl(page, s.loc, (e, w) => (w === "checked" ? e.checked : e.disabled), what);
  if (got !== s.value) throw new Error(`${showLoc(s.loc)} ${what} ${got}, expected ${s.value}`);
}

async function stage(state, answer) {
  if (state.stub !== null) throw new Error("a stub is already staged; run-effect answers one at a time");
  state.stub = answer;
}

async function tick(page, s) {
  const n = await page.evaluate((ms) => {
    const ids = window.__rt.intervals(ms);
    for (const id of ids) window.__rt.tick(id);
    return ids.length;
  }, s.period_ms);
  if (n === 0 && s.op === "tick-interval") throw new Error(`no live interval with period ${s.period_ms} ms`);
  return settle(page);
}

async function metricDelta(page, state, s, atMost) {
  if (state.mark === null) throw new Error("no mark-metrics before this step");
  const now = await counters(page);
  const got = sumOf(now, s.counters) - sumOf(state.mark, s.counters);
  const want = BigInt(s.delta);
  if (atMost ? got > want : got !== want) {
    throw new Error(`${s.metric} changed by ${got}, expected ${atMost ? "at most " : ""}${want}`);
  }
}

async function storageItem(page, key) {
  return page.evaluate((k) => (window.__localStorage ?? localStorage).getItem(k), key);
}

// Move through history by `delta`: within the document, the popstate the
// app's subscription receives; across documents, a step this runner refuses
// (a traversal may restore a cached page instead of mounting afresh).
async function traverse(page, delta, what) {
  const target = await page.evaluate((d) => {
    const at = navigation.currentEntry.index + d;
    const e = navigation.entries()[at];
    return e === undefined ? null : { same: e.sameDocument };
  }, delta);
  if (target === null) throw new Error(`${what} with no ${delta < 0 ? "history" : "forward entry"}`);
  if (!target.same) throw new Error(`${what} crosses documents, which specs do not model`);
  return popstateAfter(page, delta < 0 ? "history.back()" : "history.forward()");
}

// The same-document rule of the HTML standard: a navigation to a URL that
// has a fragment and differs from the current one only in the fragment.
const sameDocument = (from, to) => to.includes("#") && from.split("#")[0] === to.split("#")[0];

// One handler per step form of the grammar (`Scm.step_forms`).
const STEPS = {
  click: (page, s, state) => click(page, state, s.loc, false),
  "real-click": (page, s, state) => click(page, state, s.loc, true),
  fill: (page, s) => fill(page, s.loc, s.text),
  check: (page, s, state) => setChecked(page, state, s.loc, true),
  uncheck: (page, s, state) => setChecked(page, state, s.loc, false),
  "select-option": async (page, s) => {
    await need(page, s.loc);
    const r = await onEl(
      page,
      s.loc,
      (e, v) => {
        if (e.tagName !== "SELECT") return "is not a <select>";
        if (![...e.options].some((o) => o.value === v)) return `has no option ${JSON.stringify(v)}`;
        e.value = v;
        e.dispatchEvent(new Event("input", { bubbles: true }));
        e.dispatchEvent(new Event("change", { bubbles: true }));
        return null;
      },
      s.text,
    );
    if (r) throw new Error(`${showLoc(s.loc)} ${r}`);
    return settle(page);
  },
  focus: async (page, s) => {
    await need(page, s.loc);
    await onEl(page, s.loc, (e) => e.focus());
    return settle(page);
  },
  blur: async (page, s) => {
    await need(page, s.loc);
    await onEl(page, s.loc, (e) => e.blur());
    return settle(page);
  },
  change: async (page, s) => {
    await need(page, s.loc);
    const r = await onEl(
      page,
      s.loc,
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
    if (r) throw new Error(`${showLoc(s.loc)} ${r}`);
    return settle(page);
  },
  submit: async (page, s) => {
    await need(page, s.loc);
    const r = await onEl(page, s.loc, (e) => {
      if (e.tagName !== "FORM") return "is not a <form>";
      e.requestSubmit();
      return null;
    });
    if (r) throw new Error(`${showLoc(s.loc)} ${r}`);
    return settle(page);
  },
  "expect-text": (page, s) => expectText(page, s.loc, s.text),
  "expect-value": async (page, s) => {
    await need(page, s.loc);
    const got = await onEl(page, s.loc, (e) => e.value);
    if (got !== s.text) throw new Error(`${showLoc(s.loc)} value ${JSON.stringify(got)}, expected ${JSON.stringify(s.text)}`);
  },
  "expect-checked": (page, s) => expectProp(page, s, "checked"),
  "expect-disabled": (page, s) => expectProp(page, s, "disabled"),
  "expect-visible": (page, s) => need(page, s.loc),
  "expect-absent": async (page, s) => {
    if (await find(page, s.loc)) throw new Error(`${showLoc(s.loc)} is present`);
  },
  "expect-attr": async (page, s) => {
    await need(page, s.loc);
    const got = await onEl(page, s.loc, (e, n) => window.__attrOf(e, n), s.name);
    if (got === null) throw new Error(`${showLoc(s.loc)} has no ${s.name} attribute, expected ${JSON.stringify(s.text)}`);
    if (got !== s.text) throw new Error(`${showLoc(s.loc)} ${s.name}=${JSON.stringify(got)}, expected ${JSON.stringify(s.text)}`);
  },
  "expect-no-attr": async (page, s) => {
    await need(page, s.loc);
    const got = await onEl(page, s.loc, (e, n) => e.getAttribute(n), s.name);
    if (got !== null) throw new Error(`${showLoc(s.loc)} has ${s.name}=${JSON.stringify(got)}`);
  },
  "expect-updates": async (page, s) => {
    await need(page, s.loc);
    const n = await onEl(page, s.loc, (e) => {
      window.__mo.flush();
      return 1 + (e.__w ?? 0);
    });
    if (n !== s.count) throw new Error(`${showLoc(s.loc)} was written ${n} times (its creation and every later update), expected ${s.count}`);
  },
  "stub-http": (page, s, state) => stage(state, { url: s.url, status: s.status, body: s.body, headers: s.headers.length ? s.headers : [["content-type", "application/json"]] }),
  // As the native runner (SpecRunner.encode_reject): a timeout, or a network
  // failure whose message is the detail.
  "stub-http-reject": (page, s, state) => stage(state, s.kind === "timeout" ? { timeout: true } : { network: s.detail }),
  "run-effect": async (page, s, state) => {
    const r = await page.evaluate(
      (n, answer) => {
        const rt = window.__rt;
        const id = rt.issued[n - 1];
        if (id === undefined) return { error: `effect occurrence ${n} was never issued (${rt.issued.length} issued)` };
        const e = rt.live.get(id);
        if (e === undefined) return { error: `effect occurrence ${n} is not pending (cancelled or done)` };
        // A timer fires; it takes no staged answer.
        if (e.kind === "timer") {
          rt.runEffect(id, {});
          return { used: false };
        }
        // A worker job really runs in a worker; the step waits for its
        // result turn.
        if (e.kind === "work") return Promise.resolve(rt.runEffect(id)).then(() => ({ used: false }));
        if (answer === null) return { error: `run-effect ${n} answers ${e.req.url} without a staged stub` };
        if (answer.url !== undefined && e.req.url !== answer.url) return { error: `no spec stub for ${e.req.url} (stub is for ${answer.url})` };
        rt.runEffect(id, answer);
        return { used: true };
      },
      s.count,
      state.stub,
    );
    if (r.error) throw new Error(r.error);
    if (r.used) state.stub = null;
    return settle(page);
  },
  "expect-pending-effects": async (page, s) => {
    const got = await page.evaluate(() => window.__rt.pendingEffects().map((r) => r.url ?? r.op));
    if (got.length !== s.count) throw new Error(`expected ${s.count} pending effects, got ${got.length} ${JSON.stringify(got)}`);
  },
  "tick-interval": tick,
  "tick-interval-if-active": tick,
  "expect-interval": async (page, s) => {
    const n = await page.evaluate((ms) => window.__rt.intervals(ms).length, s.period_ms);
    if (n !== s.count) throw new Error(`${n} live intervals with period ${s.period_ms} ms, expected ${s.count}`);
  },
  "expect-cleanup": async (page, s) => {
    const n = await page.evaluate((name) => (window.__rt.workRecord().cleanups.get(name) ?? 0n).toString(), s.name);
    if (BigInt(n) !== BigInt(s.count)) throw new Error(`cleanup ${JSON.stringify(s.name)} ran ${n} times, expected ${s.count}`);
  },
  navigate: async (page, s, state) => {
    const from = await page.evaluate(() => location.pathname + location.search + location.hash);
    if (sameDocument(from, s.text)) return popstateAfter(page, `location.assign(${JSON.stringify(s.text)})`);
    // Any other navigation loads a new document: the app mounts afresh.
    return navigating(page, state, () => page.evaluate((url) => location.assign(url), s.text), { cross: true, href: s.text });
  },
  "set-online": async (page, s) => {
    await page.evaluate((on) => {
      Object.defineProperty(navigator, "onLine", { get: () => on, configurable: true });
      window.dispatchEvent(new Event(on ? "online" : "offline"));
    }, s.text === "online");
    return settle(page);
  },
  "set-visibility": async (page, s) => {
    await page.evaluate((vis) => {
      Object.defineProperty(document, "visibilityState", { get: () => vis, configurable: true });
      Object.defineProperty(document, "hidden", { get: () => vis === "hidden", configurable: true });
      document.dispatchEvent(new Event("visibilitychange"));
    }, s.text);
    return settle(page);
  },
  "history-back": (page) => traverse(page, -1, "history-back"),
  "history-forward": (page) => traverse(page, 1, "history-forward"),
  "expect-current-location": async (page, s) => {
    const got = await page.evaluate(() => location.pathname + location.search + location.hash);
    if (got !== s.text) throw new Error(`location ${JSON.stringify(got)}, expected ${JSON.stringify(s.text)}`);
  },
  "expect-document-title": async (page, s) => {
    const got = await page.title();
    if (got !== s.text) throw new Error(`title ${JSON.stringify(got)}, expected ${JSON.stringify(s.text)}`);
  },
  "expect-local-storage": async (page, s) => {
    const got = await storageItem(page, s.key);
    if (got !== s.text) throw new Error(`local storage ${s.key} = ${got === null ? "<missing>" : JSON.stringify(got)}, expected ${JSON.stringify(s.text)}`);
  },
  "expect-no-local-storage": async (page, s) => {
    if ((await storageItem(page, s.key)) !== null) throw new Error(`local storage ${s.key} is present`);
  },
  "mark-metrics": async (page, s, state) => {
    state.mark = await counters(page);
  },
  "expect-metric-delta": (page, s, state) => metricDelta(page, state, s, false),
  "expect-metric-delta-at-most": (page, s, state) => metricDelta(page, state, s, true),
};

// One handler per setup form of the grammar (`Scm.setup_forms`).
const SETUP = {
  "initial-location": (out, s) => {
    out.location = s.text;
  },
  "local-storage": (out, s) => {
    out.storage.push([s.key, s.text]);
  },
  "local-storage-unavailable": (out) => {
    out.storageAvailable = false;
  },
  "initial-online": (out, s) => {
    out.online = s.text === "online";
  },
  "initial-visibility": (out, s) => {
    out.visibility = s.text;
  },
};

// `--check-grammar`: the handler tables cover exactly the grammar's forms.
function checkGrammar(file) {
  const g = JSON.parse(fs.readFileSync(file, "utf8"));
  const diff = (kind, want, have) => {
    const out = [];
    for (const f of want) if (!have.includes(f)) out.push(`${kind} form ${f} has no handler in replay.mjs`);
    for (const f of have) if (!want.includes(f)) out.push(`replay.mjs handles ${kind} form ${f}, which the grammar does not have`);
    return out;
  };
  const problems = [...diff("step", g.steps, Object.keys(STEPS)), ...diff("setup", g.setup, Object.keys(SETUP))];
  for (const p of problems) console.error(p);
  console.error(problems.length === 0 ? `== replay.mjs handles all ${g.steps.length} step and ${g.setup.length} setup forms` : `== ${problems.length} grammar mismatches`);
  process.exit(problems.length === 0 ? 0 : 1);
}

function setupOf(spec) {
  const out = { location: "/", storage: [], storageAvailable: true, online: true, visibility: "visible" };
  for (const s of spec.setup) {
    const h = SETUP[s.op];
    if (h === undefined) throw new Error(`setup ${s.op} has no handler in this runner`);
    h(out, s);
  }
  if (!out.storageAvailable && out.storage.length) throw new Error("local-storage seeds storage that local-storage-unavailable says the app cannot read");
  return out;
}

// Installed in every document before the app loads: the document token, the
// attribute reader, the navigation a click's default action starts, and the
// page-side half of `expect-updates` (per node, the attribute and text
// mutations after the callback that inserted it).
function install(attrOfSource) {
  window.__doc = `${Date.now()}-${Math.random()}`;
  window.__attrOf = eval(`(${attrOfSource})`);
  window.__nav = null;
  // Bubbling, on window: after the runtime's delegated listener has decided
  // whether to prevent the click's default action.
  window.addEventListener("click", (e) => {
    if (e.defaultPrevented) return;
    const a = e.target instanceof Element ? e.target.closest("a[href]") : null;
    if (!a) return;
    const to = new URL(a.getAttribute("href"), location.href);
    const here = new URL(location.href);
    if (to.origin !== here.origin) {
      e.preventDefault();
      window.__nav = { cross: true, external: true, href: to.href };
      return;
    }
    const same = to.hash !== "" && to.pathname === here.pathname && to.search === here.search;
    window.__nav = same ? null : { cross: true, href: to.pathname + to.search + to.hash };
  });
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

const opts = parseArgs(process.argv.slice(2));
if (opts.grammar !== null) checkGrammar(opts.grammar);

const specs = fs
  .readFileSync(opts.steps, "utf8")
  .split("\n")
  .filter((l) => l.trim() !== "")
  .map((l) => JSON.parse(l));

const files = {
  "index.html": path.join(here, "index.html"),
  "locate.js": path.join(here, "locate.js"),
  "runtime.mjs": opts.runtime,
  // The runtime's worker script, which it loads from beside itself.
  "worker.mjs": path.join(path.dirname(opts.runtime), "worker.mjs"),
  "app.wasm": opts.wasm,
};
const types = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript", ".wasm": "application/wasm" };
// Files are served by basename under any path (apps mount under a base path,
// e.g. /roc-signals/examples/conduit/), and a directory as index.html.
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
      (storage, storageAvailable, online, visibility) => {
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
        window.__manualFx = true;
        if (!online) Object.defineProperty(navigator, "onLine", { get: () => false, configurable: true });
        if (visibility !== "visible") {
          Object.defineProperty(document, "visibilityState", { get: () => visibility, configurable: true });
          Object.defineProperty(document, "hidden", { get: () => true, configurable: true });
        }
      },
      setup.storage,
      setup.storageAvailable,
      setup.online,
      setup.visibility,
    );
    await page.evaluateOnNewDocument(install, attrOf.toString());
    const state = { stub: null, mark: null, doc: null, loads: 0 };
    await page.goto(`http://127.0.0.1:${port}${setup.location}`);
    page.conn.on(page.sessionId, "Page.loadEventFired", () => {
      state.loads += 1;
    });
    await mounted(page);
    state.doc = await docToken(page);
    for (; i < spec.steps.length; i += 1) {
      const s = spec.steps[i];
      const h = STEPS[s.op];
      if (h === undefined) throw new Error(`${s.op} has no handler in this runner`);
      await h(page, s, state);
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
      kind: "assertion",
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
console.error(`== ${count("passed")} passed, ${count("failed")} failed`);
if (opts.out) fs.writeFileSync(opts.out, JSON.stringify({ results }, null, 1));
process.exit(count("failed") === 0 && results.length > 0 ? 0 : 1);
