// Controlled top-layer properties and reference commands against raw protocol
// batches. The pure engine and native oracle are checked independently.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";

const options = parseArgs(process.argv.slice(2));
const files = runtimeFiles(options.runtime);
const server = http.createServer((request, response) => {
  const name = path.basename(new URL(request.url, "http://x").pathname);
  if (!name) { response.writeHead(200, { "content-type": "text/html" }); response.end("<!doctype html>"); return; }
  if (name === "observation-runtime.mjs") {
    response.writeHead(200, { "content-type": "text/javascript" });
    response.end(`${fs.readFileSync(files["runtime.mjs"], "utf8")}\nexport { ScrollHistory };`);
    return;
  }
  if (!files[name]) { response.writeHead(404); response.end(); return; }
  response.writeHead(200, { "content-type": "text/javascript" }); response.end(fs.readFileSync(files[name]));
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const browser = await launch({ executablePath: options.chrome });
let failures = 0;
const check = (name, actual, expected) => {
  const pass = JSON.stringify(actual) === JSON.stringify(expected);
  if (!pass) failures += 1;
  console.log(`${pass ? "ok  " : "FAIL"} ${name}${pass ? "" : `: got ${JSON.stringify(actual)}, expected ${JSON.stringify(expected)}`}`);
};
try {
  const page = await browser.newPage();
  await page.goto(`http://127.0.0.1:${server.address().port}/`);
  await page.evaluate(async () => {
    const { RocEngineRuntime } = await import("/runtime.mjs");
    const encoder = new TextEncoder();
    const join = (...parts) => { const out = new Uint8Array(parts.reduce((n, part) => n + part.length, 0)); let at = 0; for (const part of parts) { out.set(part, at); at += part.length; } return out; };
    const u32 = (n) => { const out = new Uint8Array(4); new DataView(out.buffer).setUint32(0, n, true); return out; };
    const str = (s) => { const bytes = encoder.encode(s); return join(u32(bytes.length), bytes); };
    window.__dialogFixture = () => {
      const root = document.createElement("main"); document.body.append(root);
      const memory = new WebAssembly.Memory({ initial: 2 }); let length = 0;
      const exports = { memory, cmd_ptr: () => 0, cmd_len: () => length, files_released: () => 0, metric: () => 0n, work_len: () => 0, fault: () => 0, drop: () => {} };
      const rt = new RocEngineRuntime(exports, root, { manualEffects: true });
      rt.controlListeners(); rt.nativeEventListeners(); rt.documentKeyListeners(); rt.listen("submit");
      const calls = []; rt.deliver = (node, handler, bytes) => calls.push({ node, handler, payload: [...bytes] });
      const raw = (...parts) => { const bytes = join(...parts); new Uint8Array(memory.buffer).set(bytes); length = bytes.length; rt.busy = true; try { rt.apply(); } finally { rt.busy = false; length = 0; } rt.drainQueue(); };
      const elem = (id, parent, tag) => join([8], u32(id), u32(parent), u32(0), str(tag));
      const attr = (id, name, value) => join([9], u32(id), str(name), [1], str(value));
      const prop = (id, kind, value) => join([21], u32(id), [kind], str(value));
      const listen = (id, handler, type, kind = 5, policies = 0) => join([11], u32(id), u32(handler), str(type), [kind], u32(policies));
      const ref = (id, mode, ...extra) => join([18, mode], u32(id), ...extra);
      const remove = (id) => join([5], u32(id));
      const end = () => { rt.unmount(); root.remove(); };
      return { rt, root, calls, raw, elem, attr, prop, listen, ref, remove, u32, join, end };
    };
    window.__waitDialogFixture = async (fixture) => {
      const start = performance.now();
      for (;;) {
        await new Promise((resolve) => setTimeout(resolve, 0));
        if (fixture.rt.nativeEventsReady()) return;
        if (performance.now() - start > 20000) throw new Error("timed out observing native dialog callbacks");
        await new Promise((resolve) => setTimeout(resolve, 0));
      }
    };
  });
  const initial = await page.evaluate(async () => {
    const f = __dialogFixture(); const { elem, prop, ref, listen } = f;
    f.raw(elem(1, 0, "button"), ref(1, 1));
    f.raw(elem(2, 0, "dialog"), prop(2, 6, "modal"), listen(2, 0, "close"), elem(3, 2, "button"));
    const shown = [f.rt.statics[2].open, f.rt.statics[2].matches(":modal"), document.activeElement === f.rt.statics[3]];
    f.raw(prop(2, 6, "hidden")); await __waitDialogFixture(f);
    const result = [shown, document.activeElement === f.rt.statics[1], f.calls]; f.end(); return result;
  });
  check("show waits for content; hide restores focus and carries Bool close", initial, [[true, true, true], true, [{ node: 2, handler: 0, payload: [0] }]]);
  const hidden = await page.evaluate(() => {
    const f = __dialogFixture(); const { elem, prop } = f;
    f.raw(elem(1, 0, "dialog")); const dialog = f.rt.statics[1]; let shows = 0;
    const original = dialog.showModal; dialog.showModal = function () { shows += 1; return original.call(this); };
    f.raw(prop(1, 6, "modal"), prop(1, 6, "hidden"));
    const answer = [dialog.open, shows]; f.end(); return answer;
  });
  check("a later hide supersedes an earlier deferred show", hidden, [false, 0]);
  const identity = await page.evaluate(() => {
    const f = __dialogFixture(); const { elem, prop, remove } = f;
    f.raw(elem(1, 0, "dialog"), prop(1, 6, "modal"), remove(1), elem(1, 0, "dialog"));
    const result = [f.rt.statics[1].open, f.rt.root.querySelectorAll(":modal").length]; f.end(); return result;
  });
  check("a removed show's node id cannot alias its replacement", identity, [false, 0]);
  const ordered = await page.evaluate(async () => {
    const f = __dialogFixture(); const { elem, prop, ref, remove } = f;
    f.raw(elem(1, 0, "button"), elem(2, 0, "button"), ref(1, 1), elem(3, 0, "dialog"), prop(3, 6, "open"), elem(4, 3, "button"), ref(2, 1));
    const showThenFocus = document.activeElement === f.rt.statics[2];
    f.rt.statics[4].focus(); f.raw(prop(3, 6, "hidden"), remove(4)); await __waitDialogFixture(f);
    const hideBeforeRemove = document.activeElement === f.rt.statics[1];
    const result = [showThenFocus, hideBeforeRemove]; f.end(); return result;
  });
  check("show/ref stream order and hide-before-content-remove preserve focus", ordered, [true, true]);
  const stale = await page.evaluate(async () => {
    const f = __dialogFixture(); const { elem, prop, listen } = f;
    f.raw(elem(1, 0, "dialog"), listen(1, 7, "close"), prop(1, 6, "modal"));
    f.raw(prop(1, 6, "hidden"), prop(1, 6, "modal")); await __waitDialogFixture(f);
    const result = f.calls; f.end(); return result;
  });
  check("a delayed close payload reads the reopened live state", stale, [{ node: 1, handler: 7, payload: [1] }]);
  const toggleOrder = await page.evaluate(async () => {
    const f = __dialogFixture();
    f.raw(f.elem(1, 0, "dialog"), f.listen(1, 1, "close"), f.listen(1, 2, "toggle", 1), f.prop(1, 6, "modal"));
    f.raw(f.prop(1, 6, "hidden"), f.prop(1, 6, "modal")); await __waitDialogFixture(f);
    const result = f.calls.sort((a, b) => a.handler - b.handler); f.end(); return result;
  });
  check("coalesced native callbacks both read the reopened live state", toggleOrder, [{ node: 1, handler: 1, payload: [1] }, { node: 1, handler: 2, payload: [] }]);
  const popovers = await page.evaluate(async () => {
    const f = __dialogFixture(); const { elem, attr, prop, listen } = f;
    f.raw(elem(1, 0, "div"), attr(1, "popover", "auto"), listen(1, 1, "toggle"), prop(1, 7, "true"), elem(2, 0, "div"), attr(2, "popover", "auto"), listen(2, 2, "toggle"), prop(2, 7, "true"));
    await __waitDialogFixture(f); const initial = f.calls.slice(); f.calls.length = 0;
    f.raw(elem(3, 0, "dialog"), prop(3, 6, "modal")); await __waitDialogFixture(f);
    const result = [initial, f.calls]; f.end(); return result;
  });
  check("auto-popover replacement and a modal's implicit hide use actual toggle", popovers, [[{ node: 1, handler: 1, payload: [0] }, { node: 2, handler: 2, payload: [1] }], [{ node: 2, handler: 2, payload: [0] }]]);
  const scrolls = await page.evaluate(() => {
    const f = __dialogFixture(); const { elem, ref, u32 } = f;
    f.raw(elem(1, 0, "div")); const target = f.rt.statics[1]; const calls = [];
    target.scrollIntoView = (options) => calls.push(["into", options]); target.scrollTo = (options) => calls.push(["to", options]);
    Object.defineProperty(target, "scrollHeight", { value: 700 }); Object.defineProperty(target, "scrollWidth", { value: 900 });
    f.raw(ref(1, 6, [1, 3, 2]), ref(1, 7, [2, 3], u32(42), [1]));
    const result = [calls, f.rt.scrollCount().toString(), f.rt.scrollRecord("1").target.deref() === target, f.rt.scrollRecord("2").kind]; f.end(); return result;
  });
  check("REF scroll bytes use named browser options and log weak identities", scrolls, [[["into", { block: "center", inline: "nearest", behavior: "smooth" }], ["to", { behavior: "instant", top: 700, left: 42 }]], "2", true, "to"]);
  const history = await page.evaluate(async () => {
    const { ScrollHistory } = await import("/observation-runtime.mjs"); const element = document.createElement("div");
    const log = new ScrollHistory(); for (let i = 0; i < 4097; i += 1) log.add(element, "to");
    let old; try { log.at(1n); old = "accepted"; } catch (error) { old = error.message; }
    const last = [log.total().toString(), log.at(2n).ordinal.toString(), log.at(4097n).target.deref() === element, log.records.length];
    const exhausted = new ScrollHistory(1n); exhausted.add(element, "to"); exhausted.add(element, "to");
    let overflow; try { exhausted.total(); overflow = "accepted"; } catch (error) { overflow = error.message; }
    return { old, last, overflow };
  });
  check("scroll observer retains newest4096 and reports ordinal exhaustion", history, { old: "scroll command 1 is outside retained scroll history (newest 4096)", last: ["4097", "2", true, 4096], overflow: "scroll history ordinal exhausted" });
  const exhaustedWork = await page.evaluate(async () => {
    const { ScrollHistory } = await import("/observation-runtime.mjs"); const f = __dialogFixture();
    f.rt.scrollLog = new ScrollHistory(1n); f.raw(f.elem(1, 0, "div")); let actual = 0;
    f.rt.statics[1].scrollTo = () => { actual += 1; };
    f.raw(f.ref(1, 7, [0, 0, 0]), f.ref(1, 7, [0, 0, 0]), f.ref(1, 7, [0, 0, 0]));
    let error; try { f.rt.scrollCount(); } catch (failure) { error = failure.message; }
    const answer = [actual, f.rt.poisoned, error]; f.end(); return answer;
  });
  check("exhausted scroll observation never suppresses work or poisons the app", exhaustedWork, [3, null, "scroll history ordinal exhausted"]);
  const callbacks = await page.evaluate(async () => {
    const f = __dialogFixture();
    f.raw(f.elem(1, 0, "div"), f.attr(1, "popover", "auto"), f.listen(1, 0, "toggle"), f.prop(1, 7, "true"));
    f.raw(f.prop(1, 7, "false"));
    await Promise.resolve(); const pending = !f.rt.nativeEventsReady();
    await __waitDialogFixture(f); const coalesced = f.calls;
    f.raw(f.elem(2, 0, "dialog"), f.prop(2, 6, "modal"), f.prop(2, 6, "hidden"), f.remove(2));
    await Promise.resolve(); const removedReady = f.rt.nativeEventsReady();
    const answer = [pending, coalesced, removedReady, f.rt.nativeTasks.size]; f.end(); return answer;
  });
  check("coalesced actual toggle is awaited and removal cannot resurrect callback observation", callbacks, [true, [{ node: 1, handler: 0, payload: [0] }], true, 0]);
  const modalOrder = await page.evaluate(async () => {
    const f = __dialogFixture();
    f.raw(f.elem(1, 0, "dialog"), f.elem(2, 0, "dialog"), f.prop(2, 6, "modal"), f.prop(1, 6, "modal"));
    const latest = f.rt.topModal() === f.rt.statics[1];
    f.raw(f.prop(1, 6, "hidden")); const closed = f.rt.topModal() === f.rt.statics[2];
    f.raw(f.remove(2)); await __waitDialogFixture(f);
    const result = [latest, closed, f.rt.topModal() === null, f.rt.nativeTasks.size]; f.end(); return result;
  });
  check("modal order follows actual show order and drops closed or removed targets", modalOrder, [true, true, true, 0]);
  const moved = await page.evaluate(async () => {
    const f = __dialogFixture(); f.raw(f.elem(1, 0, "dialog"), f.elem(2, 0, "div"), f.prop(1, 6, "modal"));
    f.raw(f.join([4], f.u32(1), f.u32(0))); const before = [f.rt.statics[1].open, f.rt.topModal() === null];
    f.raw(f.prop(1, 6, "modal")); await __waitDialogFixture(f);
    const result = [before, f.rt.statics[1].matches(":modal"), f.rt.topModal() === f.rt.statics[1]]; f.end(); return result;
  });
  check("MOVE drops modal state and a repeated shown property restores its observed order", moved, [[true, true], true, true]);
  const scrollIdentity = await page.evaluate(() => {
    const f = __dialogFixture(); f.raw(f.elem(1, 0, "div")); const old = f.rt.statics[1]; let performed = 0;
    old.scrollTo = () => { performed += 1; };
    for (let i = 0; i < 4097; i += 1) f.raw(f.ref(1, 7, [0, 0, 0]));
    f.raw(f.remove(1), f.elem(1, 0, "div")); const fresh = f.rt.statics[1];
    const result = [performed, f.rt.scrollCount().toString(), f.rt.scrollRecord("4097").target.deref() === old, f.rt.scrollRecord("4097").target.deref() !== fresh];
    f.end(); result.push(f.rt.scrollCount().toString()); return result;
  });
  check("every scroll executes beyond ring capacity and recycled ids keep distinct history", scrollIdentity, [4097, "4097", true, true, "0"]);
  const focusInPlace = await page.evaluate(() => {
    const f = __dialogFixture(); f.raw(f.elem(1, 0, "button")); const calls = [];
    f.rt.statics[1].focus = (options) => calls.push(options); f.raw(f.ref(1, 5)); f.end(); return calls;
  });
  check("FocusInPlace preserves browser scroll via preventScroll", focusInPlace, [{ preventScroll: true }]);
  const formDefault = await page.evaluate(() => {
    const f = __dialogFixture(); f.raw(f.elem(1, 0, "dialog"), f.prop(1, 6, "modal"), f.elem(2, 1, "form"), f.attr(2, "method", "dialog"));
    const event = new Event("submit", { bubbles: true, cancelable: true }); f.rt.statics[2].dispatchEvent(event);
    const answer = [event.defaultPrevented, f.rt.statics[1].open]; f.end(); return answer;
  });
  check("submit without an app handler is prevented from mount", formDefault, [true, true]);
  const cancelled = await page.evaluate(async () => {
    const f = __dialogFixture(); f.raw(f.elem(1, 0, "dialog"));
    f.rt.statics[1].addEventListener("beforetoggle", (event) => event.preventDefault());
    let failed = false; try { f.raw(f.prop(1, 6, "modal")); } catch (error) { failed = error.message.includes("dialog stayed hidden"); }
    await Promise.resolve(); const result = [failed, f.rt.nativeEventsReady()]; f.end(); return result;
  });
  check("external show cancellation fails execution without phantom pending callbacks", cancelled, [true, true]);
  const bad = await page.evaluate(() => {
    const results = [];
    for (const make of [f => f.ref(1, 8), f => f.ref(1, 6, [4, 0, 0]), f => f.ref(1, 7, [4, 0, 0]), f => f.prop(1, 6, "bad"), f => f.prop(1, 7, "true"), f => f.listen(1, 0, "close")]) {
      const f = __dialogFixture(); f.raw(f.elem(1, 0, "div")); try { f.raw(make(f)); results.push(false); } catch (_) { results.push(true); } f.end();
    }
    return results;
  });
  check("malformed reference/property/open-kind declarations are rejected", bad, [true, true, true, true, true, true]);
  for (const activated of [false, true]) {
    const context = await browser.createBrowserContext(); const inputPage = await context.newPage();
    await inputPage.goto(`http://127.0.0.1:${server.address().port}/`);
    await inputPage.evaluate(() => {
      document.body.innerHTML = '<dialog><button>First</button></dialog>'; window.__cancelFacts = [];
      const dialog = document.querySelector("dialog");
      dialog.addEventListener("cancel", (event) => { __cancelFacts.push(event.cancelable); event.preventDefault(); }); dialog.showModal();
    });
    if (activated) await inputPage.pressSpec({ key: "F2", code: "F2" }, [{ key: "F2", code: "F2", vk: 113 }]);
    await inputPage.pressSpec({ key: "Escape", code: "Escape" }, [{ key: "Escape", code: "Escape", vk: 27 }]);
    check(`Escape cancelability ${activated ? "after" : "without"} activation`, await inputPage.evaluate(() => [document.querySelector("dialog").open, __cancelFacts]), activated ? [true, [true]] : [false, [false]]);
    if (activated) {
      await inputPage.pressSpec({ key: "Escape", code: "Escape" }, [{ key: "Escape", code: "Escape", vk: 27 }]);
      check("repeated Escape ignores cancellation without another activation", await inputPage.evaluate(() => [document.querySelector("dialog").open, __cancelFacts]), [false, [true, false]]);
    }
    await context.close();
  }
  {
    const context = await browser.createBrowserContext(); const inputPage = await context.newPage();
    await inputPage.goto(`http://127.0.0.1:${server.address().port}/`);
    await inputPage.evaluate(() => { document.body.innerHTML = '<div popover="auto">Popover</div>'; document.querySelector("div").showPopover(); });
    const open = [];
    for (const type of ["mousePressed", "mouseReleased"]) {
      await inputPage.send("Input.dispatchMouseEvent", { type, x: 5, y: 400, button: "left", buttons: type === "mousePressed" ? 1 : 0, clickCount: 1 });
      open.push(await inputPage.evaluate(() => document.querySelector("div").matches(":popover-open")));
    }
    check("real outside pointer Down then Up light-dismisses only on Up", open, [true, false]); await context.close();
  }
  for (const action of ["insert", "delete", "mouse", "pen", "touch"]) {
    const context = await browser.createBrowserContext(); const inputPage = await context.newPage();
    await inputPage.goto(`http://127.0.0.1:${server.address().port}/`);
    await inputPage.evaluate(() => {
      document.body.innerHTML = '<input value="old"><div style="position:absolute;left:0;top:100px;width:200px;height:200px;touch-action:none">Input zone</div>';
      window.__activationFacts = [];
      document.addEventListener("pointerdown", (event) => { event.preventDefault(); __activationFacts.push([event.pointerType, navigator.userActivation.isActive]); }, true);
    });
    const before = await inputPage.evaluate(() => navigator.userActivation.hasBeenActive);
    let down = null; let consumed = null;
    if (action === "insert" || action === "delete") {
      await inputPage.evaluate(() => { const input = document.querySelector("input"); input.focus(); input.select(); });
      if (action === "insert") await inputPage.send("Input.insertText", { text: "new" });
      else await inputPage.evaluate(() => document.execCommand("delete"));
    } else if (action === "touch") {
      await inputPage.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [{ id: 0, x: 50, y: 150 }] });
      down = await inputPage.evaluate(() => navigator.userActivation.isActive);
      await inputPage.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] });
    } else {
      await inputPage.send("Input.dispatchMouseEvent", { type: "mousePressed", x: 50, y: 150, pointerType: action, button: "left", buttons: 1, clickCount: 1 });
      down = await inputPage.evaluate(() => navigator.userActivation.isActive);
      consumed = await inputPage.evaluate(() => { const popup = window.open("about:blank"); popup?.close(); return navigator.userActivation.isActive; });
      await inputPage.send("Input.dispatchMouseEvent", { type: "mouseReleased", x: 50, y: 150, pointerType: action, button: "left", buttons: 0, clickCount: 1 });
    }
    const after = await inputPage.evaluate(() => navigator.userActivation.isActive);
    check(`actual ${action} activation respects the performed input phase`, [before, down, after], [false, action === "touch" ? false : ["mouse", "pen"].includes(action) ? true : null, !["delete", "mouse", "pen"].includes(action)]);
    if (["mouse", "pen"].includes(action)) check(`${action} Up does not renew consumed activation`, consumed, false);
    await context.close();
  }
} finally { await browser.close(); await new Promise((resolve) => server.close(resolve)); }
if (failures) process.exit(1);
console.log("dialogs-browser: all pass");
