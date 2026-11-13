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
    parent.__h = { close: { h: 1 }, scroll: { h: 2 }, cancel: { h: 3 } };
    const rt = new RocEngineRuntime({}, root);
    const calls = [];
    rt.deliver = (node, handler) => calls.push([node, handler]);
    for (const type of ["close", "scroll", "cancel"]) rt.listen(type);
    target.__h = { close: { h: 4 }, scroll: { h: 5 } };
    target.dispatchEvent(new Event("close"));
    target.dispatchEvent(new Event("scroll"));
    target.__h = {};
    target.dispatchEvent(new Event("close"));
    target.dispatchEvent(new Event("scroll"));
    target.dispatchEvent(new Event("cancel", { bubbles: true }));
    target.dispatchEvent(new Event("cancel"));
    parent.__h.drop = { h: 8, files: true };
    parent.__h.dragover = { h: 6 };
    rt.listen("drop");
    rt.listen("dragover");
    const over = new Event("dragover", { bubbles: true, cancelable: true });
    target.dispatchEvent(over);
    const dropAllows = over.defaultPrevented;
    rt.contain(new Error("fixture done"), "executor");
    target.__h = { close: { h: 4 } };
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
    byte(3); byte(1); byte(0); byte(7); str("click");
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
      a.__h = b.__h = { focus: { h: 0 } };
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
await browser.close();
server.close();
console.log(failures === 0 ? "== controls: all pass" : `== controls: ${failures} failures`);
process.exit(failures === 0 ? 0 : 1);
