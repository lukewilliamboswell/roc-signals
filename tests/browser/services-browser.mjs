import { installProtocolFixture } from "./protocol-fixture.mjs";
// services-browser.mjs --wasm services.wasm --runtime runtime.mjs --chrome PATH
// -- runtime and host contract cases with tests/apps/services in headless
// Chrome:
// - the protocol version: the host reports it and the runtime refuses any
//   other version before running anything;
// - malformed boot bytes and a non-UTF-8 effect result poison the instance
//   with class `contract`, and a one-byte template count above 255 with
//   `resource_limit`;
// - the ingress queue is bounded: overflow poisons with `resource_limit`;
// - a submit is default-prevented (no navigation);
// - the boot bytes carry connectivity and visibility, and the subscriptions
//   follow the browser's `online`/`offline` and `visibilitychange` events;
// - the boot bytes say whether local storage is available: a page whose
//   `localStorage` throws boots with the storage flag clear;
// - a <select> re-applies its value when options are inserted or change;
// - the work record: `metric(16 + k)` and `workRecord()` agree, and count
//   the commands the batch applied.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const opts = parseArgs(process.argv.slice(2));
const files = { "index.html": path.join(here, "index.html"), ...runtimeFiles(opts.runtime), "app.wasm": opts.wasm };
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
const base = `http://127.0.0.1:${server.address().port}`;
const browser = await launch({ executablePath: opts.chrome });

