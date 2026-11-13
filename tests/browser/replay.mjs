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
// live DOM. A worker job the runtime reports lost (`roc worker fault [...]`
// on the console) is a result, not a page error. Effects are always manual: `stub-http` stages one answer and
// `run-effect N` answers the N-th awaited HTTP request or upload, timer, worker job or operation on a file
// the current document issued (a job really runs in a worker, and the step
// waits for its result turn); storage reads answer by themselves from storage. History,
// title and storage assertions read the real browser state. A worker job's
// timeout never fires on its own: `time-out-work` expires it and
// `lose-work` answers it lost, through the runtime's manual-mode hooks.
// `local-storage-unavailable` makes `window.localStorage` throw, as a browser
// with site data disabled does; storage assertions then read the real store
// underneath, so they confirm nothing was written.
//
// Intervals tick only through `tick-interval` (the runtime's manual
// intervals), and connectivity and visibility change only through
// `set-online` and `set-visibility`, which update the runtime's environment readers and
// dispatch the browser's own events only when a value changes.
// A report step supplies its own frame unless `hold-reports` is active;
// assertions leave that frame pending and occurrences deliver it first.
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
import os from "node:os";
import { fileURLToPath } from "node:url";
import { launch } from "./cdp.mjs";
import { verifyPointerRecords, verifyClickEvents, beginPointerInput, endPointerInput } from "./pointer-log.mjs";

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

// Native close/toggle tasks can run after a zero-delay timer. Observe their
// actual completion; the tracker never causes a callback or an app turn.
async function settle(page) {
  const deadline = Date.now() + 20000;
  for (;;) {
    const observation = await page.evaluate(async () => {
      let timer;
      try {
        await Promise.race([window.__rt?.idle(), new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("transition idle timed out")), 20000); })]);
      } catch (error) { return { error: error.message }; }
      finally { clearTimeout(timer); }
      await new Promise((resolve) => setTimeout(resolve, 0));
      try { return { ready: window.__rt?.nativeEventsReady() ?? true, pending: !!window.__rt?.pendingTransition }; }
      catch (error) { return { error: error.message }; }
    });
    if (observation.error) throw new Error(`native UI observation failed: ${observation.error}`);
    if (observation.ready && !observation.pending) {
      await page.evaluate(async () => {
        const rt = window.__rt;
        if (rt?.manualScrollers?.size) await new Promise((resolve) => requestAnimationFrame(() => setTimeout(resolve, 0)));
        rt?.checkManualScrolls();
      });
      return;
    }
    if (Date.now() >= deadline) throw new Error("native UI observation timed out waiting for actual callbacks");
  }
}

// These are oracle-known top-layer facts, without layout or hit testing.
async function reachable(page, loc) {
  await need(page, loc);
  const reason = await onEl(page, loc, (element) => {
    const modal = window.__rt.topModal();
    if (modal && !modal.contains(element)) return "is outside the topmost modal dialog";
    for (let ancestor = element; ancestor && ancestor !== window.__rt.root; ancestor = ancestor.parentElement) {
      if (ancestor.tagName === "DIALOG" && !ancestor.open) return "is inside a hidden dialog";
      if (ancestor.hasAttribute("popover") && !ancestor.matches(":popover-open")) return "is inside a hidden popover";
    }
    return null;
  });
  if (reason) throw new Error(`${showLoc(loc)} ${reason}`);
}

// The current document's token, set before any script runs (see `install`):
// a cross-document navigation replaces it.
const docToken = (page) => page.evaluate(() => window.__doc).catch(() => null);

// Wait for the app of a new document to mount.
async function mounted(page) {
  await page.waitForFunction("window.__ready || window.__error");
  const err = await page.evaluate(() => window.__error ?? null);
  if (err) throw new Error(`mount failed: ${err}`);
  await settle(page);
}

