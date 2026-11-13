// Keyboard dispatch against raw wire commands isolates the browser adapter
// from the engine's separately checked payload decoder and authoring API.
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
    const utf8 = new TextEncoder();
    const join = (...parts) => { const out = new Uint8Array(parts.reduce((n, part) => n + part.length, 0)); let at = 0; for (const part of parts) { out.set(part, at); at += part.length; } return out; };
    const u32 = (n) => { const out = new Uint8Array(4); new DataView(out.buffer).setUint32(0, n, true); return out; };
    const str = (s) => { const bytes = utf8.encode(s); return join(u32(bytes.length), bytes); };
    const elem = (id, parent, tag) => join([8], u32(id), u32(parent), u32(0), str(tag));
    const prop = (id, kind, value) => join([21], u32(id), [kind], str(value));
    const listen = (id, handler, type = "keydown", flags = 0, kind = 4) => join([11], u32(id), u32(handler), str(type), [kind], u32(flags));
    const release = (id) => join([23], u32(id));
    const remove = (id) => join([5], u32(id));
    const focus = (id, mode) => join([18, mode], u32(id));
    const entry = (key, mods = "----", policy = "p", place = "a") => `${policy}${place}${mods}${utf8.encode(key).length}:${key}`;
    window.__keyFixture = () => {
      const root = document.createElement("div"); document.body.append(root);
      const memory = new WebAssembly.Memory({ initial: 2 }); let length = 0;
      const exports = { memory, cmd_ptr: () => 0, cmd_len: () => length, files_released: () => 0, metric: () => 0n, work_len: () => 0, fault: () => 0, drop: () => {} };
      const rt = new RocEngineRuntime(exports, root, { manualEffects: true });
      rt.controlListeners();
      const calls = [];
      rt.deliver = (node, handler, bytes) => {
        const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength); let at = 1;
        const read = () => { const n = dv.getUint32(at, true); at += 4; const text = new TextDecoder().decode(bytes.subarray(at, at + n)); at += n; return text; };
        const key = read(), code = read(), heard = bytes[at++], heardKey = read();
        calls.push({ node, handler, flags: bytes[0], key, code, heard, heardKey });
      };
      const raw = (...parts) => { const bytes = join(...parts); new Uint8Array(memory.buffer).set(bytes); length = bytes.length; rt.apply(); length = 0; };
      const emit = (id, key, options = {}) => {
        const { type = "keydown", keyCode = 0, ...fields } = options;
        const event = new KeyboardEvent(type, { key, code: "", bubbles: true, cancelable: true, ...fields });
        if (keyCode) Object.defineProperty(event, "keyCode", { value: keyCode });
        (id === 0 ? document.body : rt.statics[id]).dispatchEvent(event);
        return event.defaultPrevented;
      };
      const end = () => { rt.unmount(); root.remove(); };
      return { rt, root, raw, calls, emit, end, elem, prop, listen, release, remove, focus, entry };
    };
  });
  const matching = await page.evaluate(() => {
    const f = __keyFixture(); const { elem, prop, listen, entry } = f;
    f.raw(elem(1, 0, "div"), elem(2, 1, "input"), prop(1, 4, entry("k", "C---") + entry("л", "C---")), listen(1, 0));
    const exact = f.emit(2, "л", { code: "KeyK", ctrlKey: true });
    f.raw(prop(1, 4, entry("k", "C---")));
    const fallback = f.emit(2, "л", { code: "KeyK", ctrlKey: true });
    const dvorak = f.emit(2, "t", { code: "KeyK", ctrlKey: true });
    const empty = f.emit(2, "", { code: "KeyK", ctrlKey: true });
    const result = { policies: [exact, fallback, dvorak, empty], heard: f.calls.map((call) => call.heardKey) }; f.end(); return result;
  });
  check("exact layout entry precedes physical fallback; Dvorak and empty keys pass", matching, { policies: [true, true, false, false], heard: ["л", "k"] });
  const places = await page.evaluate(() => {
    const f = __keyFixture(); const { elem, prop, listen, entry } = f;
    f.raw(elem(1, 0, "div"), elem(2, 1, "input"), prop(1, 4, entry("/", "----", "p", "o") + entry("/", "----", "k")), listen(1, 0));
    const inside = f.emit(2, "/"), outside = f.emit(1, "/");
    f.raw(prop(1, 4, "o*"));
    const before = f.calls.length; f.emit(2, "x"); f.emit(1, "x");
    const result = [inside, outside, f.calls.length - before, f.calls.at(-1).heardKey]; f.end(); return result;
  });
  check("OutsideText duplicates retain order and every respects place", places, [false, true, 1, "x"]);
  const modifiers = await page.evaluate(() => {
    const f = __keyFixture(); const { elem, prop, listen, entry } = f;
    f.raw(elem(1, 0, "div"), prop(1, 4, entry("?") + entry("é") + entry("л") + entry(" ") + entry("a", "--S-")), listen(1, 0));
    const matches = [f.emit(1, "?", { shiftKey: true }), f.emit(1, "é", { shiftKey: true }), f.emit(1, "л", { shiftKey: true }), f.emit(1, " ", { shiftKey: true }), f.emit(1, "A", { shiftKey: true })];
    f.raw(prop(1, 4, "a*"));
    f.emit(1, "Enter", { code: "Enter", ctrlKey: true, altKey: true, shiftKey: true, metaKey: true, repeat: true, isComposing: true });
    const payload = f.calls.at(-1); f.end(); return { matches, payload };
  });
  check("Shift is ignored for Unicode punctuation and symbols only", modifiers.matches, [true, false, false, false, true]);
  check("key payload carries all bits and every's actual chord", modifiers.payload, { node: 1, handler: 0, flags: 63, key: "Enter", code: "Enter", heard: 15, heardKey: "Enter" });
  const composition = await page.evaluate(() => {
    const f = __keyFixture(); const { elem, prop, listen, entry } = f;
    f.raw(elem(1, 0, "div"), prop(1, 4, entry("Enter")), listen(1, 0));
    const results = [f.emit(1, "Enter", { isComposing: true }), f.emit(1, "Enter", { keyCode: 229 })];
    f.raw(prop(1, 4, "a*")); f.emit(1, "Enter", { keyCode: 229 });
    const answer = [results, f.calls.length, f.calls.at(-1).flags]; f.end(); return answer;
  });
  check("composition skips entries; only every hears composing Enter", composition, [[false, false], 1, 32]);
  const routing = await page.evaluate(() => {
    const f = __keyFixture(); const { elem, prop, listen, entry, release, remove } = f;
    f.raw(elem(1, 0, "div"), elem(2, 1, "input"), elem(3, 0, "div"), elem(4, 0, "div"), prop(1, 4, entry("Escape")), listen(1, 1), prop(2, 4, entry("Enter")), listen(2, 2), prop(3, 4, entry("Escape") + entry("k", "C---")), listen(3, 3, "keydown", 16), prop(4, 4, entry("Escape")), listen(4, 4, "keydown", 16));
    f.emit(2, "Escape"); f.emit(0, "Escape"); f.emit(0, "k", { ctrlKey: true });
    f.raw(release(4), remove(4)); f.emit(0, "Escape");
    const result = f.calls.map((call) => call.handler); f.end(); return result;
  });
  check("passover, root/document deduplication, newest document map and RELEASE", routing, [1, 4, 3, 3]);
  const queued = await page.evaluate(() => {
    const f = __keyFixture(); const { elem, prop, listen, entry } = f;
    f.raw(elem(1, 0, "div"), prop(1, 4, entry("Escape")), prop(1, 5, entry("Enter", "----", "k")), listen(1, 0), listen(1, 1, "keyup"));
    f.rt.busy = true;
    const prevented = f.emit(1, "Escape");
    f.raw(prop(1, 4, entry("Enter")));
    f.rt.busy = false; f.rt.drainQueue();
    const newIgnored = f.emit(1, "Escape"), next = f.emit(1, "Enter");
    const up = f.emit(1, "Enter", { type: "keyup" });
    const result = [prevented, newIgnored, next, up, f.calls.map((call) => [call.handler, call.heardKey])]; f.end(); return result;
  });
  check("queued key keeps its rendered match, later keys see updates, and Up has its own map", queued, [true, false, true, false, [[0, "Escape"], [0, "Enter"], [1, "Enter"]]]);
  const elementStop = await page.evaluate(() => {
    const f = __keyFixture(), g = __keyFixture();
    f.raw(f.elem(1, 0, "input"), f.prop(1, 4, f.entry("Escape")), f.listen(1, 0, "keydown", 2));
    g.raw(g.elem(1, 0, "div"), g.prop(1, 4, g.entry("Escape")), g.listen(1, 1, "keydown", 16));
    let pageCalls = 0; const observer = () => { pageCalls += 1; }; document.addEventListener("keydown", observer);
    f.emit(1, "Escape");
    const result = [f.calls.length, g.calls.length, pageCalls];
    document.removeEventListener("keydown", observer); f.end(); g.end(); return result;
  });
  check("element stop hides the key from page and another mount's document handlers", elementStop, [1, 0, 0]);
  const lifecycle = await page.evaluate(() => {
    const f = __keyFixture(), g = __keyFixture(); const { elem, prop, listen, entry } = f;
    let windowCalls = 0; const observe = () => { windowCalls += 1; }; window.addEventListener("keydown", observe);
    f.raw(elem(1, 0, "div"), prop(1, 4, entry("Escape")), listen(1, 1, "keydown", 18));
    g.raw(elem(1, 0, "div"), prop(1, 4, entry("Escape")), listen(1, 2, "keydown", 16));
    const prevented = f.emit(0, "Escape"); const stopped = [f.calls.length, g.calls.length, windowCalls];
    f.rt.contain(new Error("fixture")); const afterPoison = f.emit(0, "Escape");
    g.end(); const afterUnmount = f.emit(0, "Escape");
    const result = { prevented, stopped, afterPoison, afterUnmount, windowCalls, listeners: [f.rt.documentListeners.size, g.rt.documentListeners.size] };
    window.removeEventListener("keydown", observe); f.end(); return result;
  });
  check("document stop preserves mount listener order and hides window; teardown removes listeners", lifecycle, { prevented: true, stopped: [1, 1, 0], afterPoison: true, afterUnmount: false, windowCalls: 2, listeners: [0, 0] });
  const apply = await page.evaluate(() => {
    const f = __keyFixture(); const { elem, prop, focus } = f;
    f.raw(elem(1, 0, "input"), prop(1, 1, "original"), focus(1, 1));
    const input = f.rt.statics[1]; input.value = "typed"; f.raw(prop(1, 1, "restored"));
    const deferred = input.value; f.raw(focus(1, 4)); const applied = input.value, focused = document.activeElement === input;
    input.dispatchEvent(new CompositionEvent("compositionstart", { bubbles: true })); input.value = "composition";
    f.raw(prop(1, 1, "cancelled"), focus(1, 4)); const composing = input.value;
    input.dispatchEvent(new CompositionEvent("compositionend", { bubbles: true })); const ended = input.value;
    input.dispatchEvent(new CompositionEvent("compositionstart", { bubbles: true }));
    f.raw(prop(1, 1, "echo"), focus(1, 4)); input.value = "echo"; input.dispatchEvent(new Event("input", { bubbles: true }));
    input.dispatchEvent(new CompositionEvent("compositionend", { bubbles: true }));
    const result = [deferred, applied, focused, composing, ended, input.value, input.__deferred ?? null]; f.end(); return result;
  });
  check("ApplyValue overrides focused guard, waits for composition, and accepts its input echo", apply, ["typed", "restored", true, "composition", "cancelled", "echo", null]);
  const discharged = await page.evaluate(() => {
    const f = __keyFixture();
    f.raw(f.elem(1, 0, "input"), f.prop(1, 1, "rendered"), f.focus(1, 1));
    const input = f.rt.statics[1];
    input.dispatchEvent(new CompositionEvent("compositionstart", { bubbles: true }));
    input.value = "draft"; f.raw(f.focus(1, 4));
    input.value = "rendered"; input.dispatchEvent(new Event("input", { bubbles: true }));
    const pending = input.__applyValue;
    input.value = "newer draft"; input.dispatchEvent(new Event("input", { bubbles: true }));
    input.dispatchEvent(new CompositionEvent("compositionend", { bubbles: true }));
    const retained = input.value;
    input.value = "rendered";
    input.dispatchEvent(new CompositionEvent("compositionstart", { bubbles: true }));
    f.raw(f.focus(1, 4));
    input.value = "later draft";
    input.dispatchEvent(new CompositionEvent("compositionend", { bubbles: true }));
    const result = [pending, retained, input.value]; f.end(); return result;
  });
  check("an already matching composition value discharges ApplyValue before a newer draft", discharged, [false, "newer draft", "later draft"]);
  const unchanged = await page.evaluate(() => {
    const f = __keyFixture();
    f.raw(f.elem(1, 0, "input"), f.prop(1, 1, "rendered"), f.focus(1, 1));
    const input = f.rt.statics[1];
    input.value = "user"; f.raw(f.focus(1, 4));
    const focused = input.value;
    input.dispatchEvent(new CompositionEvent("compositionstart", { bubbles: true }));
    input.value = "composition"; f.raw(f.focus(1, 4));
    const before = input.value;
    input.dispatchEvent(new CompositionEvent("compositionend", { bubbles: true }));
    const result = [focused, before, input.value, document.activeElement === input]; f.end(); return result;
  });
  check("ApplyValue uses the rendered value even without a deferred property write", unchanged, ["rendered", "composition", "rendered", true]);
  await page.evaluate(() => {
    document.body.innerHTML = '<button id="first" tabindex="2">First</button><button id="positive" tabindex="1">Positive</button><button disabled>Disabled</button><button hidden>Hidden</button><a id="link" href="#activated">Link</a><input id="box" type="checkbox"><input id="radio" type="radio"><form id="form"><input id="edit"><button id="submit">Submit</button></form><textarea id="area"></textarea>';
    window.__defaults = [];
    for (const type of ["keydown", "keyup", "click", "submit"]) document.addEventListener(type, (event) => {
      __defaults.push([type, event.target.id]);
      if (type === "submit") event.preventDefault();
    });
  });
  const table = [
    { key: "Tab", code: "Tab", named: true, needs_shift: false },
    { key: "Enter", code: "Enter", named: true, needs_shift: false },
    { key: " ", code: "Space", named: true, needs_shift: false },
    { key: "Escape", code: "Escape", named: true, needs_shift: false },
    { key: "F2", code: "F2", named: true, needs_shift: false },
    { key: "ArrowLeft", code: "ArrowLeft", named: true, needs_shift: false },
  ];
  const press = (key, extra = {}) => page.pressSpec({ key, code: table.find((entry) => entry.key === key).code, ctrl: false, alt: false, shift: false, meta: false, ...extra }, table);
  await page.evaluate(() => { document.body.tabIndex = -1; document.body.focus(); document.body.removeAttribute("tabindex"); });
  await page.evaluate(() => positive.focus());
  await press("Tab");
  const firstTab = await page.evaluate(() => document.activeElement.id);
  await press("Tab", { shift: true });
  const reverse = await page.evaluate(() => document.activeElement.id);
  await page.evaluate(() => first.focus());
  await press("Tab");
  check("physical Tab follows positive tabindex order and skips disabled/hidden controls", [firstTab, reverse, await page.evaluate(() => document.activeElement.id)], ["first", "positive", "link"]);
  await page.evaluate(() => { first.focus(); __defaults = []; });
  await press("Enter");
  check("physical Enter activates a button before keyup", await page.evaluate(() => __defaults), [["keydown", "first"], ["click", "first"], ["keyup", "first"]]);
  await page.evaluate(() => { box.focus(); __defaults = []; });
  await press(" ");
  check("physical Space toggles checkbox on keyup", await page.evaluate(() => [box.checked, __defaults]), [true, [["keydown", "box"], ["keyup", "box"], ["click", "box"]]]);
  await page.evaluate(() => { radio.focus(); __defaults = []; });
  await press(" ");
  check("physical Space selects a radio on keyup", await page.evaluate(() => [radio.checked, __defaults]), [true, [["keydown", "radio"], ["keyup", "radio"], ["click", "radio"]]]);
  await page.evaluate(() => { first.focus(); __defaults = []; });
  await press(" ");
  check("physical Space activates a button on keyup", await page.evaluate(() => __defaults), [["keydown", "first"], ["keyup", "first"], ["click", "first"]]);
  await page.evaluate(() => { edit.focus(); __defaults = []; });
  await press("Enter");
  check("physical Enter in a form input implicitly activates submit", await page.evaluate(() => __defaults), [["keydown", "edit"], ["click", "submit"], ["submit", "form"], ["keyup", "edit"]]);
  await page.evaluate(() => { edit.value = "abc"; edit.focus(); edit.setSelectionRange(1, 1); __defaults = []; });
  await press("Escape"); await press("F2"); await press("ArrowLeft");
  check("Escape, F keys and caret keys leave a text control's value", await page.evaluate(() => [edit.value, document.activeElement.id]), ["abc", "edit"]);
  await page.evaluate(() => { link.focus(); __defaults = []; });
  await press("Enter");
  check("physical Enter activates a link", await page.evaluate(() => [location.hash, __defaults]), ["#activated", [["keydown", "link"], ["click", "link"], ["keyup", "link"]]]);
  const implicit = [];
  for (const contents of ['<input id="implicit">', '<input id="implicit"><input>', '<input id="implicit"><input type="checkbox">', '<input id="implicit"><button disabled>Disabled submit</button>', '<input id="implicit"><input type="hidden">']) {
    await page.evaluate((contents) => {
      document.body.innerHTML = `<form id="implicit-form">${contents}</form>`;
      window.__implicitSubmits = 0;
      document.getElementById("implicit-form").addEventListener("submit", (event) => { event.preventDefault(); __implicitSubmits += 1; });
      document.getElementById("implicit").focus();
    }, contents);
    await press("Enter");
    implicit.push(await page.evaluate(() => __implicitSubmits));
  }
  check("implicit submission without a submit control obeys HTML blocking inputs", implicit, [1, 0, 1, 0, 1]);
  await page.evaluate(() => {
    document.body.innerHTML = "";
    const f = __keyFixture(); window.__imeFixture = f;
    f.raw(f.elem(1, 0, "input"), f.prop(1, 4, f.entry("Enter")), f.listen(1, 0), f.prop(1, 1, "before"), f.focus(1, 1));
    f.rt.statics[1].select();
  });
  await page.send("Input.imeSetComposition", { text: "かな", selectionStart: 2, selectionEnd: 2 });
  const ime = await page.evaluate(() => {
    const f = __imeFixture, input = f.rt.statics[1];
    const composing = input.__composing;
    const prevented = f.emit(1, "Enter", { code: "Enter", isComposing: composing });
    f.raw(f.prop(1, 1, "restored"), f.focus(1, 4));
    return [composing, prevented, input.value, f.calls.length];
  });
  check("real CDP composition does not dispatch committing Enter or get cut by ApplyValue", ime, [true, false, "かな", 0]);
  await page.send("Input.insertText", { text: "かな" });
  check("real compositionend lands explicit deferred ApplyValue", await page.evaluate(() => { const f = __imeFixture; const value = f.rt.statics[1].value; f.end(); delete window.__imeFixture; return value; }), "restored");
  const utf16 = await page.evaluate(() => {
    const fixtures = [];
    const run = (map, key, code) => {
      const f = __keyFixture(); fixtures.push(f);
      f.raw(f.elem(1, 0, "div"), f.prop(1, 4, map), f.listen(1, 0));
      f.emit(1, key, { code });
      return [f.calls.length, f.rt.poisoned?.class ?? null];
    };
    const result = [run("a*", "\ud800", "KeyK"), run("a*", "k", "\udfff"), run("", "\ud800", "\udfff"), run("a*", "", "\ud800")];
    for (const f of fixtures) f.end();
    return result;
  });
  check("heard malformed UTF-16 is contained; ignored and empty keys stage nothing", utf16, [[0, "executor"], [0, "executor"], [0, null], [0, null]]);
  const emptyChord = await page.evaluate(() => {
    const f = __keyFixture();
    f.raw(f.elem(1, 0, "div"), f.prop(1, 4, "pa----0:"), f.listen(1, 0));
    const empty = f.emit(1, ""), ignored = f.emit(1, "x");
    f.raw(f.prop(1, 4, "pa----0:a*"));
    const every = f.emit(1, "x");
    const result = [empty, ignored, every, f.calls.map((call) => call.heardKey)]; f.end(); return result;
  });
  check("an empty declared chord hears nothing while every still catches valid keys", emptyChord, [false, false, false, ["x"]]);
  const malformed = await page.evaluate(() => {
    const bad = ["x", "pa----00:", "pa----01:x", "pa----2:x", "paX---1:x", "a*a*", "a*pa----1:x", "pa----1:é"];
    return bad.map((map) => { const f = __keyFixture(); f.raw(f.elem(1, 0, "div")); let refused = false; try { f.raw(f.prop(1, 4, map)); } catch { refused = true; } f.end(); return refused; });
  });
  check("malformed rendered keymaps fail before dispatch", malformed, Array(8).fill(true));
  console.log(`${failures ? "FAILED" : "PASS"}: keyboard runtime contracts`);
} finally { await browser.close(); await new Promise((resolve) => server.close(resolve)); }
if (failures) process.exitCode = 1;
