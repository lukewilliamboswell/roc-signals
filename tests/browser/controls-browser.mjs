// controls-browser.mjs --wasm APP.wasm --runtime runtime.mjs --chrome PATH -- controlled
// inputs, focus and containment in headless Chrome against tests/apps/controls (design.md "Controlled Inputs",
// "Error Containment").
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const opts = parseArgs(process.argv.slice(2));
const files = {
  "index.html": path.join(here, "index.html"),
  ...runtimeFiles(opts.runtime),
  "app.wasm": opts.wasm,
};
const server = http.createServer((req, res) => {
  const u = new URL(req.url, "http://x");
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
const base = `http://127.0.0.1:${server.address().port}/app/`;
const browser = await launch({ executablePath: opts.chrome });
let failures = 0;
const check = (name, got, want) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  if (!ok) failures += 1;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok ? "" : `: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`}`);
};
async function open() {
  const ctx = await browser.createBrowserContext();
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => {
    if (m.type() === "error") errors.push(m.text());
  });
  await page.goto(base);
  await page.waitForFunction("window.__ready || window.__error");
  return { page, ctx, errors };
}
const input = (page, label) => page.$(`[aria-label="${label}"]`);
const val = (page, label) => page.$eval(`[aria-label="${label}"]`, (e) => [e.value, e.selectionStart, e.selectionEnd]);
const text = (page, id) => page.$eval(`[data-testid="${id}"]`, (e) => e.textContent);

{
  const { page, ctx } = await open();
  // 1. Typing in the middle of existing text keeps the caret.
  const plain = await input(page, "Plain");
  await plain.focus();
  await page.evaluate(() => document.querySelector('[aria-label="Plain"]').setSelectionRange(5, 5));
  await page.keyboard.type("XYZ");
  check("typing mid-text: value and caret preserved", await val(page, "Plain"), ["helloXYZ world", 8, 8]);
  check("engine state follows", await text(page, "state"), "helloXYZ world|");
  await page.keyboard.press("ArrowLeft");
  await page.keyboard.press("ArrowLeft");
  await page.keyboard.press("Backspace");
  check("deleting mid-text keeps the caret", await val(page, "Plain"), ["helloYZ world", 5, 5]);
  // A selection survives an equal echo.
  await page.evaluate(() => document.querySelector('[aria-label="Plain"]').setSelectionRange(0, 5));
  await page.keyboard.type("Hi");
  check("replacing a selection keeps the caret", await val(page, "Plain"), ["HiYZ world", 2, 2]);

  // 2. A differing engine value is deferred while focused, applied on blur.
  const upper = await input(page, "Upper");
  await upper.focus();
  await page.keyboard.type("ab");
  check("differing value deferred while focused", [await val(page, "Upper"), await text(page, "state")], [["ab", 2, 2], "HiYZ world|AB"]);
  await plain.focus();
  check("deferred value applied on blur", (await val(page, "Upper"))[0], "AB");
  // A later input echo that matches the deferred value cancels it.
  await upper.focus();
  await page.keyboard.press("End");
  await page.keyboard.type("c");
  await page.keyboard.press("Backspace");
  await page.keyboard.down("Shift");
  await page.keyboard.type("C");
  await page.keyboard.up("Shift");
  check("matching echo leaves nothing deferred", await page.$eval('[aria-label="Upper"]', (e) => [e.value, e.__deferred === undefined]), ["ABC", true]);
  await plain.focus();
  check("value after blur", (await val(page, "Upper"))[0], "ABC");

  // 3. IME composition: never overwritten while composing.
  const cdp = await page.createCDPSession();
  await upper.focus();
  await page.keyboard.press("End");
  await cdp.send("Input.imeSetComposition", { text: "ka", selectionStart: 2, selectionEnd: 2 });
  check("during composition: typed text kept, engine upper-cased", [(await val(page, "Upper"))[0], await page.$eval('[aria-label="Upper"]', (e) => e.__composing === true), await text(page, "state")], ["ABCka", true, "HiYZ world|ABCKA"]);
  await cdp.send("Input.imeSetComposition", { text: "kan", selectionStart: 3, selectionEnd: 3 });
  check("composition update not overwritten", (await val(page, "Upper"))[0], "ABCkan");
  await cdp.send("Input.insertText", { text: "かん" });
  check("composition committed, still focused: equal echo, nothing deferred", [await val(page, "Upper"), await page.$eval('[aria-label="Upper"]', (e) => [e.__composing, e.__deferred === undefined])], [["ABCかん", 5, 5], [false, true]]);
  await plain.focus();
  check("after blur", (await val(page, "Upper"))[0], "ABCかん");
  await ctx.close();
}
{
  // 4. Focus commands and focus/blur events.
  const { page, ctx } = await open();
  const active = () => page.evaluate(() => document.activeElement.getAttribute("aria-label") ?? document.activeElement.tagName);
  const clickButton = (name) => page.evaluate((n) => [...document.querySelectorAll("button")].find((b) => b.textContent === n).click(), name);
  await clickButton("Focus upper");
  check("Focus command focuses the referenced input", await active(), "Upper");
  await clickButton("Select plain");
  check("SelectText focuses and selects", [await active(), await val(page, "Plain")], ["Plain", ["hello world", 0, 11]]);
  check("focus event delivered with the value payload", (await text(page, "log")).split("|").includes("focus:hello world"), true);
  await clickButton("Blur plain");
  check("Blur command blurs it; blur event delivered", [await active() !== "Plain", (await text(page, "log")).split("|").includes("blur:hello world")], [true, true]);
  await clickButton("Focus missing");
  check("missing reference: no focus change, no error", await active() !== "Plain", true);
  await ctx.close();
}
{
  // 5. Containment: a contract error poisons the instance; it is reported,
  // refuses further work without re-entering Wasm, keeps the last DOM, and a
  // fresh instance recovers.
  const { page, ctx, errors } = await open();
  const clickButton = (name) => page.evaluate((n) => [...document.querySelectorAll("button")].find((b) => b.textContent === n).click(), name);
  await page.evaluate(() => {
    window.__faults = [];
    window.__rt.onFault = (f) => window.__faults.push(f);
  });
  await clickButton("Add row");
  await clickButton("Add row");
  check("rows render", await text(page, "rows"), "r0r1");
  await clickButton("Duplicate row");
  const f = await page.evaluate(() => window.__faults);
  check("one fault reported with class and construction-site path", [f.length, f[0] && f[0].class, f[0] && /^contract: duplicate key "r0" in each at site \/\d/.test(f[0].message)], [1, "contract", true]);
  check("host reports the poisoned class; staged commands discarded", await page.evaluate(() => [window.__rt.x.fault(), window.__rt.x.cmd_len()]), [1, 0]);
  check("last committed DOM kept as fallback", await text(page, "rows"), "r0r1");
  const before = await text(page, "state");
  await clickButton("Add row");
  await (await input(page, "Plain")).type("zz");
  await page.evaluate(() => window.__rt.dispatch(1, 0, ""));
  check("listeners detached; later events and direct dispatch refused", [await text(page, "rows"), await text(page, "state"), await page.evaluate(() => [window.__rt.listening.size, window.__rt.refused])], ["r0r1", before, [0, 1]]);
  const reentry = await page.evaluate(() => {
    try {
      window.__rt.x.event(1, 0);
      return "entered";
    } catch (e) {
      return "trapped";
    }
  });
  check("the poisoned host itself refuses engine entry", reentry, "trapped");
  check("fault printed to the console", errors.some((e) => e.includes("roc engine fault [contract]")), true);
  await page.evaluate(() => window.__rt.recover());
  check("recover(): fresh instance, initial state", [await text(page, "rows"), (await val(page, "Plain"))[0], await page.evaluate(() => window.__rt.x.fault())], ["", "hello world", 0]);
  await clickButton("Add row");
  check("recovered instance handles events", await text(page, "rows"), "r0");
  await ctx.close();
}
for (const [button, where] of [
  ["Two handlers", ""],
  ["Two row handlers", " in the row template of an each"],
]) {
  // 6. Two handlers for one event on one element: a contract error at
  // mount that names the event, the element and the site, never a second
  // listener silently dropped.
  const { page, ctx, errors } = await open();
  const clickButton = (name) => page.evaluate((n) => [...document.querySelectorAll("button")].find((b) => b.textContent === n).click(), name);
  await page.evaluate(() => {
    window.__faults = [];
    window.__rt.onFault = (f) => window.__faults.push(f);
  });
  await clickButton(button);
  const f = await page.evaluate(() => window.__faults);
  const message = new RegExp(`^contract: two handlers for the "click" event on one <button>${where} at site /[\\d/]+: an element takes one handler per event; run both from one with Handler\\.also$`);
  check(`${button}: one contract fault naming the event, the element and the site`, [f.length, f[0] && f[0].class, f[0] && message.test(f[0].message)], [1, "contract", true]);
  check(`${button}: nothing of the faulty turn is applied`, await page.evaluate(() => [...document.querySelectorAll("button")].some((b) => b.textContent.startsWith("Twice"))), false);
  check(`${button}: the fault reaches the console`, errors.some((e) => e.includes("roc engine fault [contract]")), true);
  await ctx.close();
}
{
  const { page, ctx } = await open();
  const button = (name) => page.evaluate((n) => [...document.querySelectorAll("button")].find((b) => b.textContent === n).click(), name);
  const active = () => page.evaluate(() => document.activeElement.getAttribute("aria-label"));
  await page.evaluate(() => { window.__rowA = document.querySelector('[aria-label="Row a"]'); });
  await button("Focus row a");
  check("row reference focuses its element", await active(), "Row a");
  await button("Reverse reference rows");
  await button("Focus row a");
  check("a keyed reorder keeps the focused node and its reference", [await active(), await page.evaluate(() => window.__rowA === document.querySelector('[aria-label="Row a"]'))], ["Row a", true]);
  await page.evaluate(() => document.querySelector('[aria-label="Row b"]').click());
  check("a referenced row still routes its own click", await text(page, "reference-log"), "b");
  await button("Remove row a");
  const staleBefore = await page.evaluate(() => Number(window.__rt.workRecord().counters[34]));
  await button("Focus row a");
  check("a disposed row reference is stale", await page.evaluate((n) => Number(window.__rt.workRecord().counters[34]) - n, staleBefore), 1);
  await button("Restore reference rows");
  await button("Focus row a");
  check("a fresh row may reuse its disposed reference", await active(), "Row a");
  await button("Use selected reference");
  await button("Focus current row");
  check("the selected row holds a shared command address", await active(), "Row a");
  await button("Select row b");
  await button("Focus current row");
  check("a reference can move between surviving rows in one turn", [await active(), await page.evaluate(() => window.__rt.poisoned)], ["Row b", null]);
  await button("Clear reference names");
  const unnamedBefore = await page.evaluate(() => Number(window.__rt.workRecord().counters[34]));
  await button("Focus current row");
  await button("Focus empty name");
  check("empty names hold no references and never collide", [await active(), await page.evaluate((n) => Number(window.__rt.workRecord().counters[34]) - n, unnamedBefore), await page.evaluate(() => window.__rt.poisoned)], ["Row b", 2, null]);
  await ctx.close();
}
{
  const { page, ctx } = await open();
  await page.evaluate(() => [...document.querySelectorAll("button")].find((b) => b.textContent === "Duplicate references").click());
  const got = await page.evaluate(() => window.__rt.poisoned);
  check("duplicate reference names fail with both construction sites", [got?.class, got?.message], ["contract", 'contract: duplicate reference "duplicate" at sites /0/0/1/0 and /0/0/1/1']);
  await ctx.close();
}
{
  const { page, ctx } = await open();
  const before = await page.evaluate(() => Number(window.__rt.workRecord().counters[30]));
  await page.evaluate(() => [...document.querySelectorAll("button")].find((b) => b.textContent === "Start focus loop").click());
  check("an app's focus feedback loop poisons after its initiating turn and 4096 queued turns", await page.evaluate((n) => [window.__rt.poisoned?.class, Number(window.__rt.workRecord().counters[30]) - n, window.__rt.listening.size], before), ["resource_limit", 4097, 0]);
  await ctx.close();
}
{
  // Root delegation follows the actual event's bubbles flag, including
  // two occurrences of one type with different flags (cancel).
  const { page, ctx } = await open();
  const got = await page.evaluate(async () => {
    const { RocEngineRuntime } = await import("./runtime.mjs");
    const root = document.createElement("div");
    document.body.append(root);
    const parent = document.createElement("div");
    const target = document.createElement("div");
    root.append(parent);
    parent.append(target);
    parent.__rn = 101;
    parent.__h = { close: { h: 1, kind: 1, policies: 0 }, scroll: { h: 2, kind: 1, policies: 0 }, cancel: { h: 3, kind: 1, policies: 0 } };
    const rt = new RocEngineRuntime({}, root);
    const calls = [];
    rt.deliver = (node, handler) => calls.push([node, handler]);
    for (const type of ["close", "scroll", "cancel"]) rt.listen(type);
    target.__h = { close: { h: 4, kind: 1, policies: 0 }, scroll: { h: 5, kind: 1, policies: 0 } };
    target.dispatchEvent(new Event("close"));
    target.dispatchEvent(new Event("scroll"));
    target.__h = {};
    target.dispatchEvent(new Event("close"));
    target.dispatchEvent(new Event("scroll"));
    target.dispatchEvent(new Event("cancel", { bubbles: true }));
    target.dispatchEvent(new Event("cancel"));
    parent.__h.drop = { h: 8, kind: 2, policies: 0 };
    parent.__h.dragover = { h: 6, kind: 1, policies: 0 };
    rt.listen("drop");
    rt.listen("dragover");
    const over = new Event("dragover", { bubbles: true, cancelable: true });
    target.dispatchEvent(over);
    const dropAllows = over.defaultPrevented;
    rt.contain(new Error("fixture done"), "executor");
    target.__h = { close: { h: 4, kind: 1, policies: 0 } };
    target.dispatchEvent(new Event("close"));
    root.remove();
    return [calls, dropAllows, rt.listening.size];
  });
  check("non-bubbling events reach only their target; bubbling cancel and explicit dragover reach an ancestor once, alongside the file-drop default policy", got, [[[101, 4], [101, 5], [101, 3], [101, 6]], true, 0]);
  await ctx.close();
}
{
  // A reference hole's id is an address for commands, never an event
  // route. Removing or clearing its row must release that address too.
  const { page, ctx } = await open();
  const got = await page.evaluate(async () => {
    const { RocEngineRuntime } = await import("./runtime.mjs");
    const root = document.createElement("div");
    document.body.append(root);
    const bytes = [];
    const byte = (n) => bytes.push(n);
    const word = (n) => bytes.push(n & 255, (n >>> 8) & 255, (n >>> 16) & 255, (n >>> 24) & 255);
    const str = (s) => { const b = new TextEncoder().encode(s); word(b.length); bytes.push(...b); };
    // <div><input/></div>, holes: reference and click on the input.
    const tpl = [];
    byte(1); str("div"); byte(0); byte(1);
    byte(1); str("input"); byte(0); byte(0);
    byte(2); byte(5); byte(1); byte(0);
    byte(3); byte(1); byte(0); byte(7); str("click"); byte(1); word(0);
    tpl.push(...bytes); bytes.length = 0;
    byte(7); word(1); word(tpl.length); bytes.push(...tpl);
    byte(1); word(10); word(0); word(0); word(1); word(11);
    let batch = Uint8Array.from(bytes);
    const memory = new WebAssembly.Memory({ initial: 1 });
    const x = { memory, cmd_ptr: () => 0, cmd_len: () => batch.length };
    const rt = new RocEngineRuntime(x, root);
    rt.statics[0] = root;
    rt.sites[1] = new Set();
    const calls = [];
    rt.deliver = (node, handler) => calls.push([node, handler]);
    const apply = () => { new Uint8Array(memory.buffer).set(batch); rt.applyBatch(); };
    apply();
    const input = rt.statics[11];
    input.dispatchEvent(new Event("click", { bubbles: true }));
    const addressed = input === root.firstChild.firstChild;
    batch = Uint8Array.from([5, 10, 0, 0, 0]); apply();
    const removed = rt.statics[11] === undefined;
    bytes.length = 0;
    byte(1); word(10); word(0); word(0); word(1); word(11);
    batch = Uint8Array.from(bytes); apply();
    batch = Uint8Array.from([6, 0, 0, 0, 0, 1, 0, 0, 0]); apply();
    const cleared = rt.statics[11] === undefined && root.childNodes.length === 0;
    // A static ancestor can remove a row without a separate row REMOVE.
    bytes.length = 0;
    byte(8); word(30); word(0); word(0); str("section");
    byte(8); word(31); word(30); word(0); str("div");
    byte(10); word(32); word(31); word(0); str("static child");
    byte(1); word(10); word(31); word(0); word(1); word(11);
    batch = Uint8Array.from(bytes); apply();
    batch = Uint8Array.from([5, 30, 0, 0, 0]); apply();
    const ancestor = [10, 11, 30, 31, 32].every((id) => rt.statics[id] === undefined) && rt.sites[1].size === 0;
    // Clearing an outer site must also forget a nested site's rows and
    // references, while leaving another live site alone.
    bytes.length = 0;
    byte(7); word(2); word(tpl.length); bytes.push(...tpl);
    byte(8); word(50); word(0); word(0); str("section");
    byte(1); word(10); word(50); word(0); word(1); word(11);
    byte(1); word(20); word(10); word(0); word(2); word(21);
    byte(8); word(40); word(0); word(0); str("section");
    byte(1); word(41); word(40); word(0); word(2); word(42);
    batch = Uint8Array.from(bytes); apply();
    batch = Uint8Array.from([6, 50, 0, 0, 0, 1, 0, 0, 0]); apply();
    const nested = [10, 11, 20, 21].every((id) => rt.statics[id] === undefined) && rt.sites[1].size === 0 && [...rt.sites[2]].join() === "41" && rt.statics[42].isConnected;
    rt.contain(new Error("fixture done"), "executor");
    root.remove();
    return [addressed, calls, removed, cleared, ancestor, nested];
  });
  check("reference INST operand addresses the element, preserves the row's event route, and is forgotten with its row", got, [true, [[10, 7]], true, true, true, true]);
  await ctx.close();
}
{
  const { page, ctx } = await open();
  const got = await page.evaluate(async () => {
    const { RocEngineRuntime, MAX_QUEUED } = await import("./runtime.mjs");
    const run = (limit) => {
      const root = document.createElement("div");
      const a = document.createElement("input");
      const b = document.createElement("input");
      root.append(a, b); document.body.append(root);
      a.__rn = 1; b.__rn = 2;
      a.__h = b.__h = { focus: { h: 0, kind: 1, policies: 0 } };
      const rt = new RocEngineRuntime({}, root);
      rt.listen("focus");
      let delivered = 0;
      rt.deliver = (node) => {
        delivered += 1;
        if (delivered < limit) (node === 1 ? b : a).focus();
      };
      // Begin with focus raised during a batch, as a FOCUS command does.
      rt.busy = true; a.focus(); rt.busy = false;
      rt.drainQueue();
      const result = [delivered, rt.poisoned?.class ?? null];
      if (!rt.poisoned) rt.contain(new Error("fixture done"), "executor");
      root.remove();
      return result;
    };
    return [run(MAX_QUEUED), run(Infinity)];
  });
  check("4096 chained focus turns may finish; a focus loop is contained before its 4097th turn", got, [[4096, null], [4096, "resource_limit"]]);
  await ctx.close();
}
{
  // Record real CDP input, the reference for the native click sequence.
  // Hover is recorded separately: specs suppress it because it depends on
  // layout, while these contract cases still prove the browser delivers it.
  const { page, ctx } = await open();
  await page.evaluate(() => {
    const panel = document.createElement("div");
    panel.style.cssText = "position:fixed;inset:0;background:white;z-index:99999";
    for (const name of ["a", "b", "prevented"]) {
      const input = document.createElement("input");
      input.id = `sequence-${name}`;
      input.style.cssText = "display:block;width:100px;height:30px;margin:20px";
      panel.append(input);
    }
    document.body.append(panel);
    window.__sequence = [];
    const types = ["pointerover", "pointerout", "pointerenter", "pointerleave", "mouseover", "mouseout", "mouseenter", "mouseleave", "pointermove", "mousemove", "pointerdown", "mousedown", "focusin", "pointerup", "mouseup", "click"];
    for (const type of types) panel.addEventListener(type, (e) => {
      if (e.target.id.startsWith("sequence-")) window.__sequence.push(e.type);
    }, true);
    document.getElementById("sequence-prevented").addEventListener("pointerdown", (e) => e.preventDefault());
  });
  const clickSequence = async (name) => {
    await page.evaluate(() => { window.__sequence = []; });
    await (await page.$(`#sequence-${name}`)).click();
    return page.evaluate(() => window.__sequence);
  };
  const first = await clickSequence("a");
  const other = await clickSequence("b");
  const same = await clickSequence("b");
  const prevented = await clickSequence("prevented");
  const isHover = (type) => /^(pointer|mouse)(over|out|enter|leave)$/.test(type);
  const press = ["pointermove", "mousemove", "pointerdown", "mousedown", "focusin", "pointerup", "mouseup", "click"];
  check("a click at a new element: pointer and mouse press with focus in order", first.filter((t) => !isHover(t)), press);
  check("clicking a different element: same press sequence", other.filter((t) => !isHover(t)), press);
  check("clicking the same point: move and press again, no focus change", same.filter((t) => !isHover(t)), press.filter((t) => t !== "focusin"));
  check("prevented pointerdown suppresses mouse press/release and focus, but still clicks", prevented.filter((t) => !isHover(t)), ["pointermove", "mousemove", "pointerdown", "pointerup", "click"]);
  check("hover boundary events occur on entry and travel but not a resting second click", [first.some(isHover), other.some(isHover), same.some(isHover)], [true, true, false]);
  await ctx.close();
}
{
  // The kind decoder runs after routing, and reports the owning site for
  // malformed bytes or an export that supplied the wrong payload kind.
  const { page, ctx } = await open();
  const got = await page.evaluate(async () => {
    const { pageImports } = await import("./runtime.mjs");
    const plain = document.querySelector('[aria-label="Plain"]');
    const module = window.__rt.module;
    const failures = [];
    for (const mode of ["utf8", "files"]) {
      const x = (await WebAssembly.instantiate(module, pageImports(module))).exports;
      x.boot_keys(); x.payload_reserve(0); x.init();
      const payload = mode === "utf8" ? [255] : [0, 0, 0, 0, 0, 0, 0, 0];
      if (mode === "files") x.files_stage(0);
      const ptr = x.payload_reserve(payload.length);
      new Uint8Array(x.memory.buffer, ptr, payload.length).set(payload);
      try {
        if (mode === "files") x.event_files(plain.__rn, plain.__h.input.h);
        else x.event(plain.__rn, plain.__h.input.h);
        failures.push([mode, "accepted"]);
      } catch (_) {
        failures.push([mode, x.fault(), new TextDecoder().decode(new Uint8Array(x.memory.buffer, x.err_ptr(), x.err_len())), x.cmd_len()]);
      }
    }
    return failures;
  });
  check("routed kind decoders reject malformed text and files sent to a text handler, naming the owning site", got, [
    ["utf8", 1, "contract: text event payload is not UTF-8 at site /0", 0],
    ["files", 1, "contract: event payload does not match text kind at site /0", 0],
  ]);
  await ctx.close();
}
{
  const { page, ctx } = await open();
  const got = await page.evaluate(() => {
    const rt = window.__rt;
    const checkbox = document.querySelector('[aria-label="Property check a"]');
    const rowId = checkbox.parentNode.__rn;
    const original = rt.applyBatch;
    let bytes;
    rt.applyBatch = function () {
      bytes = Array.from(new Uint8Array(this.x.memory.buffer, this.x.cmd_ptr(), this.x.cmd_len()));
      return original.call(this);
    };
    const click = (name) => [...document.querySelectorAll("button")].find((b) => b.textContent === name).click();
    click("Set row checks");
    const changed = bytes;
    click("Touch row metadata");
    const equal = bytes;
    rt.applyBatch = original;
    document.querySelector('[aria-label="Custom colon event"]').dispatchEvent(new Event("x:y", { bubbles: true }));
    const word = (n) => [n & 255, (n >>> 8) & 255, (n >>> 16) & 255, (n >>> 24) & 255];
    return {
      changed, expected: [22, ...word(rowId), 1, 4, 0, 0, 0, 116, 114, 117, 101],
      equal, checked: checkbox.checked, same: checkbox === document.querySelector('[aria-label="Property check a"]'),
      custom: document.querySelector('[data-testid="custom-event-log"]').textContent,
      attrs: [document.querySelector('[data-testid="ordinary-progress"]').getAttribute("value"), document.querySelector('[data-testid="ordinary-custom-value"]').getAttribute("value"), document.querySelector('[data-testid="ordinary-custom-value"]').value ?? null],
    };
  });
  check("producer emits the exact HPROP bytes for one row's checked property", got.changed, got.expected);
  check("equal row properties emit nothing and retain their DOM node", [got.equal, got.checked, got.same], [[], true, true]);
  check("a custom event type containing a colon reaches its declared handler", got.custom, "received");
  check("ordinary value attributes remain attributes outside the property rows", got.attrs, ["0.5", "attribute only", null]);
  await ctx.close();
}
for (const [button, expected] of [
  ["Retired prevent suffix", 'contract: retired event suffix in "click:prevent" at site /0/6/1; use on_with for policies or on_files for files'],
  ["Retired files suffix", 'contract: retired event suffix in "change:files" at site /0/6/1; use on_with for policies or on_files for files'],
  ["Duplicate click policies", 'contract: two handlers for the "click" event on one <button> at site /0/6/1: an element takes one handler per event; run both from one with Handler.also'],
  ["Duplicate change kinds", 'contract: two handlers for the "change" event on one <input> at site /0/6/1: an element takes one handler per event; run both from one with Handler.also'],
  ["Checked property on div", 'contract: property "checked" is not allowed on <div> at site /0/6/1'],
  ["Value attribute on input", 'contract: attribute "value" on <input> is claimed by a property at site /0/6/1; use prop or prop_s'],
  ["Duplicate value property", 'contract: property "value" is declared twice on <input> at site /0/6/1'],
]) {
  const { page, ctx } = await open();
  await page.evaluate((name) => [...document.querySelectorAll("button")].find((b) => b.textContent === name).click(), button);
  check(`${button}: exact mount diagnostic`, await page.evaluate(() => [window.__rt.poisoned?.class, window.__rt.poisoned?.message]), ["contract", expected]);
  await ctx.close();
}
for (const mode of ["initial", "changed"]) {
  const { page, ctx } = await open();
  const got = await page.evaluate((mode) => {
    const click = (name) => [...document.querySelectorAll("button")].find((b) => b.textContent === name).click();
    let node;
    if (mode === "changed") {
      node = document.querySelector('[aria-label="Dynamic file value"]').__id;
      click("Make value input a file");
      if (window.__rt.poisoned) return ["premature", window.__rt.poisoned.message];
      click("Write file value");
    } else {
      click("Value property on file input");
      node = [...document.querySelectorAll('input[type="file"]')].at(-1).__id;
    }
    return [window.__rt.poisoned?.class, window.__rt.poisoned?.message, `contract: value property on file input at node ${node}`];
  }, mode);
  check(`${mode} file-input value property: exact contract diagnostic from its current type`, got.slice(0, 2), ["contract", got[2]]);
  await ctx.close();
}
{
  // Independent wire fixtures cover declaration-driven dispatch and element
  // properties, including invalid producer bytes and contract containment.
  const { page, ctx } = await open();
  const got = await page.evaluate(async () => {
    const { RocEngineRuntime } = await import("./runtime.mjs");
    const harness = () => {
      const root = document.createElement("div"); document.body.append(root);
      const memory = new WebAssembly.Memory({ initial: 1 });
      let bytes = [];
      const x = { memory, cmd_ptr: () => 0, cmd_len: () => bytes.length, fault: () => 0 };
      const rt = new RocEngineRuntime(x, root);
      rt.statics[0] = root;
      const byte = (n) => bytes.push(n);
      const word = (n) => bytes.push(n & 255, (n >>> 8) & 255, (n >>> 16) & 255, (n >>> 24) & 255);
      const str = (s) => { const b = new TextEncoder().encode(s); word(b.length); bytes.push(...b); };
      const elem = (id, tag, parent = 0) => { byte(8); word(id); word(parent); word(0); str(tag); };
      const attr = (id, name, value, present = 1) => { byte(9); word(id); str(name); byte(present); if (present === 1) str(value); };
      const prop = (id, index, value) => { byte(21); word(id); byte(index); str(value); };
      const listen = (id, type, kind = 1, policies = 0) => { byte(11); word(id); word(7); str(type); byte(kind); word(policies); };
      const apply = () => { new Uint8Array(memory.buffer).set(bytes); rt.guard(() => rt.applyBatch()); bytes = []; };
      const template = (id, tag, property) => {
        const outer = bytes; bytes = [];
        byte(1); str(tag); byte(0); byte(0);
        byte(1); byte(6); byte(0); byte(property);
        const tpl = bytes; bytes = outer;
        byte(7); word(id); word(tpl.length); bytes.push(...tpl);
      };
      const inst = (id, parent, tpl, value) => { byte(1); word(id); word(parent); word(0); word(tpl); str(value); };
      const hprop = (id, hole, value) => { byte(22); word(id); byte(hole); str(value); };
      const attrTemplate = (id) => {
        const outer = bytes; bytes = [];
        byte(1); str("img"); byte(2); str("alt"); str(""); str("data-static"); str(""); byte(0);
        byte(1); byte(2); byte(0); str("aria-label");
        const tpl = bytes; bytes = outer;
        byte(7); word(id); word(tpl.length); bytes.push(...tpl);
      };
      const attrInst = (id, tpl, present, value = "") => { byte(1); word(id); word(0); word(0); word(tpl); byte(present); if (present === 1) str(value); };
      const hattr = (id, present, value = "") => { byte(3); word(id); byte(0); byte(present); if (present === 1) str(value); };
      const close = () => { if (!rt.poisoned) rt.contain(new Error("fixture done"), "executor"); root.remove(); };
      return { root, rt, byte, word, str, elem, attr, prop, listen, apply, template, inst, hprop, attrTemplate, attrInst, hattr, close };
    };
    if (!customElements.get("property-probe")) customElements.define("property-probe", class extends HTMLElement { value = "original"; });
    const h = harness();
    const calls = [];
    h.rt.deliver = (node, handler, payload) => calls.push([node, handler, payload]);
    h.elem(1, "input"); h.prop(1, 1, "hello");
    h.elem(2, "input"); h.attr(2, "type", "checkbox"); h.prop(2, 2, "true");
    h.elem(3, "property-probe"); h.attr(3, "value", "attribute");
    h.elem(4, "progress"); h.attr(4, "value", "0.5");
    h.listen(1, "x:y", 1, 3); h.listen(1, "close", 1, 2);
    h.elem(5, "select"); h.prop(5, 1, "b");
    h.template(1, "option", 1); h.inst(40, 5, 1, "b");
    h.template(2, "input", 2); h.inst(41, 0, 2, "true");
    h.apply();
    const state = [h.rt.statics[1].value, h.rt.statics[1].getAttribute("value"), h.rt.statics[2].checked, h.rt.statics[3].getAttribute("value"), h.rt.statics[3].value, h.rt.statics[4].getAttribute("value"), h.rt.statics[5].value, h.rt.statics[41].checked];
    h.hprop(41, 0, "false"); h.hprop(40, 0, "c"); h.prop(5, 1, "c"); h.apply();
    const changed = [h.rt.statics[41].checked, h.rt.statics[5].value];
    let documentEvents = 0;
    const observed = () => { documentEvents += 1; };
    document.addEventListener("x:y", observed);
    const custom = new Event("x:y", { bubbles: true, cancelable: true });
    h.rt.statics[1].dispatchEvent(custom);
    document.removeEventListener("x:y", observed);
    let targetEvents = 0;
    h.rt.statics[1].addEventListener("close", () => { targetEvents += 1; });
    h.rt.statics[1].dispatchEvent(new Event("close"));
    const dispatch = [calls, custom.defaultPrevented, documentEvents, targetEvents];
    h.close();
    const attributes = harness();
    attributes.elem(1, "img"); attributes.attr(1, "alt", ""); attributes.attr(1, "aria-label", "");
    attributes.attr(1, "data-cleared", "before"); attributes.attr(1, "data-cleared", "", 0);
    attributes.attr(1, "hidden", ""); attributes.attr(1, "required", "false"); attributes.attr(1, "disabled", "true");
    attributes.attrTemplate(3); attributes.attrInst(10, 3, 1); attributes.attrInst(11, 3, 0);
    attributes.elem(20, "select"); attributes.prop(20, 1, "");
    attributes.elem(21, "option", 20); attributes.prop(21, 1, "");
    attributes.byte(10); attributes.word(22); attributes.word(21); attributes.word(0); attributes.str("All works");
    attributes.elem(30, "svg"); attributes.attr(30, "class", "");
    attributes.apply();
    const image = attributes.rt.statics[1];
    const row = attributes.rt.statics[10];
    const emptyAttrs = [image.getAttribute("alt"), image.getAttribute("aria-label"), image.hasAttribute("data-cleared"), image.hasAttribute("hidden"), image.hasAttribute("required"), image.hasAttribute("disabled"), row.getAttribute("alt"), row.getAttribute("data-static"), row.getAttribute("aria-label"), attributes.rt.statics[11].hasAttribute("aria-label"), attributes.rt.statics[30].getAttribute("class")];
    attributes.hattr(10, 1, "named"); attributes.apply();
    attributes.hattr(10, 0); attributes.apply();
    const removed = row.hasAttribute("aria-label");
    attributes.hattr(10, 1, ""); attributes.apply();
    const option = attributes.rt.statics[21];
    const attrChanges = [removed, row.getAttribute("aria-label"), row === attributes.rt.statics[10], attributes.rt.statics[20].value, option.value, option.getAttribute("value")];
    attributes.close();
    const failures = [];
    for (const fault of ["attribute-presence", "hole-presence", "inst-presence", "kind", "kind-event", "policy", "property", "wrong-element", "checked", "template", "file", "changed-file"]) {
      const bad = harness();
      bad.elem(9, fault === "wrong-element" ? "div" : "input");
      if (fault === "attribute-presence") bad.attr(9, "alt", "", 2);
      if (fault === "hole-presence") { bad.attrTemplate(1); bad.attrInst(10, 1, 1); bad.apply(); bad.hattr(10, 2); }
      if (fault === "inst-presence") { bad.attrTemplate(1); bad.attrInst(10, 1, 2); }
      if (fault === "kind") bad.listen(9, "click", 99, 0);
      if (fault === "kind-event") bad.listen(9, "click", 2, 0);
      if (fault === "policy") bad.listen(9, "click", 1, 16);
      if (fault === "property") bad.prop(9, 99, "x");
      if (fault === "wrong-element") bad.prop(9, 2, "true");
      if (fault === "checked") bad.prop(9, 2, "yes");
      if (fault === "template") bad.template(1, "input", 99);
      if (fault === "file") { bad.attr(9, "type", "file"); bad.prop(9, 1, ""); }
      if (fault === "changed-file") { bad.prop(9, 1, "draft"); bad.apply(); bad.attr(9, "type", "file"); bad.prop(9, 1, "next"); }
      bad.apply();
      failures.push([fault, bad.rt.poisoned?.class, fault.includes("file") ? bad.rt.poisoned?.message : null]);
      bad.close();
    }
    const malformedAttributes = [];
    for (const command of ["ATTR", "HATTR", "INST"]) {
      for (const fault of ["missing-length", "truncated-ascii", "truncated-long", "invalid-utf8"]) {
        const bad = harness();
        if (command === "ATTR") {
          bad.elem(1, "img"); bad.apply();
          bad.byte(9); bad.word(1); bad.str("alt");
        } else {
          bad.attrTemplate(1);
          if (command === "HATTR") bad.attrInst(10, 1, 1);
          bad.apply();
          if (command === "HATTR") { bad.byte(3); bad.word(10); bad.byte(0); }
          else { bad.byte(1); bad.word(10); bad.word(0); bad.word(0); bad.word(1); }
        }
        bad.byte(1);
        if (fault === "truncated-ascii") { bad.word(2); bad.byte(65); }
        if (fault === "truncated-long") { bad.word(33); bad.byte(65); }
        if (fault === "invalid-utf8") { bad.word(1); bad.byte(0x80); }
        bad.apply();
        malformedAttributes.push([command, fault, bad.rt.poisoned?.class]);
        bad.close();
      }
    }
    return { state, changed, dispatch, emptyAttrs, attrChanges, failures, malformedAttributes };
  });
  check("property commands preserve controls and select settling; ordinary value attributes do not assign custom properties", got.state, ["hello", "hello", true, "attribute", "original", "0.5", "b", true]);
  check("HPROP applies checkbox and option holes", got.changed, [false, "c"]);
  check("typed prevent/stop hide a bubbling custom name above the mount, while non-bubbling stop leaves the target listener running", got.dispatch, [[[1, 7, ""], [1, 7, ""]], true, 0, 1]);
  check("empty ordinary attributes survive plain commands, static templates and INST; booleans keep their existing absence rule", got.emptyAttrs, ["", "", false, false, false, true, "", "", "", false, ""]);
  check("HATTR distinguishes removal from an empty present value and option value mirrors preserve the empty select choice", got.attrChanges, [false, "", true, "", "", ""]);
  check("unknown declarations and property encodings are executor faults; file input values are contract faults with the node", got.failures, [
    ["attribute-presence", "executor", null], ["hole-presence", "executor", null], ["inst-presence", "executor", null],
    ["kind", "executor", null], ["kind-event", "executor", null], ["policy", "executor", null], ["property", "executor", null], ["wrong-element", "executor", null], ["checked", "executor", null], ["template", "executor", null],
    ["file", "contract", "contract: value property on file input at node 9"], ["changed-file", "contract", "contract: value property on file input at node 9"],
  ]);
  check("ATTR, HATTR and INST reject missing lengths, truncated present strings and invalid UTF-8", got.malformedAttributes, ["ATTR", "HATTR", "INST"].flatMap((command) => ["missing-length", "truncated-ascii", "truncated-long", "invalid-utf8"].map((fault) => [command, fault, "executor"])));
  await ctx.close();
}
await browser.close();
server.close();
console.log(failures === 0 ? "== controls: all pass" : `== controls: ${failures} failures`);
process.exit(failures === 0 ? 0 : 1);