// Run `act`, which may start a navigation, then wait for its outcome: a
// same-document navigation's popstate has already run; a cross-document one
// mounts the app afresh at the new URL. `__nav` (see `install`) records the
// navigation a click's default action starts, before it commits.
async function navigating(page, state, act, known = undefined) {
  const before = state.doc;
  const loads = state.loads;
  await act();
  if (state.dialogError) throw new Error(state.dialogError);
  // The click may already have replaced its document, whose installer has
  // reset __nav. Read the intent and token together so that replacement is
  // still observed even when the old document's intent is no longer present.
  const observed = await page
    .evaluate(() => {
      const nav = window.__nav ?? null;
      window.__nav = null;
      return { nav, doc: window.__doc, href: location.pathname + location.search + location.hash };
    })
    .catch(() => ({ nav: { cross: true, href: "?" }, doc: null }));
  const nav = known ?? observed.nav;
  if (nav?.cross || observed.doc !== before) {
    const href = nav?.href ?? observed.href;
    if (state.holdingReports) throw new Error("a cross-document navigation cannot leave while reports are held");
    if (state.pointers.size) throw new Error("a cross-document navigation cannot leave while a pointer is down");
    if (nav?.external) throw new Error(`the click navigates to ${nav.href}, which leaves the app`);
    const t0 = Date.now();
    while (state.loads === loads) {
      if (state.dialogError) throw new Error(state.dialogError);
      if (Date.now() - t0 > 20000) throw new Error(`timed out waiting for the navigation to ${href}`);
      await new Promise((r) => setTimeout(r, 10));
    }
    await mounted(page);
    // The new document's preinstalled reader advances its seed before the
    // app mounts. Carry that exact environment forward for another document.
    state.environment = await page.evaluate(() => window.__env);
    await installEnvironment(page, state);
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
  await reachable(page, loc);
  const box = await onEl(page, loc, (e) => {
    e.scrollIntoView({ block: "nearest", inline: "nearest" });
    const r = e.getBoundingClientRect();
    return { x: r.left + r.width / 2, y: r.top + r.height / 2, disabled: e.disabled === true };
  });
  if (box.disabled) {
    if (real) throw new Error(`${showLoc(loc)} is disabled`);
    return;
  }
  await pointerPoint(page, loc, null, true);
  await beginPointerInput(page, { loc });
  await navigating(page, state, () => page.clickAt(box));
  const { raw, records } = await endPointerInput(page);
  const events = raw.filter((record) => record.typed);
  verifyClickEvents(raw);
  verifyPointerRecords(records, events.map((record) => ({ ...record, alias: 1 })), new Map([[1, { alias: 1, kind: "mouse" }]]), 1);
}

// Locate a spec point without asking the engine to invent layout. The
// oracle can name only a zone's fractions or the centre outside any zone.
async function pointerPoint(page, loc, at, click = false) {
  await reachable(page, loc);
  const result = await onEl(page, loc, (element, at, click) => {
    element.scrollIntoView({ block: "nearest", inline: "nearest" });
    const root = window.__rt.root;
    let zone = element;
    while (zone && zone !== root && !zone.__pointerZone) zone = zone.parentElement;
    if (zone === root) zone = null;
    const reachesPointer = (type) => {
      for (let node = element; node && node !== root; node = node.parentElement) {
        if (node.__h?.[type]) return node.__h[type].kind === 3;
      }
      return false;
    };
    const typed = !click || ["pointermove", "pointerdown", "pointerup"].some(reachesPointer);
    if (typed && at === null && zone && zone !== element) return { error: `LOC lies in zone ${zone.__pointerZone}; give :at in that zone using the pointer steps` };
    if (at !== null && !zone) return { error: ":at needs a pointer zone" };
    const box = (at === null ? element : zone).getBoundingClientRect();
    if (box.width <= 0 || box.height <= 0) return { error: "a pointer step cannot place a point in a zero-size box" };
    const x = box.x + box.width * (at === null ? 0.5 : at.x / 100);
    const y = box.y + box.height * (at === null ? 0.5 : at.y / 100);
    const hit = document.elementFromPoint(x, y);
    if (!hit || !element.contains(hit)) return { error: "the pointer point does not hit LOC or a descendant" };
    let actualZone = hit;
    while (actualZone && actualZone !== root && !actualZone.__pointerZone) actualZone = actualZone.parentElement;
    if (actualZone === root) actualZone = null;
    if (typed && actualZone !== zone) return { error: "a nested or different pointer zone covers the point" };
    return { x, y, at: !zone ? null : { zone: zone.__pointerZone, x: at === null ? 5000 : at.x * 100, y: at === null ? 5000 : at.y * 100 }, touchAction: getComputedStyle(element).touchAction };
  }, at, click);
  if (result.error) throw new Error(result.error);
  return result;
}

const pointerModifiers = (names) => names.reduce((mask, name) => mask | ({ alt: 1, ctrl: 2, meta: 4, shift: 8 })[name], 0);
const mouseButton = (button) => ({ main: "left", middle: "middle", secondary: "right" })[button];
const buttonMask = (button) => ({ main: 1, middle: 4, secondary: 2 })[button];

async function pointerStep(page, step, state) {
  const pointers = state.pointers;
  const down = step.op === "pointer-down", cancel = step.op === "pointer-cancel", up = step.op === "pointer-up";
  let pointer = pointers.get(step.id);
  if (down && pointer) throw new Error(`pointer ${step.id} is already down`);
  if (!down && !pointer && !(step.op === "pointer-move" && step.id === 1)) throw new Error(`pointer ${step.id} is not down`);
  if (down) {
    if (step.pointer === "mouse" && step.id !== 1) throw new Error("the mouse pointer id is 1");
    if (step.pointer !== "mouse" && step.id === 1) throw new Error("pointer id 1 is reserved for the mouse");
    if (step.pointer !== "touch" && [...pointers.values()].some((p) => p.kind !== "touch")) throw new Error("the browser replay supports one active mouse or pen press");
    if ([...pointers.values()].some((p) => (p.kind === "touch") !== (step.pointer === "touch"))) throw new Error("the browser replay cannot mix touch with a mouse or pen press");
    pointer = { id: step.id, kind: step.pointer, button: step.button, modifiers: step.modifiers, moved: false };
    if (step.pointer === "touch") {
      if (pointers.size >= 16) throw new Error("the browser replay supports at most 16 active touch pointers");
      const used = new Set([...pointers.values()].map((p) => p.driver));
      pointer.driver = 0;
      while (used.has(pointer.driver)) pointer.driver += 1;
    }
  } else if (!pointer) pointer = { id: 1, kind: "mouse", button: "none", modifiers: [], moved: false };
  if (cancel && pointer.kind !== "touch") throw new Error("pointer-cancel requires a touch pointer");
  if (cancel && [...pointers.values()].filter((p) => p.kind === "touch").length !== 1) throw new Error("pointer-cancel cannot cancel only the named touch while several touches are active");
  const point = cancel ? { x: pointer.x, y: pointer.y, at: null } : await pointerPoint(page, step.loc, step.at);
  if (down && pointer.kind === "touch" && point.touchAction !== "none") throw new Error("touch pointer-down requires touch-action:none on LOC");
  if (pointer.kind === "touch" && step.op === "pointer-move" && point.x === pointer.x && point.y === pointer.y) throw new Error("touch pointer-move must change the point beyond tap slop");
  await beginPointerInput(page, { at: cancel ? null : point.at });
  await page.evaluate((active) => { window.__pointersActive = active; }, down ? true : up || cancel ? pointers.size > 1 : pointers.size > 0);
  const modifiers = pointerModifiers(pointer.modifiers);
  if (up || cancel) pointers.delete(step.id);
  const dispatch = async () => {
    if (pointer.kind === "touch") {
      const touches = [...pointers.values()].filter((p) => p.kind === "touch").map((p) => ({ id: p.driver, x: p.id === step.id ? point.x : p.x, y: p.id === step.id ? point.y : p.y }));
      if (down) touches.push({ id: pointer.driver, x: point.x, y: point.y });
      // CDP touchEnd names the released points, whereas start/move describe
      // active points. An empty end would release every remaining touch.
      const points = up ? [{ id: pointer.driver, x: point.x, y: point.y }] : touches;
      await page.send("Input.dispatchTouchEvent", { type: cancel ? "touchCancel" : down ? "touchStart" : up ? "touchEnd" : "touchMove", touchPoints: cancel ? [] : points, modifiers });
      // Chrome may acknowledge a touch move before its frame-aligned DOM
      // dispatch. Manual reports remain held while that input reaches listeners.
      if (!down && !up && !cancel) await page.evaluate(() => new Promise(requestAnimationFrame));
    } else {
      await page.send("Input.dispatchMouseEvent", { type: down ? "mousePressed" : up ? "mouseReleased" : "mouseMoved", x: point.x, y: point.y,
        button: pointer.button === "none" ? "none" : mouseButton(pointer.button), buttons: up ? 0 : buttonMask(pointer.button) ?? 0,
        clickCount: down || up ? 1 : 0, pointerType: pointer.kind, modifiers });
    }
  };
  await navigating(page, state, dispatch);
  const { raw, records } = await endPointerInput(page);
  const type = cancel ? "pointercancel" : down ? "pointerdown" : up ? "pointerup" : "pointermove";
  const event = raw.find((record) => record.type === type && (!pointer.actual || record.id === pointer.actual));
  if (!event) throw new Error(pointer.kind === "touch" && type === "pointermove" ? `touch move raised no event beyond the browser's tap slop (${JSON.stringify(raw)})` : `the browser raised no ${type}`);
  if (event.kind !== pointer.kind || (pointer.kind === "mouse" && event.id !== 1)) throw new Error(`pointer ${step.id} received the wrong browser pointer kind or identity`);
  pointer.actual = event.id;
  const aliases = new Map([[1, { alias: 1, kind: "mouse" }]]);
  for (const active of pointers.values()) aliases.set(active.actual, { alias: active.id, kind: active.kind });
  aliases.set(pointer.actual, { alias: step.id, kind: pointer.kind });
  const typed = raw.filter((record) => record.typed);
  if (typed.some((record) => record.type !== type || record.id !== pointer.actual || record.kind !== pointer.kind) || typed.length > 1) throw new Error(`pointer ${step.id} received an unexpected extra pointer dispatch`);
  verifyPointerRecords(records, typed.map((record) => ({ ...record, alias: step.id })), aliases, step.id);
  if (down) {
    await page.evaluate(({ id, actual }) => {
      window.__pointerCaptures ??= new Map();
      for (let element = window.__pointerDownTarget; element && element !== window.__rt.root; element = element.parentElement) {
        if (element.hasPointerCapture?.(actual)) { window.__pointerCaptures.set(id, { element, actual }); break; }
      }
    }, { id: step.id, actual: event.id });
  }
  if (up || cancel) {
    pointers.delete(step.id);
    await page.evaluate((id) => window.__pointerCaptures?.delete(id), step.id);
  } else if (down || pointers.has(step.id)) {
    pointers.set(step.id, { ...pointer, x: point.x, y: point.y, moved: pointer.moved || !down });
  }
  return settle(page);
}

// How long `run-effect` waits for a worker job, as the native runner does
// (`spec.zig`, `job_bound_ms`).
const JOB_BOUND_MS = 30000;

// The runtime reports every lost worker job on the console with this prefix
// (and the native runner on stderr). A lost job is a result the app sees,
// not a page error: the spec asserts what the app does with it.
const WORKER_FAULT = "roc worker fault [";
const pageErrors = (page) => page.errors.filter((e) => !e.startsWith(WORKER_FAULT));

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
  await reachable(page, loc);
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
  await reachable(page, loc);
  const kind = await onEl(page, loc, (e) => (e.tagName === "INPUT" ? (e.getAttribute("type") ?? "").toLowerCase() : ""));
  if (kind !== "checkbox" && kind !== "radio") throw new Error(`${showLoc(loc)} is not a checkbox or radio button`);
  if (kind === "radio" && !want) throw new Error(`${showLoc(loc)} is a radio button, which cannot be unchecked`);
  if ((await onEl(page, loc, (e) => e.checked)) === want) return;
  await click(page, state, loc, false);
  if ((await onEl(page, loc, (e) => e.checked)) !== want) throw new Error(`clicking ${showLoc(loc)} did not ${want ? "check" : "uncheck"} it`);
}