let failures = 0;
const check = (name, got, want) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  if (!ok) failures += 1;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok ? "" : `: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`}`);
};

async function open(prelude = "") {
  const ctx = await browser.createBrowserContext();
  const page = await ctx.newPage();
  page.on("pageerror", (e) => console.log("pageerror", String(e)));
  if (prelude) await page.evaluateOnNewDocument(prelude);
  await page.goto(`${base}/app/`);
  await installProtocolFixture(page);
  await page.waitForFunction("window.__ready || window.__error");
  return { page, ctx };
}

// Raw instances of the module, outside the runtime.
{
  const { page, ctx } = await open();
  const raw = await page.evaluate(async () => {
    const { RocEngineRuntime, PROTOCOL_VERSION, pageImports } = await import("./runtime.mjs");
    const module = await WebAssembly.compile(await (await fetch("app.wasm")).arrayBuffer());
    // Every module imports the worker effects, which the page's instance
    // answers with throwing stubs.
    const fresh = async () => (await WebAssembly.instantiate(module, pageImports(module))).exports;
    const text = (x) => new TextDecoder().decode(new Uint8Array(x.memory.buffer, x.err_ptr(), x.err_len()));
    const out = {};
    // The version.
    const x0 = await fresh();
    out.version = [x0.protocol_version(), PROTOCOL_VERSION];
    const fake = { ...x0, protocol_version: () => PROTOCOL_VERSION + 1 };
    const root = document.createElement("div");
    try {
      new RocEngineRuntime(fake, root).mount();
      out.refused = "mounted";
    } catch (e) {
      out.refused = [String(e.message).includes("is not the protocol"), root.childNodes.length];
    }
    const u32 = (value) => { const b = new Uint8Array(4); new DataView(b.buffer).setUint32(0, value, true); return b; };
    const join = (parts) => { const b = new Uint8Array(parts.reduce((n, p) => n + p.length, 0)); let at = 0; for (const p of parts) { b.set(p, at); at += p.length; } return b; };
    const str = (text) => { const b = new TextEncoder().encode(text); return join([u32(b.length), b]); };
    const section = (tag, body) => join([new Uint8Array([tag]), u32(body.length), body]);
    const i64 = (value) => { const b = new Uint8Array(8); new DataView(b.buffer).setBigInt64(0, value, true); return b; };
    const utc = { name: "UTC", from_ms: -(1n << 63n), until_ms: (1n << 63n) - 1n, offsets: [{ from_ms: -(1n << 63n), minutes: 0 }] };
    const facts = [section(7, i64(0n)), section(8, new Uint8Array(16)), section(9, join([u32(1), str("en-US")])), section(10, join([str("UTC"), i64(utc.from_ms), i64(utc.until_ms), u32(1), i64(utc.from_ms), u32(0)])), section(11, new Uint8Array([1, 0, 0, 0, 0])), section(13, join([new Uint8Array([0]), str(""), str("div")]))];
    const bootBytes = (url = "/", storage = [1, 0, 0, 0, 0]) => join([section(1, str(url)), section(2, new Uint8Array(storage)), section(3, new Uint8Array([1])), section(4, new Uint8Array([1])), section(6, new Uint8Array()), ...facts]);
    // Malformed boot bytes: a section header that runs past the end.
    const x1 = await fresh();
    x1.boot_keys();
    const p1 = x1.payload_reserve(3);
    new Uint8Array(x1.memory.buffer, p1, 3).set([9, 0, 0]);
    try {
      x1.init();
      out.boot = "accepted";
    } catch (_) {
      out.boot = [x1.fault(), text(x1)];
    }
    // An unknown boot section.
    const x2 = await fresh();
    x2.boot_keys();
    const p2 = x2.payload_reserve(8);
    new Uint8Array(x2.memory.buffer, p2, 8).set([0, 0, 0, 0, 0, 0, 0, 0]);
    try {
      x2.init();
      out.flags = "accepted";
    } catch (_) {
      out.flags = [x2.fault(), text(x2)];
    }
    // A storage value that is not UTF-8, on the effect node.
    const x3 = await fresh();
    x3.boot_keys();
    x3.payload_reserve(0);
    x3.init();
    const explicit = await fresh(); explicit.boot_keys();
    const defaultBytes = bootBytes();
    const defaultPtr = explicit.payload_reserve(defaultBytes.length);
    new Uint8Array(explicit.memory.buffer, defaultPtr, defaultBytes.length).set(defaultBytes);
    explicit.init();
    const batch = (x) => Array.from(new Uint8Array(x.memory.buffer, x.cmd_ptr(), x.cmd_len()));
    const work = (x) => Array.from(new Uint8Array(x.memory.buffer, x.work_ptr(), x.work_len()));
    out.emptyDefault = JSON.stringify([batch(x3), work(x3)]) === JSON.stringify([batch(explicit), work(explicit)]);
    explicit.drop();
    const p3 = x3.payload_reserve(2);
    new Uint8Array(x3.memory.buffer, p3, 2).set([3, 0xff]);
    try {
      x3.event(0xffffffff, 1);
      out.utf8 = "accepted";
    } catch (_) {
      out.utf8 = [x3.fault(), text(x3)];
    }
    // A row template with 256 children: a resource limit, not a wrap.
    const x4 = await fresh();
    x4.boot_keys();
    const boot = bootBytes("/#limit-children");
    const p4 = x4.payload_reserve(boot.length);
    new Uint8Array(x4.memory.buffer, p4, boot.length).set(boot);
    try {
      x4.init();
      out.wide = "accepted";
    } catch (_) {
      out.wide = [x4.fault(), text(x4)];
    }
    // Every section rejection names the section rather than a trailing-byte
    // error in an unrelated value.
    out.sections = [];
    const location = section(1, str("/")), storage = section(2, new Uint8Array([1, 0, 0, 0, 0])), online = section(3, new Uint8Array([1])), visible = section(4, new Uint8Array([1]));
    const cases = [
      [join([section(99, new Uint8Array()), storage, online, visible]), 1],
      [join([location, location, storage, online, visible]), 2],
      [join([location, online, storage, visible]), 2],
      [join([location, storage, online]), 4],
      [join([section(1, new Uint8Array([3, 0, 0, 0, 65])), storage, online, visible]), 1],
      [join([section(1, join([str("/"), new Uint8Array([0])])), storage, online, visible]), 1],
      [join([location, section(2, join([new Uint8Array([0]), u32(1), str("saved"), str("x")])), online, visible]), 2],
      [join([location, section(2, join([new Uint8Array([1]), u32(1), str("undeclared"), str("x")])), online, visible, section(6, new Uint8Array()), ...facts]), 2],
    ];
    for (const [bytes, tag] of cases) {
      const x = await fresh(); x.boot_keys();
      const p = x.payload_reserve(bytes.length); new Uint8Array(x.memory.buffer, p, bytes.length).set(bytes);
      try { x.init(); out.sections.push(false); } catch (_) { out.sections.push(x.fault() === 1 && text(x).includes(`section ${tag}`)); }
    }
    // Capture staging independently of command application.
    const empty = await fresh();
    let emptyBytes, declarationsPtr, initialized = false;
    const declarations = join([section(2, join([u32(1), str("saved")])), section(5, u32(0)), section(6, u32(0)), section(10, new Uint8Array([110, 1])), section(11, u32(0)), __protocolFixtureSection]);
    const capture = { ...empty,
      boot_keys: () => { declarationsPtr = empty.payload_reserve(declarations.length); new Uint8Array(empty.memory.buffer, declarationsPtr, declarations.length).set(declarations); },
      cmd_ptr: () => declarationsPtr,
      cmd_len: () => initialized ? 0 : declarations.length,
      init: () => { emptyBytes = new Uint8Array(empty.memory.buffer, capture.ptr, capture.len).slice(); initialized = true; },
      payload_reserve: (n) => { capture.len = n; capture.ptr = empty.payload_reserve(n); return capture.ptr; },
    };
    const rt = new RocEngineRuntime(capture, document.createElement("div"), { window: { location: { pathname: "/test", search: "?a=1", hash: "#h" } }, storage: { getItem: (key) => key === "saved" ? "seed" : null }, sessionStorage: { getItem: () => null }, environment: { online: () => false, visible: () => true, now: () => 0n, seed: () => new Uint8Array(16), languages: () => ["en-US"], timeZone: () => utc } });
    rt.mount();
    out.layout = Array.from(emptyBytes);
    out.expectedLayout = Array.from(join([section(1, str("/test?a=1#h")), section(2, join([new Uint8Array([1]), u32(1), str("saved"), str("seed")])), section(3, new Uint8Array([0])), visible, section(6, new Uint8Array()), ...facts]));
    rt.unmount();
    const keys = section(2, u32(0)), ports = section(5, u32(0));
    out.declarations = [];
    for (const bytes of [new Uint8Array(), join([section(99, u32(0)), ports]), join([keys, keys, ports]), join([ports, keys]), keys, join([section(2, new Uint8Array([1])), ports]), join([section(2, join([u32(0), new Uint8Array([0])])), ports]), join([keys, section(5, join([u32(1), str("port"), new Uint8Array([9, 0]), u32(0)]))])]) {
      let mounted = false;
      const memory = new WebAssembly.Memory({ initial: 1 });
      new Uint8Array(memory.buffer).set(bytes);
      const exports = { memory, protocol_version: () => PROTOCOL_VERSION, boot_keys: () => {}, cmd_ptr: () => 0, cmd_len: () => bytes.length, init: () => { mounted = true; } };
      try { new RocEngineRuntime(exports, document.createElement("div")).mount(); out.declarations.push(false); }
      catch (error) { out.declarations.push(!mounted && error.message.includes("declaration section")); }
    }
    return out;
  });
  check("host reports the protocol version the runtime implements", raw.version[0], raw.version[1]);
  check("a module of another protocol is refused before it runs", raw.refused, [true, 0]);
  check("truncated boot bytes: contract fault names a section", raw.boot[0] === 1 && raw.boot[1].startsWith("contract: boot section"), true);
  check("unknown boot section: contract fault", raw.flags[0] === 1 && raw.flags[1].includes("section"), true);
  check("empty boot bytes match all defaults including URL /", raw.emptyDefault, true);
  check("non-UTF-8 effect result: contract fault", raw.utf8, [1, "contract: effect result text is not UTF-8"]);
  check("a row template with 256 children: resource_limit fault", raw.wide, [2, "resource_limit: a row template's children of one element is 256; the template encoding allows at most 255"]);
  check("every malformed section is a named contract fault", raw.sections, Array(8).fill(true));
  check("runtime stages exactly the declared boot sections", raw.layout, raw.expectedLayout);
  check("unreadable declarations refuse mount before init", raw.declarations, Array(8).fill(true));
  await ctx.close();
}

// Environment readers refuse invalid mounts, then run again on the real
// subscription events. A failing live read is an executor fault.
{
  const { page, ctx } = await open();
  const out = await page.evaluate(async () => {
    const { RocEngineRuntime, pageImports } = await import("./runtime.mjs");
    const module = await WebAssembly.compile(await (await fetch("app.wasm")).arrayBuffer());
    const fresh = async (environment) => {
      const x = (await WebAssembly.instantiate(module, pageImports(module))).exports;
      const root = document.createElement("div"); document.body.append(root);
      return new RocEngineRuntime(x, root, { environment });
    };
    const rejected = [];
    for (const environment of [null, [], "online", { typo: () => true }, { online: true }, { online: () => { throw new Error("boot reader failed"); } }, { visible: () => "visible" }]) {
      let runtime;
      try { runtime = await fresh(environment); runtime.mount(); rejected.push(false); } catch (_) { rejected.push(true); }
    }
    let online = false, visible = false, onlineReads = 0, visibleReads = 0, fail = false;
    const rt = await fresh({ online: () => { onlineReads += 1; if (fail) throw new Error("live reader failed"); return online; }, visible: () => { visibleReads += 1; return visible; } });
    rt.mount();
    const text = (id) => rt.root.querySelector(`[data-testid="${id}"]`).textContent;
    const boot = [text("online"), text("visible"), onlineReads, visibleReads];
    online = true; visible = true;
    window.dispatchEvent(new Event("online")); document.dispatchEvent(new Event("visibilitychange"));
    await new Promise((resolve) => requestAnimationFrame(() => setTimeout(resolve, 0)));
    const live = [text("online"), text("visible"), onlineReads, visibleReads];
    fail = true; window.dispatchEvent(new Event("offline"));
    const fault = [rt.poisoned.class, rt.poisoned.message];
    rt.unmount();
    let badType = false;
    const wrong = await fresh({ visible: () => badType ? "hidden" : true });
    wrong.mount(); badType = true;
    document.dispatchEvent(new Event("visibilitychange"));
    const wrongType = [wrong.poisoned.class, wrong.poisoned.message];
    wrong.unmount();
    return { rejected, boot, live, fault, wrongType };
  });
  check("invalid environment readers refuse the mount", out.rejected, Array(7).fill(true));
  check("environment readers supply boot facts", out.boot, ["offline", "hidden", 1, 1]);
  check("environment readers supply later subscription results and the report scheduler's visibility", out.live, ["online", "visible", 2, 4]);
  check("a reader that throws later is an executor fault", out.fault, ["executor", "live reader failed"]);
  check("a reader that answers the wrong type later is an executor fault", out.wrongType, ["executor", "options.environment.visible must answer a boolean"]);
  await ctx.close();
}

// Connectivity events from different browser tasks meet before one frame,
// and the delivered value stays the one captured at the last event.
{
  const { page, ctx } = await open(`
    window.__reportFrames = new Map(); window.__reportFrameId = 0;
    window.requestAnimationFrame = (fn) => { const id = ++window.__reportFrameId; window.__reportFrames.set(id, fn); return id; };
    window.cancelAnimationFrame = (id) => window.__reportFrames.delete(id);
    window.__reportTimers = new Map(); window.__reportTimerId = 0;
    const set = window.setTimeout, clear = window.clearTimeout;
    window.setTimeout = (fn, ms, ...args) => {
      if (ms !== 100) return set(fn, ms, ...args);
      const id = --window.__reportTimerId; window.__reportTimers.set(id, () => fn(...args)); return id;
    };
    window.clearTimeout = (id) => { if (!window.__reportTimers.delete(id)) clear(id); };
    window.__onlineReport = true;
    Object.defineProperty(navigator, "onLine", { get: () => window.__onlineReport, configurable: true });
  `);
  const got = await page.evaluate(async () => {
    const rt = window.__rt;
    const before = rt.workRecord().counters;
    await new Promise((resolve) => {
      const channel = new MessageChannel(); let events = 0;
      channel.port1.onmessage = () => {
        window.__onlineReport = events++ !== 0;
        window.dispatchEvent(new Event(window.__onlineReport ? "online" : "offline"));
        if (events === 2) { channel.port1.close(); channel.port2.close(); resolve(); }
        else channel.port2.postMessage(null);
      };
      channel.port2.postMessage(null);
    });
    const waiting = [Number(rt.workRecord().counters[30] - before[30]), rt.reportsReplaced, rt.queue.length];
    window.__onlineReport = false;
    for (const callback of [...window.__reportFrames.values()]) callback();
    return [waiting, document.querySelector('[data-testid="online"]').textContent, Number(rt.workRecord().counters[30] - before[30]), Number(rt.workRecord().counters[33] - before[33]), rt.reportSources.size, window.__reportTimers.size];
  });
  check("connectivity from separate tasks delivers one captured newest report at the frame", got, [[0, 1, 1], "online", 1, 1, 0, 0]);
  await ctx.close();
}

// A page whose localStorage throws, as with site data disabled.
{
  const { page, ctx } = await open("Object.defineProperty(window, 'localStorage', { get: () => { throw new DOMException('denied', 'SecurityError'); }, configurable: true })");
  const got = await page.evaluate(() => document.querySelector('[data-testid="storage"]').textContent);
  check("boot carries storage availability (localStorage throws)", got, "storage unavailable");
  await ctx.close();
}

// The ingress bound.
{
  const { page, ctx } = await open();
  const r = await page.evaluate(async () => {
    const { MAX_QUEUED } = await import("./runtime.mjs");
    const rt = window.__rt;
    rt.busy = true;
    for (let i = 0; i <= MAX_QUEUED; i += 1) rt.dispatch(1, 0, "");
    rt.busy = false;
    return [rt.poisoned && rt.poisoned.class, rt.queue.length, rt.poisoned && rt.poisoned.message.startsWith("resource_limit:")];
  });
  check("queue overflow poisons with resource_limit and drops the queue", r, ["resource_limit", 0, true]);
  await ctx.close();
}

// Submit, selects, connectivity, visibility and the work record.
{
  const { page, ctx } = await open("Object.defineProperty(navigator, 'onLine', { get: () => false, configurable: true })");
  const text = (id) => page.evaluate((id) => document.querySelector(`[data-testid="${id}"]`).textContent, id);
  check("boot carries connectivity (booted offline)", await text("online"), "offline");
  check("boot carries storage availability (available)", await text("storage"), "storage available");
  await page.evaluate(async () => {
    Object.defineProperty(navigator, "onLine", { get: () => true, configurable: true });
    window.dispatchEvent(new Event("online"));
    await new Promise((resolve) => requestAnimationFrame(() => setTimeout(resolve, 0)));
  });
  check("online event reaches the subscription", await text("online"), "online");
  await page.evaluate(() => {
    Object.defineProperty(document, "visibilityState", { get: () => "hidden", configurable: true });
    document.dispatchEvent(new Event("visibilitychange"));
  });
  check("visibilitychange reaches the subscription and disposes the poll", [await text("visible"), await page.evaluate(() => window.__rt.intervals(5000).length)], ["hidden", 0]);
  const submit = await page.evaluate(() => {
    let prevented = null;
    window.addEventListener("submit", (e) => (prevented = e.defaultPrevented));
    const before = location.href;
    document.querySelector("form").requestSubmit();
    return [prevented, location.href === before, document.querySelector("[data-testid=submitted]").textContent];
  });
  check("submit is default-prevented and reaches the app", submit, [true, true, "1"]);
  const shade = await page.evaluate(() => {
    const sel = document.querySelector("[aria-label=Shade]");
    return [sel.value, sel.options.length];
  });
  check("select value re-applied after its options mount", shade, ["teal", 3]);
  const work = await page.evaluate(() => {
    const rt = window.__rt;
    const before = rt.workRecord().counters;
    document.querySelector("[aria-label=Press]").click();
    const after = rt.workRecord().counters;
    const viaMetric = rt.x.metric(16 + 12);
    return [after.length, String(after[12] - before[12]), String(viaMetric) === String(after[12]), String(after[1])];
  });
  check("work record: 49 counters (work, effects, ports, properties, releases, observations, guards, progress and comments); one SETTEXT for one click; metric(16 + k) reads counter k", work, [49, "1", true, "3"]);
  await ctx.close();
}

await browser.close();
server.close();
console.log(failures === 0 ? "== services contract: all pass" : `== services contract: ${failures} failures`);
process.exit(failures === 0 ? 0 : 1);
