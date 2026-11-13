import { installProtocolFixture } from "./protocol-fixture.mjs";
// Browser contracts for session drafts, cross-document storage reports,
// leave guards, clipboard writes and bounded paste-text input. The fixture
// consumes real protocol bytes; browser services and input remain real.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";

const opts = parseArgs(process.argv.slice(2), ["runner"]);
if (!opts.runner) throw new Error("--runner SERVICES_RUNNER is required for guarded-navigation replay contracts");
const here = path.dirname(fileURLToPath(import.meta.url));
const files = { ...runtimeFiles(opts.runtime), "app.wasm": opts.wasm };
const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://fixture");
  const name = path.basename(url.pathname);
  if (url.pathname.startsWith("/activation/")) {
    res.writeHead(200, { "content-type": "text/html", "cache-control": "no-store" });
    res.end('<!doctype html><button>Activate</button><script>window.documentToken=crypto.randomUUID();addEventListener("beforeunload",event=>{event.preventDefault();event.returnValue=true})</script>'); return;
  }
  if (files[name]) {
    res.writeHead(200, { "content-type": name.endsWith(".wasm") ? "application/wasm" : "text/javascript" }); res.end(fs.readFileSync(files[name]));
  } else { res.writeHead(200, { "content-type": "text/html" }); res.end('<!doctype html><title>Persistence contract</title><button id="activate">Activate</button><a id="leave" href="/after">Leave</a><div id="app"></div>'); }
});
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
const base = `http://127.0.0.1:${server.address().port}`;
const browser = await launch({ executablePath: opts.chrome });
let failures = 0, checks = 0;
function check(name, actual, expected = true) {
  checks += 1;
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  if (!ok) failures += 1;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok ? "" : `: got ${JSON.stringify(actual)}, expected ${JSON.stringify(expected)}`}`);
}
async function fixture() {
  const context = await browser.createBrowserContext();
  const page = await context.newPage();
  await page.goto(base);
  await installProtocolFixture(page);
  await page.evaluate(async () => {
    const { RocEngineRuntime, PROTOCOL_VERSION, MAX_QUEUED } = await import("./runtime.mjs");
    const encoder = new TextEncoder();
    const join = (...parts) => { const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0)); let at = 0; for (const p of parts) { out.set(p, at); at += p.length; } return out; };
    const u32 = value => { const out = new Uint8Array(4); new DataView(out.buffer).setUint32(0, value, true); return out; };
    const str = text => { const bytes = encoder.encode(text); return join(u32(bytes.length), bytes); };
    const section = (tag, bytes) => join(new Uint8Array([tag]), u32(bytes.length), bytes);
    window.__fixture = (options = {}, sessionKeys = [], localKeys = []) => {
      const memory = new WebAssembly.Memory({ initial: 4 });
      const declarations = join(section(2, join(u32(localKeys.length), ...localKeys.map(str))), section(5, u32(0)), section(6, u32(0)), section(10, new Uint8Array([0, 0])), section(11, join(u32(sessionKeys.length), ...sessionKeys.map(str))), __protocolFixtureSection);
      new Uint8Array(memory.buffer).set(declarations);
      let length = declarations.length, payloadLength = 0, boot;
      const exports = { memory, protocol_version: () => PROTOCOL_VERSION, boot_keys: () => {}, cmd_ptr: () => 0, cmd_len: () => length,
        payload_reserve: count => { payloadLength = count; return 65536; }, init: () => { boot = new Uint8Array(memory.buffer, 65536, payloadLength).slice(); length = 0; },
        files_released: () => 0, metric: () => 0n, work_len: () => 0, fault: () => 0, drop: () => {} };
      const root = document.createElement("div"); document.getElementById("app").append(root);
      const rt = new RocEngineRuntime(exports, root, { manualEffects: true, ...options, environment: { now: () => 0, seed: () => new Uint8Array(16), ...options.environment } });
      rt.mount();
      const calls = []; rt.deliver = (node, handler, payload) => calls.push({ node, handler, payload: [...payload] });
      const raw = bytes => { new Uint8Array(memory.buffer).set(bytes); length = bytes.length; rt.busy = true; rt.guard(() => rt.apply()); rt.busy = rt.pendingTransition !== null; rt.drainQueue(); };
      const fx = (id, kind, ...operands) => join(new Uint8Array([13]), u32(id), new Uint8Array([kind]), ...operands);
      const store = (op, key, value) => join(new Uint8Array([16, op]), str(key), ...(value === undefined ? [] : [str(value)]));
      return { rt, root, boot, calls, raw, fx, store, u32, str, join, MAX_QUEUED, end: () => { rt.unmount(); root.remove(); } };
    };
  });
  return { context, page };
}
try {
  {
    const { context, page } = await fixture();
    const result = await page.evaluate(async () => {
      sessionStorage.setItem("draft", "previous");
      const f = window.__fixture({}, ["draft"]);
      const session = (() => { for (let at = 0; at < f.boot.length;) { const tag = f.boot[at], n = new DataView(f.boot.buffer).getUint32(at + 1, true); if (tag === 11) return [...f.boot.slice(at + 5, at + 5 + n)]; at += 5 + n; } })();
      const expected = [...f.join(new Uint8Array([1]), f.u32(1), f.str("draft"), f.str("previous"))];
      f.raw(f.join(new Uint8Array([0]), f.store(3, "draft", "next"), f.fx(1, 17, f.str("draft"))));
      const before = f.calls.length;
      await new Promise(resolve => setTimeout(resolve, 0));
      const answer = f.calls[0];
      f.raw(f.join(new Uint8Array([0]), f.store(4, "draft")));
      const absent = sessionStorage.getItem("draft") === null;
      f.end();
      const unavailable = window.__fixture({ sessionStorage: { getItem: () => { throw Error("blocked"); } } }, ["draft"]);
      const bootFlag = unavailable.boot.at(-5); unavailable.end();
      return { session, expected, before, answer, absent, bootFlag };
    });
    check("session boot section has the declared values and availability", result.session, result.expected);
    check("session reads answer next task without a manual occurrence", [result.before, result.answer], [0, { node: 4294967295, handler: 1, payload: [3, ...new TextEncoder().encode("next")] }]);
    check("session remove changes the real store", result.absent);
    check("a throwing session store boots unavailable without partial pairs", result.bootFlag, 0);
    await context.close();
  }
  {
    const { context, page } = await fixture();
    const other = await context.newPage(); await other.goto(`${base}/source`);
    await page.evaluate(() => { const f = window.__storage = window.__fixture(); f.raw(f.join(new Uint8Array([0]), f.fx(1, 18, f.str("document")), f.fx(2, 18, f.str("other")))); });
    await other.evaluate(() => { localStorage.setItem("document", "first"); localStorage.setItem("document", "second"); });
    await page.waitForFunction("window.__storage.rt.reportsReplaced === 1");
    check("real storage events replace in place before a frame", await page.evaluate(() => [window.__storage.calls.length, window.__storage.rt.queue.length, window.__storage.rt.reportsReplaced]), [0, 1, 1]);
    await page.evaluate(() => { localStorage.setItem("document", "own-later"); window.__storage.rt.releaseReports(); });
    check("a storage report retains event.newValue rather than rereading", await page.evaluate(() => window.__storage.calls.map(c => [c.handler, new TextDecoder().decode(new Uint8Array(c.payload.slice(1)))])), [[1, "second"]]);
    await page.evaluate(() => new Promise(resolve => setTimeout(resolve, 0)));
    check("a write in this document never echoes", await page.evaluate(() => window.__storage.rt.queue.length), 0);
    await other.evaluate(() => { sessionStorage.setItem("document", "session"); localStorage.clear(); });
    await page.waitForFunction("window.__storage.rt.queue.length === 2");
    await page.evaluate(() => window.__storage.rt.releaseReports());
    check("clear reports Missing to every local subscription and session writes do not", await page.evaluate(() => window.__storage.calls.slice(1).map(c => [c.handler, c.payload])), [[1, [4]], [2, [4]]]);
    check("last cancellation removes the shared storage listener", await page.evaluate(() => { const f = window.__storage; f.rt.cancel(1); const first = f.rt.storageListener !== null; f.rt.cancel(2); const last = f.rt.storageListener === null; f.end(); return [first, last]; }), [true, true]);
    const identifiable = await page.evaluate(() => {
      const area = localStorage;
      const original = Object.getOwnPropertyDescriptor(area, "getItem");
      Object.defineProperty(area, "getItem", { value: () => { throw Error("read blocked"); }, configurable: true });
      try {
        const f = window.__fixture({ storage: area }, [], ["declared"]);
        f.rt.perform({ op: "storagechanges", id: 1, key: "wanted" });
        window.dispatchEvent(new StorageEvent("storage", { storageArea: area, key: "wanted", newValue: "from event" }));
        f.rt.releaseReports(); const result = f.calls.map(call => call.payload); f.end(); return result;
      } finally {
        if (original) Object.defineProperty(area, "getItem", original); else delete area.getItem;
      }
    });
    check("a store whose reads throw still reports when its non-null area identity matches", identifiable, [[3, ...new TextEncoder().encode("from event")]]);
    await context.close();
  }
  {
    const { context, page } = await fixture();
    const result = await page.evaluate(async () => {
      const blocked = { getItem: () => null, setItem: () => { throw new DOMException("full", "QuotaExceededError"); }, removeItem: () => { throw Error("unavailable"); } };
      const f = window.__fixture({ storage: blocked, sessionStorage: blocked });
      f.raw(f.join(new Uint8Array([0]), f.fx(1, 20), f.store(1, "local", "a"), f.store(3, "session", "b"), f.store(4, "session")));
      const before = f.calls.length;
      f.rt.perform({ op: "storagefailures", id: 2 }); // mounted after these writes
      await new Promise(resolve => setTimeout(resolve, 0));
      const failures = f.calls.map(c => [c.handler, c.payload]);
      f.raw(f.join(new Uint8Array([0]), f.store(1, "cancelled", "a")));
      f.rt.cancel(1); f.rt.cancel(2);
      await new Promise(resolve => setTimeout(resolve, 0));
      const cancelled = f.calls.length === 3;
      f.end();
      const none = window.__fixture({ storage: blocked }); none.raw(none.join(new Uint8Array([0]), none.store(1, "no-sub", "x")));
      await new Promise(resolve => setTimeout(resolve, 0)); const unreported = none.calls.length === 0; none.end();
      return { before, failures, cancelled, unreported };
    });
    check("write failures are next-task occurrences with captured recipients and typed reasons", result, { before: 0, failures: [[1, [25, 1, 1, ...new TextEncoder().encode("local")]], [1, [25, 2, 1, ...new TextEncoder().encode("session")]], [1, [25, 2, 2, ...new TextEncoder().encode("session")]]], cancelled: true, unreported: true });
    const bounded = await page.evaluate(() => {
      const f = window.__fixture({ storage: { getItem: () => null, setItem: () => { throw Error("blocked"); } } });
      f.rt.perform({ op: "storagefailures", id: 1 });
      const warn = console.warn; console.warn = () => {};
      try { for (let i = 0; i <= f.MAX_QUEUED; i++) f.rt.perform({ op: "set", key: "k", value: "v" }); }
      finally { console.warn = warn; }
      const result = [f.rt.poisoned?.class, f.rt.storageFailureCount, f.rt.storageFailureTask]; f.end(); return result;
    });
    check("nonlossy write failures have one bounded task and overflow is contained", bounded, ["resource_limit", 0, null]);
    const cancellation = await page.evaluate(async () => {
      const blocked = { getItem: () => null, setItem: () => { throw Error("blocked"); } };
      const f = window.__fixture({ storage: blocked });
      const warn = console.warn; console.warn = () => {};
      try {
        f.rt.perform({ op: "storagefailures", id: 1 });
        for (let i = 0; i < f.MAX_QUEUED; i++) f.rt.perform({ op: "set", key: "old", value: "v" });
        const filled = f.rt.storageFailureCount;
        f.rt.cancel(1);
        const freed = [f.rt.storageFailureCount, f.rt.storageFailureHead, f.rt.storageFailureTask];
        f.rt.perform({ op: "storagefailures", id: 2 });
        f.rt.perform({ op: "set", key: "new", value: "v" });
        await new Promise(resolve => setTimeout(resolve, 0));
        const result = [filled, freed, f.calls.map(call => [call.handler, call.payload]), f.rt.poisoned]; f.end(); return result;
      } finally { console.warn = warn; }
    });
    check("cancelled failure recipients immediately free capacity and never reach reused sites", cancellation, [4096, [0, null, null], [[2, [25, 1, 2, ...new TextEncoder().encode("new")]]], null]);
    const combined = await page.evaluate(() => {
      const f = window.__fixture({ storage: { getItem: () => null, setItem: () => { throw Error("blocked"); } } });
      f.rt.perform({ op: "storagefailures", id: 1 });
      const warn = console.warn; console.warn = () => {};
      try { for (let i = 0; i < 4095; i++) f.rt.perform({ op: "set", key: "k", value: "v" }); }
      finally { console.warn = warn; }
      f.rt.perform({ op: "interval", id: 2, ms: 1000 });
      f.rt.report(2, new Uint8Array([5,0,0,0,0,0,0,0,0]));
      const atBound = [f.rt.queue.length, f.rt.storageFailureCount, f.rt.poisoned];
      f.rt.perform({ op: "interval", id: 3, ms: 1001 });
      f.rt.report(3, new Uint8Array([5,0,0,0,0,0,0,0,0]));
      const overflow = f.rt.poisoned?.class; f.end(); return [atBound, overflow];
    });
    check("deferred failure recipients and ingress share the 4096-entry bound", combined, [[1, 4095, null], "resource_limit"]);
    const chained = await page.evaluate(async () => {
      const f = window.__fixture({ storage: { getItem: () => null, setItem: () => { throw Error("blocked"); } } });
      f.rt.perform({ op: "storagefailures", id: 1 });
      const warn = console.warn; console.warn = () => {};
      try {
        f.rt.deliver = (node, handler, payload) => {
          f.calls.push({ node, handler, payload: [...payload] });
          if (f.calls.length === 1) f.rt.perform({ op: "set", key: "second", value: "v" });
        };
        f.rt.perform({ op: "set", key: "first", value: "v" });
        await new Promise(resolve => setTimeout(resolve, 0)); const firstTask = f.calls.length;
        await new Promise(resolve => setTimeout(resolve, 0)); const secondTask = f.calls.length;
        f.end(); return [firstTask, secondTask];
      } finally { console.warn = warn; }
    });
    check("a write failed during a failure reaction waits for its own next task", chained, [1, 2]);
    const mixed = await page.evaluate(async () => {
      const blocked = { getItem: () => "read", setItem: () => { throw Error("blocked"); } };
      const f = window.__fixture({ storage: blocked });
      const warn = console.warn; console.warn = () => {};
      try {
        f.raw(f.join(new Uint8Array([0]), f.fx(1, 20), f.store(1, "A", "value"), f.fx(2, 2, f.str("B")), f.store(1, "C", "value")));
        await new Promise(resolve => setTimeout(resolve, 0));
        const result = f.calls.map(call => call.handler === 1 ? new TextDecoder().decode(new Uint8Array(call.payload.slice(3))) : "read B");
        f.end(); return result;
      } finally { console.warn = warn; }
    });
    check("the single failure task batches A and C before an intervening storage-read callback B", mixed, ["A", "C", "read B"]);

    await context.close();
  }
  {
    const { context, page } = await fixture();
    const malformed = await page.evaluate(async () => {
      let bootRefused = false;
      try { window.__fixture({ sessionStorage: { getItem: () => "\ud800" } }, ["draft"]); }
      catch (error) { bootRefused = error.message.includes("well-formed Unicode"); }
      const readFailures = [];
      for (const op of ["get", "sessionget"]) {
        const bad = { getItem: () => "\ud800" };
        const f = window.__fixture({ storage: bad, sessionStorage: bad });
        f.rt.perform({ op, id: 1, key: "draft" }); await new Promise(resolve => setTimeout(resolve, 0));
        readFailures.push([f.rt.poisoned?.class, f.calls.length]); f.end();
      }
      const f = window.__fixture(); f.rt.perform({ op: "storagechanges", id: 1, key: "wanted" });
      let reads = 0;
      const unrelated = new Event("storage");
      Object.defineProperties(unrelated, { storageArea: { value: localStorage }, key: { value: "unrelated" }, newValue: { get: () => { reads += 1; throw Error("unrelated value was read"); } } });
      window.dispatchEvent(unrelated);
      const untouched = [reads, f.rt.poisoned === null];
      window.dispatchEvent(new StorageEvent("storage", { storageArea: localStorage, key: "wanted", newValue: "\ud800" }));
      const reported = [f.rt.poisoned?.class, f.calls.length]; f.end();
      return { bootRefused, readFailures, untouched, reported };
    });
    check("storage refuses unrepresentable Unicode without repairing values or reading unrelated keys", malformed, { bootRefused: true, readFailures: [["executor", 0], ["executor", 0]], untouched: [0, true], reported: ["executor", 0] });
    await context.close();
  }
  {
    const { context, page } = await fixture();
    const result = await page.evaluate(() => {
      const f = window.__fixture({ maxPasteBytes: 4 });
      f.raw(f.join(new Uint8Array([0, 8]), f.u32(1), f.u32(0), f.u32(0), f.str("div"), new Uint8Array([11]), f.u32(1), f.u32(7), f.str("paste"), new Uint8Array([9]), f.u32(0)));
      const element = f.root.firstChild;
      const paste = text => { const data = new DataTransfer(); data.setData("text/plain", text); const event = new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }); element.dispatchEvent(event); return event.defaultPrevented; };
      const prevented = [paste("éé"), paste("ééx")];
      const payloads = f.calls.map(c => c.payload);
      f.rt.maxPasteBytes = 0; paste(""); paste("x");
      const zeroPayloads = f.calls.slice(2).map(c => c.payload); f.end();
      const zero = window.__fixture({ maxPasteBytes: 0 }); zero.end();
      const invalid = [-1, 0.5, Number.MAX_SAFE_INTEGER + 1].map(maxPasteBytes => { try { window.__fixture({ maxPasteBytes }); return false; } catch { return true; } });
      return { prevented, payloads, zeroPayloads, invalid };
    });
    check("paste text prevents default and checks UTF-8 bytes before staging", result, { prevented: [true, true], payloads: [[0, 195, 169, 195, 169], [1]], zeroPayloads: [[0], [1]], invalid: [true, true, true] });
    const unicode = await page.evaluate(() => {
      const f = window.__fixture({ maxPasteBytes: 4 });
      f.raw(f.join(new Uint8Array([0, 8]), f.u32(1), f.u32(0), f.u32(0), f.str("div"), new Uint8Array([11]), f.u32(1), f.u32(7), f.str("paste"), new Uint8Array([9]), f.u32(0)));
      const paste = text => {
        const event = new Event("paste", { bubbles: true, cancelable: true });
        // Preserve the browser API's DOMString boundary without repairing
        // the fixture's deliberate lone surrogates before dispatch.
        Object.defineProperty(event, "clipboardData", { value: { getData: () => text } });
        f.root.firstChild.dispatchEvent(event); return event.defaultPrevented;
      };
      const oversized = "\ud800".repeat(8);
      const wellFormed = String.prototype.isWellFormed, encode = TextEncoder.prototype.encode;
      let scans = 0, encodings = 0, refused;
      try {
        String.prototype.isWellFormed = function () { if (this.valueOf() === oversized) scans += 1; return wellFormed.call(this); };
        TextEncoder.prototype.encode = function (text) { if (text === oversized) encodings += 1; return encode.call(this, text); };
        refused = [paste(oversized), f.calls.map(call => call.payload), scans, encodings, f.rt.poisoned];
      } finally {
        String.prototype.isWellFormed = wellFormed; TextEncoder.prototype.encode = encode;
      }
      paste("\ud800");
      const contained = [f.rt.poisoned?.class, f.calls.length]; f.end();
      return { refused, contained };
    });
    check("oversized Unicode is refused before scanning or encoding; in-bound malformed text is contained", unicode, { refused: [true, [[1]], 0, 0, null], contained: ["executor", 1] });
    const unhandled = await page.evaluate(() => {
      const f = window.__fixture();
      f.raw(f.join(new Uint8Array([0, 8]), f.u32(1), f.u32(0), f.u32(0), f.str("div"), new Uint8Array([8]), f.u32(2), f.u32(0), f.u32(0), f.str("div"), new Uint8Array([11]), f.u32(2), f.u32(7), f.str("paste"), new Uint8Array([9]), f.u32(0)));
      f.rt.perform({ op: "storagechanges", id: 10, key: "document" });
      window.dispatchEvent(new StorageEvent("storage", { storageArea: localStorage, key: "document", newValue: "waiting" }));
      const before = [f.calls.length, f.rt.queue.length];
      const data = new DataTransfer(); data.setData("text/plain", "ignored");
      // A sibling's handler installs the delegated paste listener. This
      // target still routes no event, so its paste cannot flush the report.
      f.root.firstChild.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
      const afterPaste = [f.calls.length, f.rt.queue.length];
      f.rt.releaseReports();
      const afterRelease = [f.calls.map(call => [call.handler, call.payload]), f.rt.queue.length]; f.end();
      return { before, afterPaste, afterRelease };
    });
    check("production routing leaves held reports pending when paste has no listener", unhandled, { before: [0, 1], afterPaste: [0, 1], afterRelease: [[[10, [3, ...new TextEncoder().encode("waiting")]]], 0] });
    const bad = await page.evaluate(() => [2, 255].map(value => { const f = window.__fixture(); f.raw(new Uint8Array([0, 25, value])); const rejected = f.rt.poisoned?.class === "executor"; f.end(); return rejected; }));
    check("invalid GUARD operands are executor faults", bad, [true, true]);
    const malformed = await page.evaluate(() => {
      const cases = [];
      for (const flag of [2, 255]) {
        const f = window.__fixture(); f.raw(f.join(new Uint8Array([0]), f.fx(1, 19, f.str("text"), new Uint8Array([flag]))));
        cases.push(f.rt.poisoned?.class === "executor"); f.end();
      }
      const f = window.__fixture(); f.raw(f.join(new Uint8Array([0]), f.store(5, "key"))); cases.push(f.rt.poisoned?.class === "executor"); f.end();
      return cases;
    });
    check("clipboard HTML flags and storage operation enums are strict", malformed, [true, true, true]);
    await context.close();
  }
  {
    const { context, page } = await fixture();
    const manual = await page.evaluate(async () => {
      const f = window.__fixture(); f.raw(f.join(new Uint8Array([0]), f.fx(1, 19, f.str("text"), new Uint8Array([1]), f.str("<b>text</b>"))));
      const pending = [f.calls.length, f.rt.issued.length]; await new Promise(resolve => setTimeout(resolve, 0));
      const first = [f.calls.at(-1).payload, f.rt.clipboardSnapshot()];
      f.rt.manualClipboardDenied = true; f.rt.perform({ op: "clipboard", id: 2, text: "denied", html: null }); await new Promise(resolve => setTimeout(resolve, 0));
      const denied = [f.calls.at(-1).payload, f.rt.clipboardSnapshot()];
      f.rt.manualClipboardDenied = false; f.rt.clipboardWrites = (1n << 64n) - 1n; f.rt.perform({ op: "clipboard", id: 3, text: "still copied", html: null }); await new Promise(resolve => setTimeout(resolve, 0));
      let observation = false; try { f.rt.clipboardSnapshot(); } catch { observation = true; }
      const exhausted = [observation, f.rt.poisoned === null, f.calls.at(-1).payload]; f.end(); return { pending, first, denied, exhausted };
    });
    check("manual clipboard answers automatically and denied attempts leave successful contents/count unchanged", manual, { pending: [0, 0], first: [[23], { text: "text", html: "<b>text</b>", writes: "1" }], denied: [[24, 1], { text: "text", html: "<b>text</b>", writes: "1" }], exhausted: [true, true, [23]] });
    const cancelled = await page.evaluate(async () => {
      const f = window.__fixture();
      f.raw(f.join(new Uint8Array([0]), f.fx(1, 19, f.str("performed"), new Uint8Array([0])), new Uint8Array([14]), f.u32(1)));
      const immediate = f.rt.clipboardSnapshot(); await new Promise(resolve => setTimeout(resolve, 0));
      const result = [immediate, f.calls.length, f.rt.live.size]; f.end(); return result;
    });
    check("cancelling a clipboard answer never undoes its already-performed write", cancelled, [{ text: "performed", html: "", writes: "1" }, 0, 0]);
    await context.close();
  }
  {
    const { context, page } = await fixture();
    await page.evaluate(() => {
      const f = window.__copy = window.__fixture({ manualEffects: false });
      window.__copyActive = null;
      window.__copyHtml = false;
      const write = navigator.clipboard.write.bind(navigator.clipboard);
      navigator.clipboard.write = items => {
        window.__htmlCall = { active: navigator.userActivation.isActive, items: items.length, types: items[0].types, nodes: f.root.childNodes.length };
        window.__htmlRepresentations = Promise.all(items[0].types.map(async type => [type, await (await items[0].getType(type)).text()]));
        return write(items);
      };
      document.getElementById("activate").addEventListener("click", () => {
        window.__copyActive = navigator.userActivation.isActive;
        if (!window.__copyHtml) f.raw(f.join(new Uint8Array([0]), f.fx(1, 19, f.str("real clipboard"), new Uint8Array([0]))));
        else f.raw(f.join(new Uint8Array([1]), f.fx(2, 19, f.str("real HTML"), new Uint8Array([1]), f.str("<b>real HTML</b>")), new Uint8Array([8]), f.u32(1), f.u32(0), f.u32(0), f.str("span"), new Uint8Array([24]), f.u32(0)));
      });
    });
    await page.clickAt(await page.evaluate(() => { const r = document.getElementById("activate").getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; }));
    await page.waitForFunction("window.__copy.calls.length === 1");
    check("a real clipboard write runs inside its click's activation and succeeds", await page.evaluate(() => [window.__copyActive, window.__copy.calls[0].payload]), [true, [23]]);
    await page.evaluate(() => { window.__copyHtml = true; });
    await page.clickAt(await page.evaluate(() => { const r = document.getElementById("activate").getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; }));
    await page.waitForFunction("window.__copy.calls.length === 2");
    check("one real clipboard item carries plain text and HTML inside a marked click batch", await page.evaluate(async () => [window.__htmlCall, await window.__htmlRepresentations, window.__copy.calls[1].payload]), [{ active: true, items: 1, types: ["text/plain", "text/html"], nodes: 0 }, [["text/plain", "real HTML"], ["text/html", "<b>real HTML</b>"]], [23]]);
    // A background page has neither focus nor this new foreground page's activation.
    const front = await context.newPage(); await front.goto(`${base}/foreground`); await front.send("Page.bringToFront");
    await page.evaluate(() => window.__copy.rt.perform({ op: "clipboard", id: 3, text: "background", html: null }));
    await page.waitForFunction("window.__copy.calls.length === 3");
    check("the real browser's denied background clipboard write becomes NotAllowed", await page.evaluate(() => window.__copy.calls[2].payload), [24, 1]);
    await context.close();
  }
  {
    const { context, page } = await fixture();
    const results = await page.evaluate(async () => {
      const { RocEngineRuntime, pageImports } = await import("./runtime.mjs");
      const module = await WebAssembly.compile(await (await fetch("app.wasm")).arrayBuffer());
      const fresh = async () => (await WebAssembly.instantiate(module, pageImports(module))).exports;
      const stage = (x, payload) => { const pointer = x.payload_reserve(payload.length); new Uint8Array(x.memory.buffer, pointer, payload.length).set(payload); };
      const badResults = [[23, 0], [24], [24, 0], [24, 3], [24, 1, 0], [25], [25, 1], [25, 0, 1], [25, 3, 1], [25, 1, 0], [25, 1, 3], [25, 1, 1, 255]];
      const resultCases = [];
      for (const payload of badResults) {
        const x = await fresh(); stage(x, new Uint8Array()); x.init(); stage(x, new Uint8Array(payload));
        let failed = false; try { x.event(0xffffffff, 999999); } catch { failed = x.fault() === 1; }
        resultCases.push(failed);
      }
      for (const payload of [[23], [24, 1], [24, 2], [25, 1, 1], [25, 2, 2, 107]]) {
        const x = await fresh(); stage(x, new Uint8Array()); x.init(); stage(x, new Uint8Array(payload));
        let accepted = true; try { x.event(0xffffffff, 999999); } catch { accepted = false; }
        resultCases.push(accepted); if (accepted) x.drop();
      }
      const fixture = window.__fixture();
      const section = (tag, body) => fixture.join(new Uint8Array([tag]), fixture.u32(body.length), body);
      const boot = body => {
        const parts = [];
        for (let at = 0; at < fixture.boot.length;) {
          const tag = fixture.boot[at], length = new DataView(fixture.boot.buffer).getUint32(at + 1, true);
          parts.push(section(tag, tag === 11 ? body : fixture.boot.slice(at + 5, at + 5 + length))); at += 5 + length;
        }
        return fixture.join(...parts);
      };
      const sessionCases = [];
      for (const body of [new Uint8Array(), new Uint8Array([2, 0, 0, 0, 0]), fixture.join(new Uint8Array([0]), fixture.u32(1), fixture.str("k"), fixture.str("v")), new Uint8Array([1, 0, 0, 0, 0, 0]), fixture.join(new Uint8Array([1]), fixture.u32(1), fixture.str("undeclared"), fixture.str("v"))]) {
        const x = await fresh(); stage(x, boot(body)); let failed = false;
        try { x.init(); } catch { failed = x.fault() === 1; } sessionCases.push(failed);
      }
      fixture.end();
      const pasteCases = [];
      for (const payload of [[], [1, 0], [2], [255], [0, 255]]) {
        history.replaceState(null, "", "#persistence");
        const x = await fresh(); const root = document.createElement("div"); document.body.append(root);
        const rt = new RocEngineRuntime(x, root, { module, manualEffects: true, environment: { now: () => 0, seed: () => new Uint8Array(16) } }); rt.mount();
        const target = root.querySelector('[aria-label="Paste text"]');
        if (!target) throw new Error("the services module has no Paste text decoder probe");
        const handler = target.__h.paste; let route = target; while (route && route.__rn === undefined) route = route.parentElement;
        stage(x, new Uint8Array(payload)); let failed = false; try { x.event(route.__rn, handler.h); } catch { failed = x.fault() === 1; }
        pasteCases.push(failed); rt.unmount(); root.remove();
      }
      return { resultCases, sessionCases, pasteCases };
    });
    check("real engine rejects malformed clipboard/storage results and accepts valid stale results", results.resultCases, Array(17).fill(true));
    check("real engine rejects malformed or undeclared session boot pairs", results.sessionCases, Array(5).fill(true));
    check("real routed paste decoder rejects bad status, trailing bytes and invalid UTF-8", results.pasteCases, Array(5).fill(true));
    await context.close();
  }
  {
    const { context, page } = await fixture();
    const lifetime = await page.evaluate(async () => {
      const { RocEngineRuntime, pageImports } = await import("./runtime.mjs");
      const module = await WebAssembly.compile(await (await fetch("app.wasm")).arrayBuffer());
      const x = (await WebAssembly.instantiate(module, pageImports(module))).exports;
      history.replaceState(null, "", "#persistence");
      const root = document.createElement("div"); document.body.append(root);
      const rt = new RocEngineRuntime(x, root, { module, manualEffects: true, environment: { now: () => 0, seed: () => new Uint8Array(16) } }); rt.mount();
      const click = name => [...root.querySelectorAll("button")].find(element => element.textContent === name).click();
      click("Guard on"); const on = rt.leaveGuard;
      click("Dispose guard"); const disposed = !rt.leaveGuard;
      click("Mount guard"); const remounted = rt.leaveGuard;
      click("Guard off"); const off = !rt.leaveGuard;
      rt.unmount(); root.remove(); return [on, disposed, remounted, off];
    });
    check("real engine disposal and remount update the guard without an awaited slot", lifetime, [true, true, true, true]);
    await context.close();
  }
  // Chromium carries sticky activation through renderer-initiated,
  // same-origin top-frame navigation. Transient activation resets. Observe
  // real documents and real dialogs; the driver never sets CDP userGesture.
  // Chromium's rule: navigation_request.cc, should_have_sticky_user_activation.
  {
    const context = await browser.createBrowserContext(); const page = await context.newPage();
    const frames = [], dialogs = [];
    page.conn.on(page.sessionId, "Page.frameNavigated", event => { if (!event.frame.parentId) frames.push({ id: event.frame.id, loader: event.frame.loaderId }); });
    page.conn.on(page.sessionId, "Page.javascriptDialogOpening", async event => { dialogs.push(event.type); await page.send("Page.handleJavaScriptDialog", { accept: true }); });
    const activation = () => page.evaluate(() => ({ token: window.documentToken, timeOrigin: performance.timeOrigin, active: navigator.userActivation.isActive, sticky: navigator.userActivation.hasBeenActive }));
    const navigate = async url => {
      await page.evaluate(url => { setTimeout(() => location.assign(url), 0); }, url);
      await page.waitForFunction(`location.pathname === ${JSON.stringify(url)}`);
    };
    await page.goto(`${base}/activation/start`);
    await installProtocolFixture(page); const initial = await activation();
    await navigate("/activation/unactivated"); const fresh = await activation(); const unasked = dialogs.length;
    await page.clickAt(await page.evaluate(() => { const r = document.querySelector("button").getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; }));
    const clicked = await activation();
    await navigate("/activation/next"); const next = await activation();
    await navigate("/activation/last"); const last = await activation();
    check("fresh documents start unactivated; same-origin navigation preserves sticky but resets transient activation", [initial.active, initial.sticky, fresh.active, fresh.sticky, clicked.active, clicked.sticky, next.active, next.sticky, last.active, last.sticky], [false, false, false, false, true, true, false, true, false, true]);
    check("same-origin carry belongs to fresh documents with distinct tokens, time origins and loaders", [new Set([initial.token, fresh.token, next.token, last.token]).size, new Set([initial.timeOrigin, fresh.timeOrigin, next.timeOrigin, last.timeOrigin]).size, new Set(frames.map(frame => frame.loader)).size, new Set(frames.map(frame => frame.id)).size], [4, 4, 4, 1]);
    check("a fresh guard leaves unasked, then both guarded same-origin documents ask after activation", [unasked, dialogs], [0, ["beforeunload", "beforeunload"]]);
    await context.close();
  }
  // Each case gets a fresh document, so a previous activation cannot mask
  // the browser's sticky-activation requirement for beforeunload.
  for (const mode of ["unactivated", "on", "off", "poison", "unmount", "recover", "link"]) {
    const { context, page } = await fixture();
    await page.evaluate(async mode => {
      const f = window.__guard = window.__fixture(); f.raw(new Uint8Array([0, 25, 1]));
      if (mode === "off") f.raw(new Uint8Array([0, 25, 0]));
      if (mode === "poison") f.rt.contain(new Error("contract fixture"), "contract");
      if (mode === "unmount") f.end();
      if (mode === "recover") {
        f.rt.module = await WebAssembly.compile(await (await fetch("app.wasm")).arrayBuffer());
        f.rt.contain(new Error("contract fixture"), "contract");
        await f.rt.recover();
      }
    }, mode);
    if (mode !== "unactivated") await page.clickAt(await page.evaluate(() => { const r = document.getElementById("activate").getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; }));
    const dialogs = [];
    page.conn.on(page.sessionId, "Page.javascriptDialogOpening", async event => { dialogs.push(event.type); await page.send("Page.handleJavaScriptDialog", { accept: true }); });
    if (mode === "link") await page.clickAt(await page.evaluate(() => { const r = document.getElementById("leave").getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; }));
    else await page.evaluate(() => location.assign("/after")).catch(error => { if (!/context.*destroyed|Cannot find context/i.test(error.message)) throw error; });
    await page.waitForFunction('location.pathname === "/after"');
    check(`real beforeunload policy (${mode})`, dialogs, ["on", "poison", "link"].includes(mode) ? ["beforeunload"] : []);
    await context.close();
  }
  // Negative cases use the same Roc parser and must fail the action that
  // opened a forbidden dialog. Positive cases really answer Chrome's dialog.
  {
    const fixtures = ["guarded-navigate", "guarded-link", "guarded-stay", "guarded-leave", "disposed-guard", "storage-area-available", "storage-area-unavailable", "paste-no-handler", "paste-no-report-flush"].map(name => path.join(here, "../apps/services/contracts", `${name}.scm`));
    const emitted = spawnSync(opts.runner, ["--emit-steps", ...fixtures], { encoding: "utf8", timeout: 30000 });
    if (emitted.status !== 0) throw new Error(`could not parse guarded-navigation contracts: ${emitted.stderr}`);
    const native = spawnSync(opts.runner, fixtures, { encoding: "utf8", timeout: 30000 });
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), "roc-signals-persistence-contract-"));
    try {
      const steps = path.join(directory, "steps.jsonl"); fs.writeFileSync(steps, emitted.stdout);
      const replay = spawnSync(process.execPath, [path.join(here, "replay.mjs"), "--wasm", opts.wasm, "--runtime", opts.runtime, "--steps", steps, "--chrome", opts.chrome, "--json-lines"], { encoding: "utf8", timeout: 60000 });
      const rows = output => output.split("\n").filter(Boolean).map(line => JSON.parse(line));
      const wanted = ["failed", "failed", "passed", "passed", "passed", "passed", "passed", "passed", "passed"];
      const nativeRows = rows(native.stdout), browserRows = rows(replay.stdout);
      check("guarded navigation/link failures and deliberate stay/leave/disposal agree in both runners", [native.status, nativeRows.map(row => row.status), replay.status, browserRows.map(row => row.status)], [1, wanted, 1, wanted]);
      check("a dialog outside leave-page fails exactly its navigate or click step", [nativeRows.slice(0, 2).every(row => row.failure?.message.includes("leave-page")), browserRows.slice(0, 2).map(row => [row.failure?.step, row.failure?.message.includes("leave-page")])], [true, [[1, true], [1, true]]]);
      if (JSON.stringify(browserRows.map(row => row.status)) !== JSON.stringify(wanted)) console.log(replay.stderr);
    } finally { fs.rmSync(directory, { recursive: true, force: true }); }
  }
} finally { await browser.close(); server.close(); }
console.log(`== persistence browser: ${checks - failures}/${checks} pass`);
process.exit(failures ? 1 : 0);