// Claimed attributes on controls read their live property. On other
// elements value/checked remain ordinary attributes, as their commands do.
const attrOf = (e, n) => {
  if (n === "checked" && e.tagName === "INPUT") return e.checked ? "true" : "false";
  if (n === "disabled") return e.disabled ? "true" : "false";
  if (n === "value" && ["INPUT", "TEXTAREA", "SELECT", "OPTION"].includes(e.tagName)) return e.value;
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

// The setup files a file step names, as { name, type, text, count }.
function setupFiles(state, names) {
  return names.map((name) => {
    const f = state.files.get(name);
    if (f === undefined) throw new Error(`no setup file named ${JSON.stringify(name)}`);
    return { name, ...f };
  });
}

// The directories chosen files were written to, removed when the replay ends.
const chosenDirs = [];
process.on("exit", () => {
  for (const d of chosenDirs) fs.rmSync(d, { recursive: true, force: true });
});

// `choose-files`: the files are written to disk, each under its own name,
// and set on the file input through DevTools, as a user's choice in the
// browser's own chooser sets them, which fires `input` and `change`. The
// browser decides a chosen file's type from its name; it must be the type
// the spec declares.
async function chooseFiles(page, s, state) {
  const files = setupFiles(state, s.files);
  await reachable(page, s.loc);
  const r = await onEl(page, s.loc, (e, n) => {
    if (e.tagName !== "INPUT" || (e.getAttribute("type") ?? "").toLowerCase() !== "file") return { error: "is not a file input" };
    if (e.disabled) return { error: "is disabled" };
    if (n > 1 && !e.multiple) return { error: `takes one file, not ${n}` };
    return {};
  }, files.length);
  if (r.error) throw new Error(`${showLoc(s.loc)} ${r.error}`);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "roc-signals-files-"));
  const paths = files.map((f, i) => {
    fs.mkdirSync(path.join(dir, String(i)));
    const p = path.join(dir, String(i), f.name);
    fs.writeFileSync(p, f.text.repeat(f.count));
    return p;
  });
  const input = await page.evaluateHandle((loc) => window.__loc(loc), s.loc);
  await page.send("DOM.setFileInputFiles", { files: paths, objectId: input.objectId });
  await settle(page);
  // A chosen file is read from disk when a worker reads it, so it stays
  // until the replay ends.
  chosenDirs.push(dir);
  const types = await onEl(page, s.loc, (e) => Array.from(e.files).map((f) => f.type));
  files.forEach((f, i) => {
    if (types[i] !== f.type) throw new Error(`Chrome gives ${f.name} the type ${JSON.stringify(types[i])}, not the declared ${JSON.stringify(f.type)}`);
  });
}

// `drop-files` and `paste-files`: a `DataTransfer` of the files, carried by
// the browser's own `dragover` and `drop` events, or by a `paste` event. A
// drop needs a `dragover` that the page prevented, as in a real drag.
async function giveFiles(page, s, state, kind) {
  const files = setupFiles(state, s.files);
  await reachable(page, s.loc);
  const r = await onEl(page, s.loc, (e, kind, files) => {
    const dt = new DataTransfer();
    for (const f of files) dt.items.add(new File([f.text.repeat(f.count)], f.name, { type: f.type }));
    if (kind === "paste") {
      e.dispatchEvent(new ClipboardEvent("paste", { clipboardData: dt, bubbles: true, cancelable: true }));
      return {};
    }
    const over = new DragEvent("dragover", { dataTransfer: dt, bubbles: true, cancelable: true });
    e.dispatchEvent(over);
    if (!over.defaultPrevented) return { error: "does not take a drop" };
    e.dispatchEvent(new DragEvent("drop", { dataTransfer: dt, bubbles: true, cancelable: true }));
    return {};
  }, kind, files);
  if (r.error) throw new Error(`${showLoc(s.loc)} ${r.error}`);
  return settle(page);
}

async function stage(state, answer) {
  if (state.stub !== null) throw new Error("a stub is already staged; run-effect answers one at a time");
  state.stub = answer;
}

// `lose-work` and `time-out-work`: the N-th effect occurrence must be a
// pending worker job; the runtime's manual-mode hooks answer it, without
// running it, `WorkLost(fault)` or (for a job with a timeout) `Timeout`.
async function answerJob(page, n, how, fault) {
  const r = await page.evaluate(
    (n, how, fault) => {
      const rt = window.__rt;
      const id = rt.issued[n - 1];
      if (id === undefined) return `effect occurrence ${n} was never issued (${rt.issued.length} issued)`;
      const e = rt.live.get(id);
      if (e === undefined || e.running) return `effect occurrence ${n} is not pending (cancelled or done)`;
      if (e.kind === "portcall") return `effect occurrence ${n} is a call on port ${JSON.stringify(e.req.port)}, not a worker job`;
      if (e.kind !== "work") return `effect occurrence ${n} is ${e.kind === "timer" ? "a timer" : e.kind === "file" ? "an operation on a file" : "an HTTP request"}, not a worker job`;
      if (how === "expire") {
        if (!(e.req.timeout > 0)) return `worker job ${n} has no timeout, so it cannot time out`;
        return rt.expireEffect(id) ? null : `worker job ${n} could not be expired`;
      }
      return rt.loseEffect(id, fault) ? null : `worker job ${n} could not be lost to ${fault}`;
    },
    n,
    how,
    fault,
  );
  if (r) throw new Error(r);
  return settle(page);
}

// The pending port call that is the N-th effect occurrence, as the native
// runner's `pending_port_call` finds it: { id, port, json, timeout } or
// { error }.
function pendingPortCall(n) {
  const rt = window.__rt;
  const id = rt.issued[n - 1];
  if (id === undefined) return { error: `effect occurrence ${n} was never issued (${rt.issued.length} issued)` };
  const e = rt.live.get(id);
  if (e === undefined || e.running) return { error: `effect occurrence ${n} is not pending (cancelled or done)` };
  if (e.kind !== "portcall") return { error: `effect occurrence ${n} is not a port call` };
  return { id, port: e.req.port, json: e.req.msg.json, timeout: e.req.timeout };
}

// The port steps, through the runtime's manual-mode hooks: a call waits
// for `answer-port`, subscriptions for `emit-port`, `close-port` and
// `fail-port`, and commands are logged.
const PORT_STEPS = {
  "expect-port-call": async (page, s) => {
    const c = await page.evaluate(`(${pendingPortCall})(${s.count})`);
    if (c.error) throw new Error(c.error);
    if (c.port !== s.port || c.json !== s.json) throw new Error(`effect occurrence ${s.count} is a call on port ${JSON.stringify(c.port)} with ${JSON.stringify(c.json)}, expected port ${JSON.stringify(s.port)} with ${JSON.stringify(s.json)}`);
  },
  "answer-port": async (page, s) => {
    const c = await page.evaluate(`(${pendingPortCall})(${s.count})`);
    if (c.error) throw new Error(c.error);
    if (s.answer === "timeout" && !(c.timeout > 0)) throw new Error(`the call on port ${JSON.stringify(c.port)} has no timeout, so it cannot time out`);
    const answer = s.answer === "reply" ? { json: s.json } : s.answer === "throw" ? { threw: s.text } : s.answer === "too-large" ? { tooLarge: true } : { timeout: true };
    const ok = await page.evaluate((id, answer) => window.__rt.answerPort(id, answer), c.id, answer);
    if (!ok) throw new Error(`the call on port ${JSON.stringify(c.port)} could not be answered`);
    return settle(page);
  },
  "expect-port-sent": async (page, s) => {
    const sent = await page.evaluate((port) => window.__rt.portLog.filter((c) => c.port === port).map((c) => c.json), s.port);
    if (s.index < 1 || s.index > sent.length) throw new Error(`port ${JSON.stringify(s.port)} was sent ${sent.length} commands, so there is no command ${s.index}`);
    const got = sent[s.index - 1];
    if (got !== s.json) throw new Error(`command ${s.index} on port ${JSON.stringify(s.port)} carried ${JSON.stringify(got)}, expected ${JSON.stringify(s.json)}`);
  },
  "expect-port-sends": async (page, s) => {
    const got = await page.evaluate((port) => window.__rt.portLog.filter((c) => c.port === port).length, s.port);
    if (got !== s.count) throw new Error(`port ${JSON.stringify(s.port)} was sent ${got} commands, expected ${s.count}`);
  },
  "emit-port": (page, s) => portMessage(page, s.port, { json: s.json }),
  "close-port": (page, s) => portMessage(page, s.port, { closed: true }),
  "fail-port": (page, s) => portMessage(page, s.port, { threw: s.text }),
  "expect-port-subscriptions": async (page, s) => {
    const got = await page.evaluate((port) => window.__rt.portSubscriptions(port), s.port);
    if (got !== s.count) throw new Error(`${got} live subscriptions on port ${JSON.stringify(s.port)}, expected ${s.count}`);
  },
};

async function portMessage(page, port, answer) {
  const n = await page.evaluate((port, answer) => window.__rt.messagePort(port, answer), port, answer);
  if (n === 0) throw new Error(`no live subscription on port ${JSON.stringify(port)}`);
  return settle(page);
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

async function observeKeyInput(page, state) {
  await page.evaluate((defaults, types) => {
    let pending = null;
    const flush = () => {
      if (!pending) return;
      window.__rocKeyFacts(JSON.stringify({ type: pending.event.type, prevented: pending.event.defaultPrevented, refused: pending.refused }));
      pending = null;
    };
    const capture = (event) => {
      flush();
      const target = event.target;
      const input = target.tagName === "INPUT";
      const text = target.tagName === "TEXTAREA" || target.isContentEditable ||
        (input && !types.text_input_excluded.includes(target.type));
      const controls = new Set();
      if (text) controls.add("text");
      if (target.tagName === "TEXTAREA") controls.add("textarea");
      if (target.isContentEditable) controls.add("editable");
      if (target.tagName === "A" && target.hasAttribute("href")) controls.add("link");
      if (target.tagName === "SELECT" || (input && types.choice_input_types.includes(target.type))) controls.add("choice");
      const refused = defaults.some((row) => controls.has(row.control) && row.keys.some((key) => {
        if (key === "printable") return /^[ -~]$/.test(event.key) && !event.ctrlKey && !event.metaKey;
        if (key.startsWith("primary:")) return (event.ctrlKey || event.metaKey) && event.key.toUpperCase() === key.slice(8);
        if (key.startsWith("modified:")) return (event.ctrlKey || event.altKey || event.shiftKey || event.metaKey) && event.key === key.slice(9);
        return event.key === key;
      }));
      pending = { event, refused };
    };
    for (const type of ["keydown", "keyup"]) window.addEventListener(type, capture, true);
    window.addEventListener("beforeunload", flush);
    window.__flushKeyInput = flush;
    window.__endKeyInput = () => {
      flush();
      for (const type of ["keydown", "keyup"]) window.removeEventListener(type, capture, true);
      window.removeEventListener("beforeunload", flush);
      delete window.__endKeyInput;
      delete window.__flushKeyInput;
    };
  }, state.keyDefaults, state.keyControlTypes);
}

async function flushKeyInput(page) {
  await page.evaluate(() => window.__flushKeyInput?.()).catch((error) => {
    if (!/Execution context was destroyed|Cannot find context/.test(error.message)) throw error;
  });
}

// Keep the actual KeyboardEvent until dispatch has returned. A passive CDP
// binding preserves its prevented flag even when a key activates navigation.
async function press(page, step, state) {
  if (step.loc) {
    await reachable(page, step.loc);
    await onEl(page, step.loc, (element) => element.focus());
    await settle(page);
  }
  if (!page.keyBinding) {
    await page.send("Runtime.addBinding", { name: "__rocKeyFacts" });
    page.conn.on(page.sessionId, "Runtime.bindingCalled", (event) => {
      if (event.name !== "__rocKeyFacts" || !page.keyFacts) return;
      if (page.keyFacts.length >= 2) { page.keyFactsError = "press raised more than two keyboard events"; return; }
      page.keyFacts.push(JSON.parse(event.payload));
    });
    page.keyBinding = true;
  }
  page.keyFacts = [];
  page.keyFactsError = null;
  await observeKeyInput(page, state);
  let pressed = false, released = false;
  try {
    const before = state.doc;
    await navigating(page, state, async () => {
      await page.specKey(step.key, state.keyTable, "down");
      pressed = true;
      await flushKeyInput(page);
      if (page.keyFactsError) throw new Error(page.keyFactsError);
      const down = page.keyFacts.find((fact) => fact.type === "keydown");
      if (!down) throw new Error("press is missing physical keydown evidence");
      if (down.refused && !down.prevented) throw new Error("press has an unmodelled browser default; use fill for text input or prevent it with a keymap");
    });
    // Navigation caused by down has the ordinary bounded fresh-mount wait.
    // Only then release the physical key, with capture installed in that
    // document too, so a newly mounted Up handler hears the same release
    // as the native runner and missing input never becomes an empty log.
    if (state.doc !== before) await observeKeyInput(page, state);
    await navigating(page, state, async () => {
      await page.specKey(step.key, state.keyTable, "up");
      released = true;
      await flushKeyInput(page);
    });
    await page.evaluate(() => window.__endKeyInput?.());
    if (page.keyFactsError) throw new Error(page.keyFactsError);
    if (page.keyFacts.length !== 2 || page.keyFacts[0].type !== "keydown" || page.keyFacts[1].type !== "keyup") throw new Error("press requires physical keydown followed by keyup evidence");
  } finally {
    try {
      // A refused step still releases its synthetic physical key before
      // its context is discarded, without delivering another down.
      if (pressed && !released) await page.specKey(step.key, state.keyTable, "up");
    } finally { page.keyFacts = null; }
  }
  await settle(page);
}

// One handler per step form of the grammar (`Scm.step_forms`).
// A second page performs actual writes, so the app receives the browser's
// storage event rather than a synthetic callback or a driver-invented value.
async function storageElsewhere(page, step, state) {
  const source = await page.evaluate(() => location.origin);
  if (!state.storagePage) {
    state.storagePage = await state.context.newPage();
    await state.storagePage.goto(`${source}/storage-driver.html`);
  }
  const other = state.storagePage;
  try {
    await page.evaluate(key => {
      let resolve;
      const promise = new Promise(done => { resolve = done; });
      const listener = event => {
        if (event.storageArea === (window.__localStorage ?? localStorage) && event.key === key) resolve();
      };
      window.addEventListener("storage", listener);
      window.__storageStep = { promise, listener };
    }, step.op === "storage-elsewhere-cleared" ? null : step.key);
    const changed = await other.evaluate(s => {
      if (s.op === "storage-elsewhere") {
        const changed = localStorage.getItem(s.key) !== s.text;
        localStorage.setItem(s.key, s.text); return changed;
      }
      if (s.op === "storage-elsewhere-removed") {
        const changed = localStorage.getItem(s.key) !== null;
        localStorage.removeItem(s.key); return changed;
      }
      const changed = localStorage.length !== 0;
      localStorage.clear(); return changed;
    }, step);
    if (changed) await page.evaluate(async () => {
      let timer;
      try { await Promise.race([window.__storageStep.promise, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("the other document's storage event did not arrive")), 20000); })]); }
      finally { clearTimeout(timer); }
    });
  } finally {
    await page.evaluate(() => { if (window.__storageStep) window.removeEventListener("storage", window.__storageStep.listener); delete window.__storageStep; });
  }
  return settle(page);
}

async function leavePage(page, step, state) {
  if (state.holdingReports) throw new Error("a cross-document navigation cannot leave while reports are held");
  if (state.pointers.size) throw new Error("a cross-document navigation cannot leave while a pointer is down");
  const from = await page.evaluate(() => location.pathname + location.search + location.hash);
  if (sameDocument(from, step.text)) throw new Error("leave-page requires a cross-document URL");
  const intent = { outcome: step.outcome, dialogs: 0, handled: false };
  state.leave = intent;
  try {
    if (step.outcome !== "stay") {
      await navigating(page, state, () => page.evaluate(url => { setTimeout(() => location.assign(url), 0); }, step.text), { cross: true, href: step.text });
      if (intent.dialogs !== (step.outcome === "leave" ? 1 : 0)) throw new Error(`leave-page expected ${step.outcome === "leave" ? "one dialog" : "no dialog"}, saw ${intent.dialogs}`);
    } else {
      const before = state.doc;
      await page.evaluate(url => { setTimeout(() => location.assign(url), 0); }, step.text);
      const start = Date.now();
      while (!intent.handled) {
        if (state.dialogError) throw new Error(state.dialogError);
        if (await docToken(page) !== before) throw new Error("leave-page stay expected a dialog, but the browser left unasked");
        if (Date.now() - start >= 20000) throw new Error("leave-page stay expected a beforeunload dialog, but none opened");
        await new Promise(resolve => setTimeout(resolve, 10));
      }
      if (intent.dialogs !== 1 || await docToken(page) !== before) throw new Error("leave-page stay did not preserve its document after one declined dialog");
      await settle(page);
    }
  } finally { state.leave = null; }
}

const STEPS = {
  "paste-text": async (page, step) => {
    await reachable(page, step.loc);
    await onEl(page, step.loc, (element, text) => {
      const data = new DataTransfer();
      data.setData("text/plain", text);
      element.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
    }, step.text);
    return settle(page);
  },
  "storage-elsewhere": storageElsewhere,
  "storage-elsewhere-removed": storageElsewhere,
  "storage-elsewhere-cleared": storageElsewhere,
  "leave-page": leavePage,
  "expect-session-storage": async (page, step) => {
    const value = await page.evaluate(key => (window.__sessionStorage ?? sessionStorage).getItem(key), step.key);
    if (value !== step.text) throw new Error(`session storage ${JSON.stringify(step.key)} is ${JSON.stringify(value)}, expected ${JSON.stringify(step.text)}`);
  },
  "expect-no-session-storage": async (page, step) => {
    const value = await page.evaluate(key => (window.__sessionStorage ?? sessionStorage).getItem(key), step.key);
    if (value !== null) throw new Error(`session storage ${JSON.stringify(step.key)} is present`);
  },
  "expect-clipboard": async (page, step) => {
    const value = await page.evaluate(() => window.__rt.clipboardSnapshot().text);
    if (value !== step.text) throw new Error(`clipboard text is ${JSON.stringify(value)}, expected ${JSON.stringify(step.text)}`);
  },
  "expect-clipboard-html": async (page, step) => {
    const value = await page.evaluate(() => window.__rt.clipboardSnapshot().html);
    if (value !== step.text) throw new Error(`clipboard HTML is ${JSON.stringify(value)}, expected ${JSON.stringify(step.text)}`);
  },
  "expect-clipboard-writes": async (page, step) => {
    const count = await page.evaluate(() => window.__rt.clipboardSnapshot().writes);
    if (BigInt(count) !== BigInt(step.count)) throw new Error(`clipboard has ${count} successful writes, expected ${step.count}; denied attempts do not count`);
  },
  scroll: async (page, s) => {
    await need(page, s.loc);
    await onEl(page, s.loc, (element, top, left) => {
      const rt = window.__rt;
      if (rt.manualScrollers.has(element)) rt.expectManualScroll(element, { top, left });
      const rtl = getComputedStyle(element).direction === "rtl";
      element.scrollTo({ top, left: rtl ? -left : left, behavior: "instant" });
    }, s.top, s.left);
    await settle(page);
    const position = await onEl(page, s.loc, (element) => window.__rt.scrollPosition(element));
    if (position.top !== s.top || position.left !== s.left) throw new Error(`${showLoc(s.loc)} could not retain scroll position ${s.top}, ${s.left}; got ${position.top}, ${position.left}`);
  },
  "report-size": async (page, s) => {
    await need(page, s.loc);
    await onEl(page, s.loc, (element, width, height) => window.__rt.injectLayout(element, 7, { width, height }), s.width, s.height);
    return settle(page);
  },
  "report-seen": async (page, s) => {
    await need(page, s.loc);
    await onEl(page, s.loc, (element, intersecting, ratio_permille) => window.__rt.injectLayout(element, 8, { intersecting, ratio_permille }), s.intersecting, s.ratio_permille);
    return settle(page);
  },
  "set-media": async (page, s, state) => {
    const declared = await page.evaluate((query) => window.__rt.mediaQueries.includes(query), s.query);
    if (!declared) throw new Error(`undeclared media query ${JSON.stringify(s.query)}`);
    const values = new Map(state.environment.media);
    if ((values.get(s.query) ?? false) === s.matches) return;
    values.set(s.query, s.matches);
    state.environment.media = [...values];
    await installEnvironment(page, state);
    await page.evaluate(({ query, matches }) => {
      const current = window.__mediaQueries.get(query);
      current.matches = matches;
      current.dispatchEvent(new Event("change"));
      window.__env.media = [...new Map(window.__env.media).set(query, matches)];
    }, s);
    return settle(page);
  },
  "expect-observed": async (page, s) => {
    const count = await page.evaluate(() => Number(window.__rt.x.metric(16 + 44)));
    if (count !== s.count) throw new Error(`expected ${s.count} live observations, got ${count}`);
  },
  "expect-media-subscriptions": async (page, s) => {
    const count = await page.evaluate((query) => [...window.__rt.live.values()].filter((entry) => entry.req?.op === "media" && entry.req.query === query).length, s.query);
    if (count !== s.count) throw new Error(`expected ${s.count} media subscriptions for ${JSON.stringify(s.query)}, got ${count}`);
  },
  press,
  dismiss: (page, _step, state) => {
    const escape = state.keyTable.find((entry) => entry.name === "Escape");
    if (!escape) throw new Error("dismiss has no parser Escape definition");
    return press(page, { key: { key: escape.key, code: escape.code, ctrl: false, alt: false, meta: false, shift: false } }, state);
  },
  "expect-shown": async (page, step) => {
    await need(page, step.loc);
    const actual = await onEl(page, step.loc, (element) => element.tagName === "DIALOG"
      ? !element.open ? "hidden" : element.matches(":modal") ? "modal" : "open"
      : element.hasAttribute("popover") ? element.matches(":popover-open") ? "popover" : "hidden" : "unsupported");
    if (actual !== step.shown) throw new Error(`${showLoc(step.loc)} is ${actual}, expected ${step.shown}`);
  },
  "expect-transitions": async (page, step) => {
    const actual = await page.evaluate(() => window.__rt.transitionLog.total().toString());
    if (actual !== step.count) throw new Error(`${actual} view transitions, expected ${step.count}`);
  },
  "expect-transition": async (page, step) => {
    const actual = await page.evaluate(at => window.__rt.transitionLog.at(BigInt(at)).types, step.at);
    if (JSON.stringify(actual) !== JSON.stringify(step.types)) throw new Error(`transition ${step.at} types ${JSON.stringify(actual)}, expected ${JSON.stringify(step.types)}`);
  },
  "expect-scrolls": async (page, step) => {
    const actual = await page.evaluate(() => window.__rt.scrollCount().toString());
    if (actual !== step.count) throw new Error(`${actual} scroll commands, expected ${step.count}`);
  },
  "expect-scroll": async (page, step) => {
    await need(page, step.loc);
    const error = await page.evaluate((step) => {
      const record = window.__rt.scrollRecord(step.ordinal);
      if (record.target.deref() !== window.__loc(step.loc)) return "target differs";
      if (record.kind !== step.kind) return `kind is ${record.kind}, expected ${step.kind}`;
      return null;
    }, step);
    if (error) throw new Error(`scroll ${step.ordinal} ${error}`);
  },
  "pointer-down": pointerStep,
  "pointer-move": pointerStep,
  "pointer-up": pointerStep,
  "pointer-cancel": pointerStep,
  ...PORT_STEPS,
  "hold-reports": async (page, _s, state) => {
    if (state.holdingReports) throw new Error("reports are already held");
    state.holdingReports = true;
    await page.evaluate(() => { window.__reportsHeld = true; });
  },
  "release-reports": async (page, _s, state) => {
    if (!state.holdingReports) throw new Error("reports are not held");
    await releaseReports(page);
    state.holdingReports = false;
    await page.evaluate(() => { window.__reportsHeld = false; });
  },
  "expect-reports-replaced": async (page, s) => {
    const count = await page.evaluate(() => window.__rt.reportsReplaced);
    if (count !== s.count) throw new Error(`${count} reports were replaced, expected ${s.count}`);
  },
  click: (page, s, state) => click(page, state, s.loc, false),
  "real-click": (page, s, state) => click(page, state, s.loc, true),
  fill: (page, s) => fill(page, s.loc, s.text),
  check: (page, s, state) => setChecked(page, state, s.loc, true),
  uncheck: (page, s, state) => setChecked(page, state, s.loc, false),
  "select-option": async (page, s) => {
    await reachable(page, s.loc);
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
    await reachable(page, s.loc);
    await onEl(page, s.loc, (e) => e.focus());
    return settle(page);
  },
  blur: async (page, s) => {
    await reachable(page, s.loc);
    await onEl(page, s.loc, (e) => e.blur());
    return settle(page);
  },
  change: async (page, s) => {
    await reachable(page, s.loc);
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
    await reachable(page, s.loc);
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
  "expect-focused": async (page, s) => {
    await need(page, s.loc);
    if (!(await onEl(page, s.loc, (e) => e === document.activeElement))) throw new Error(`${showLoc(s.loc)} is not focused`);
  },
  "expect-no-focus": async (page) => {
    if (!(await page.evaluate(() => document.activeElement === document.body))) throw new Error("an element holds focus");
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
      (n, answer, JOB_BOUND_MS) => {
        const rt = window.__rt;
        const id = rt.issued[n - 1];
        if (id === undefined) return { error: `effect occurrence ${n} was never issued (${rt.issued.length} issued)` };
        const e = rt.live.get(id);
        if (e === undefined) return { error: `effect occurrence ${n} is not pending (cancelled or done)` };
        if (e.kind === "portcall") return { error: `effect occurrence ${n} is a call on port ${JSON.stringify(e.req.port)}; answer it with answer-port` };
        // A timer fires; it takes no staged answer.
        if (e.kind === "timer") {
          rt.runEffect(id, {});
          return { used: false };
        }
        // A worker job really runs in a worker; the step waits for its
        // result turn.
        // A spec's time is manual, so the job's own timeout never ends it;
        // the runner's bound (as the native runner's) fails a job that never
        // finishes instead of hanging.
        // An operation on a file the app holds is really performed, on the
        // file Chrome holds; the step waits for its result turn.
        if (e.kind === "file") {
          return Promise.resolve(rt.runEffect(id)).then(() => ({ used: false }));
        }
        if (e.kind === "work") {
          return Promise.race([
            Promise.resolve(rt.runEffect(id)).then(() => ({ used: false })),
            new Promise((r) => setTimeout(() => r({ error: "the worker job did not finish within 30 s; a spec expires a job's timeout with time-out-work" }), JOB_BOUND_MS)),
          ]);
        }
        if (answer === null) return { error: `run-effect ${n} answers ${e.req.url} without a staged stub` };
        if (answer.url !== undefined && e.req.url !== answer.url) return { error: `no spec stub for ${e.req.url} (stub is for ${answer.url})` };
        rt.runEffect(id, answer);
        return { used: true };
      },
      s.count,
      state.stub,
      JOB_BOUND_MS,
    );
    if (r.error) throw new Error(r.error);
    if (r.used) state.stub = null;
    return settle(page);
  },
  "expect-pending-effects": async (page, s) => {
    const got = await page.evaluate(() => window.__rt.pendingEffects().map((r) => r.url ?? r.op));
    if (got.length !== s.count) throw new Error(`expected ${s.count} pending effects, got ${got.length} ${JSON.stringify(got)}`);
  },
  "lose-work": (page, s) => answerJob(page, s.count, "lose", s.fault),
  "time-out-work": (page, s) => answerJob(page, s.count, "expire", null),
  "expect-pending-work": async (page, s) => {
    const got = await page.evaluate((task) => window.__rt.pendingEffects().filter((r) => r.op === "work" && r.task === task).length, s.task);
    if (got !== s.count) throw new Error(`expected ${s.count} pending worker jobs for ${JSON.stringify(s.task)}, got ${got}`);
  },
  // The N-th effect occurrence is a pending upload whose body is the range
  // of the chosen setup file: what the runtime holds to send, the browser's
  // own file (by name) and the range it was sliced to.
  "expect-upload": async (page, s) => {
    const r = await page.evaluate(
      (n) => {
        const rt = window.__rt;
        const id = rt.issued[n - 1];
        if (id === undefined) return { error: `effect occurrence ${n} was never issued (${rt.issued.length} issued)` };
        const e = rt.live.get(id);
        if (e === undefined) return { error: `effect occurrence ${n} is not pending (cancelled or done)` };
        if (e.req.op !== "upload") return { error: `effect occurrence ${n} is not an upload` };
        return { name: e.req.file.name, start: e.req.start, len: e.req.len, size: e.req.blob.size };
      },
      s.count,
    );
    if (r.error) throw new Error(r.error);
    if (r.name !== s.file || r.start !== s.start || r.len !== s.len || r.size !== s.len) {
      throw new Error(`upload ${s.count} sends ${JSON.stringify(r.name)} ${r.start}+${r.len} (a body of ${r.size} bytes), expected ${JSON.stringify(s.file)} ${s.start}+${s.len}`);
    }
  },
  "choose-files": (page, s, state) => chooseFiles(page, s, state),
  "drop-files": (page, s, state) => giveFiles(page, s, state, "drop"),
  "paste-files": (page, s, state) => giveFiles(page, s, state, "paste"),
  "expect-files": async (page, s) => {
    const n = await page.evaluate(() => Number(window.__rt.x.metric(6)));
    if (n !== s.count) throw new Error(`expected ${s.count} live file handles, found ${n}`);
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
    if (state.holdingReports) throw new Error("a cross-document navigation cannot leave while reports are held");
    if (state.pointers.size) throw new Error("a cross-document navigation cannot leave while a pointer is down");
    // Any other navigation loads a new document: the app mounts afresh.
    return navigating(page, state, () => page.evaluate((url) => location.assign(url), s.text), { cross: true, href: s.text });
  },
  "set-time": async (page, s, state) => {
    const value = BigInt(s.at_ms);
    if (value < -(1n << 63n) || value > (1n << 63n) - 1n) throw new Error("set-time is outside I64");
    state.environment.now_ms = value.toString();
    await page.evaluate(value => { window.__env.now_ms = value; }, value.toString());
    await installEnvironment(page, state);
  },
  "advance-time": async (page, s, state) => {
    const duration = BigInt(s.ms);
    if (duration < 0n || duration > (1n << 64n) - 1n) throw new Error("advance-time duration is outside U64");
    const value = BigInt(state.environment.now_ms) + duration;
    if (value < -(1n << 63n) || value > (1n << 63n) - 1n) throw new Error("advance-time exceeds I64");
    state.environment.now_ms = value.toString();
    await page.evaluate(value => { window.__env.now_ms = value; }, value.toString());
    await installEnvironment(page, state);
  },
  "set-online": async (page, s, state) => {
    const online = s.text === "online";
    if (state.environment.online === online) return;
    state.environment.online = online;
    await installEnvironment(page, state);
    await page.evaluate((on) => {
      window.__env.online = on;
      window.dispatchEvent(new Event(on ? "online" : "offline"));
    }, online);
    return settle(page);
  },
  "set-visibility": async (page, s, state) => {
    const visible = s.text === "visible";
    if (state.environment.visible === visible) return;
    state.environment.visible = visible;
    await installEnvironment(page, state);
    await page.evaluate((vis) => {
      window.__env.visible = vis;
      document.dispatchEvent(new Event("visibilitychange"));
    }, visible);
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
  // The files the app saved: in manual mode the runtime logs each `SAVE`
  // with the Blob it would download, read back here as text.
  "expect-saved": async (page, s) => {
    const r = await page.evaluate(async (i) => {
      const log = window.__rt.saveLog;
      if (i < 1 || i > log.length) return { error: `the app saved ${log.length} files, so there is no save ${i}` };
      const e = log[i - 1];
      return { name: e.name, text: await e.blob.text() };
    }, s.index);
    if (r.error) throw new Error(r.error);
    if (r.name !== s.name || r.text !== s.text) throw new Error(`save ${s.index} was ${JSON.stringify(r.name)} holding ${JSON.stringify(r.text)}, expected ${JSON.stringify(s.name)} holding ${JSON.stringify(s.text)}`);
  },
  "expect-saves": async (page, s) => {
    const n = await page.evaluate(() => window.__rt.saveLog.length);
    if (n !== s.count) throw new Error(`the app saved ${n} files, expected ${s.count}`);
  },
};

// Assertions inspect a held frame without delivering it. An occurrence's
// target and pending request must be resolved only after earlier reports
// have reached the app, since a report may change either of them.
async function isOccurrence(page, step) {
  if (step.op.startsWith("expect-")) return false;
  if (["hold-reports", "release-reports", "mark-metrics", "stub-http", "stub-http-reject", "set-online", "set-visibility", "scroll", "report-size", "report-seen", "set-media", "storage-elsewhere", "storage-elsewhere-removed", "storage-elsewhere-cleared"].includes(step.op)) return false;
  if (step.op === "emit-port") return page.evaluate((port) => window.__rt.portDecls.get(port)?.delivery !== 2, step.port);
  if (step.op === "pointer-move") return page.evaluate(({ loc, id }) => {
    const root = window.__rt.root;
    const capture = window.__pointerCaptures?.get(id);
    let element = capture?.element;
    if (!element?.isConnected || !element.hasPointerCapture(capture.actual)) element = window.__loc(loc);
    for (; element && element !== root; element = element.parentElement) {
      const handler = element.__h?.pointermove;
      if (handler) return (handler.policies & 8) === 0;
    }
    return true;
  }, { loc: step.loc, id: step.id });
  return true;
}

async function releaseReports(page) {
  await page.evaluate(() => window.__rt.releaseReports());
  return settle(page);
}

// One handler per setup form of the grammar (`Scm.setup_forms`).
const SETUP = {
  // The parser resolves these forms into spec.environment. Keeping their
  // entries here makes grammar coverage explicit without interpreting twice.
  "initial-location": () => {},
  "local-storage": () => {},
  "local-storage-unavailable": () => {},
  "session-storage": () => {},
  "session-storage-unavailable": () => {},
  "session-storage-full": out => { out.mount.manualSessionStorageFull = true; },
  "local-storage-full": out => { out.mount.manualLocalStorageFull = true; },
  "clipboard-denied": out => { out.mount.manualClipboardDenied = true; },
  "max-paste-bytes": (out, step) => { out.mount.maxPasteBytes = step.count; },
  "initial-online": () => {},
  "initial-visibility": () => {},
  "initial-media": () => {},
  "initial-time": () => {},
  seed: () => {},
  languages: () => {},
  "time-zone": () => {},
  file: (out, s) => {
    if (out.files.has(s.name)) throw new Error(`file ${JSON.stringify(s.name)} is declared twice`);
    out.files.set(s.name, { type: s.type, text: s.text, count: s.count });
  },
  // The runtime's maxOutputBytes mount option.
  "max-output-bytes": (out, s) => {
    out.mount.maxOutputBytes = s.count;
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
  const problems = [...diff("step", g.steps, Object.keys(STEPS)), ...diff("setup", g.setup, Object.keys(SETUP)), ...diff("environment section", g.environment_sections, Object.keys(ENVIRONMENT_SECTIONS))];
  for (const p of problems) console.error(p);
  console.error(problems.length === 0 ? `== replay.mjs handles all ${g.steps.length} step and ${g.setup.length} setup forms` : `== ${problems.length} grammar mismatches`);
  process.exit(problems.length === 0 ? 0 : 1);
}

function setupOf(spec) {
  const out = { environment: spec.environment, files: new Map(), mount: {} };
  if (!out.environment) throw new Error("the parser did not supply the resolved environment");
  for (const s of spec.setup) {
    const h = SETUP[s.op];
    if (h === undefined) throw new Error(`setup ${s.op} has no handler in this runner`);
    h(out, s);
  }
  return out;
}

// Each parser section has one document applier. Storage is seeded on the
// first document only: the browser preserves the app's subsequent writes and
// removals across navigation without any marker in app-visible storage.
const ENVIRONMENT_SECTIONS = {
  location: () => {},
  "local-storage": (env, seed) => {
    if (seed) for (const [key, value] of env.storage) localStorage.setItem(key, value);
    if (!env.storage_available) {
      window.__localStorage = localStorage;
      Object.defineProperty(window, "localStorage", {
        get: () => { throw new DOMException("The operation is insecure.", "SecurityError"); },
        configurable: true,
      });
    }
  },
  "session-storage": (env, seed) => {
    if (seed) for (const [key, value] of env.session) sessionStorage.setItem(key, value);
    if (!env.session_available) {
      window.__sessionStorage = sessionStorage;
      Object.defineProperty(window, "sessionStorage", {
        get: () => { throw new DOMException("The operation is insecure.", "SecurityError"); },
        configurable: true,
      });
    }
  },
  connectivity: (env) => { window.__mountOptions.environment.online = () => window.__env.online; },
  visibility: (env) => { window.__mountOptions.environment.visible = () => window.__env.visible; },
  time: () => { window.__mountOptions.environment.now = () => BigInt(window.__env.now_ms); },
  seed: () => {
    window.__mountOptions.environment.seed = () => {
      let value = BigInt(window.__env.seed);
      if (value < 0n || value >= (1n << 128n)) throw new Error("the spec seed is exhausted at the next document");
      const bytes = new Uint8Array(16);
      for (let index = 0; index < bytes.length; index++) { bytes[index] = Number(value & 255n); value >>= 8n; }
      return bytes;
    };
  },
  languages: () => { window.__mountOptions.environment.languages = () => window.__env.languages; },
  "time-zone": () => {
    window.__mountOptions.environment.timeZone = () => {
      const zone = window.__env.zone;
      return { name: zone.name, from_ms: BigInt(zone.from_ms), until_ms: BigInt(zone.until_ms), offsets: zone.offsets.map(offset => ({ from_ms: BigInt(offset.from_ms), minutes: offset.minutes })) };
    };
  },
  media: (env) => {
    window.__mediaQueries = new Map();
    window.__mountOptions.environment.matchMedia = (query) => {
      let current = window.__mediaQueries.get(query);
      if (!current) {
        current = new EventTarget();
        current.matches = new Map(window.__env.media).get(query) ?? false;
        window.__mediaQueries.set(query, current);
      }
      return current;
    };
  },
};

async function installEnvironment(page, state, seed = false) {
  if (state.environmentScript !== null) await page.send("Page.removeScriptToEvaluateOnNewDocument", { identifier: state.environmentScript });
  const install = (environment, mount, seed, appliers) => {
    window.__env = environment;
    window.__mountOptions = { ...mount, environment: {} };
    window.__manualFx = true;
    for (const source of appliers) eval(`(${source})`)(environment, seed);
    for (const [name, full] of [["localStorage", mount.manualLocalStorageFull], ["sessionStorage", mount.manualSessionStorageFull]]) {
      if (!full) continue;
      const store = name === "localStorage" ? (window.__localStorage ?? localStorage) : (window.__sessionStorage ?? sessionStorage);
      // Seed reads the existing store before its writes become over quota.
      Object.defineProperty(store, "setItem", { value: () => { throw new DOMException("The quota has been exceeded.", "QuotaExceededError"); }, configurable: true });
    }
  };
  // Future documents get the next seed before their app starts. Keep the
  // current document unchanged; an exhausted future seed fails its reader
  // at mount rather than falling back to real entropy or wrapping to zero.
  const environment = { ...state.environment, seed: seed ? state.environment.seed : (BigInt(state.environment.seed) + 1n).toString() };
  const args = [environment, state.mount, seed, Object.values(ENVIRONMENT_SECTIONS).map(String)];
  const result = await page.send("Page.addScriptToEvaluateOnNewDocument", { source: `(${install})(...${JSON.stringify(args)})` });
  state.environmentScript = result.identifier;
}

// Installed in every document before the app loads: the document token, the
// attribute reader, the navigation a click's default action starts, and the
// page-side half of `expect-updates` (per node, the attribute and text
// mutations after the callback that inserted it).
function install(attrOfSource) {
  // Its OS-dependent timing is outside the portable grammar, as hover is.
  window.addEventListener("contextmenu", (event) => { event.preventDefault(); event.stopImmediatePropagation(); }, true);
  for (const type of ["gotpointercapture", "lostpointercapture"]) window.addEventListener(type, (event) => event.stopImmediatePropagation(), true);
  // Hover depends on layout, outside the native oracle. Exclude it from
  // every replay, including boundary events Chrome raises after a DOM change.
  for (const type of ["pointerover", "pointerout", "pointerenter", "pointerleave", "mouseover", "mouseout", "mouseenter", "mouseleave"]) {
    window.addEventListener(type, (e) => e.stopImmediatePropagation(), true);
  }
  window.__doc = `${Date.now()}-${Math.random()}`;
  window.__attrOf = eval(`(${attrOfSource})`);
  window.__nav = null;
  window.__reportsHeld = false;
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
    if (!same && (window.__reportsHeld || window.__pointersActive)) e.preventDefault();
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
  "environment.mjs": path.join(path.dirname(opts.runtime), "environment.mjs"),
  "app.wasm": opts.wasm,
};
const types = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript", ".wasm": "application/wasm" };
// Files are served by basename under any path (apps mount under a base path,
// e.g. /roc-signals/examples/conduit/), and a directory as index.html.
const server = http.createServer((req, res) => {
  const u = new URL(req.url, "http://x");
  if (u.pathname === "/storage-driver.html") {
    res.writeHead(200, { "content-type": "text/html" }); res.end("<!doctype html><title>storage driver</title>"); return;
  }
  const f = u.pathname.endsWith("/") || path.extname(u.pathname) === "" ? files["index.html"] : files[path.basename(u.pathname)];
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
  const context = await browser.createBrowserContext();
  const page = await context.newPage();
  const t0 = Date.now();
  let failed = null;
  let i = 0;
  try {
    const setup = setupOf(spec);
    await page.evaluateOnNewDocument(fs.readFileSync(files["locate.js"], "utf8"));
    const state = { context, stub: null, mark: null, doc: null, loads: 0, files: setup.files, environment: setup.environment, mount: setup.mount, environmentScript: null, holdingReports: false, pointers: new Map(), activationTable: spec.activation_table, keyTable: spec.key_table, keyDefaults: spec.unmodelled_key_defaults, keyControlTypes: spec.key_control_types };
    if (!Array.isArray(state.activationTable) || state.activationTable.length !== Object.keys(STEPS).length ||
      new Set(state.activationTable.map((row) => row.op)).size !== state.activationTable.length ||
      state.activationTable.some((row) => !Object.hasOwn(STEPS, row.op))) throw new Error("parser activation table does not name every replay step exactly once");
    state.leave = null;
    state.dialogError = null;
    page.conn.on(page.sessionId, "Page.javascriptDialogOpening", async event => {
      const intent = state.leave;
      if (event.type !== "beforeunload" || intent === null) {
        state.dialogError = `${event.type} dialog opened outside leave-page; use leave-page for a guarded document`;
        await page.send("Page.handleJavaScriptDialog", { accept: false });
        return;
      }
      intent.dialogs += 1;
      if (intent.outcome === "unasked") state.dialogError = "leave-page unasked opened a beforeunload dialog";
      await page.send("Page.handleJavaScriptDialog", { accept: intent.outcome === "leave" });
      intent.handled = true;
    });
    await installEnvironment(page, state, true);
    await page.evaluateOnNewDocument(install, attrOf.toString());
    await page.goto(`http://127.0.0.1:${port}${setup.environment.url}`);
    page.conn.on(page.sessionId, "Page.loadEventFired", () => {
      state.loads += 1;
    });
    await mounted(page);
    await installEnvironment(page, state);
    state.doc = await docToken(page);
    for (; i < spec.steps.length; i += 1) {
      const s = spec.steps[i];
      const h = STEPS[s.op];
      if (h === undefined) throw new Error(`${s.op} has no handler in this runner`);
      if (await isOccurrence(page, s)) await releaseReports(page);
      await h(page, s, state);
      if (state.dialogError) throw new Error(state.dialogError);
      if (!state.holdingReports) await releaseReports(page);
      if (pageErrors(page).length) throw new Error(`page error: ${pageErrors(page).join("; ")}`);
    }
    if (state.holdingReports) throw new Error("the spec ended while reports were held");
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
  await context.close();
}
await browser.close();
server.close();
const count = (st) => results.filter((r) => r.status === st).length;
console.error(`== ${count("passed")} passed, ${count("failed")} failed`);
if (opts.out) fs.writeFileSync(opts.out, JSON.stringify({ results }, null, 1));
process.exit(count("failed") === 0 && results.length > 0 ? 0 : 1);
