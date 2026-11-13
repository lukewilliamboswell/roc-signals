// Layout wire declarations, observation ownership and real browser reports.
// The engine's decoders and the native model are checked independently.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";

const options = parseArgs(process.argv.slice(2), ["runner"]);
if (!options.runner) throw new Error("--runner TABLE_RUNNER is required for layout replay contracts");
const here = path.dirname(fileURLToPath(import.meta.url));
const files = runtimeFiles(options.runtime);
const server = http.createServer((request, response) => {
  const name = path.basename(new URL(request.url, "http://x").pathname);
  if (!name) { response.writeHead(200, { "content-type": "text/html" }); response.end("<!doctype html><style>body{margin:0}</style>"); return; }
  if (name === "app.wasm") { response.writeHead(200, { "content-type": "application/wasm" }); response.end(fs.readFileSync(options.wasm)); return; }
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
    const { RocEngineRuntime, PROTOCOL_VERSION } = await import("/runtime.mjs");
    const encoder = new TextEncoder();
    const join = (...parts) => { const out = new Uint8Array(parts.reduce((n, part) => n + part.length, 0)); let at = 0; for (const part of parts) { out.set(part, at); at += part.length; } return out; };
    const u32 = (n) => { const out = new Uint8Array(4); new DataView(out.buffer).setUint32(0, n, true); return out; };
    const str = (text) => { const bytes = encoder.encode(text); return join(u32(bytes.length), bytes); };
    const section = (tag, bytes) => join([tag], u32(bytes.length), bytes);
    window.__layoutFixture = (options = {}) => {
      const root = document.createElement("main"); document.body.append(root);
      const memory = new WebAssembly.Memory({ initial: 2 }); let length = 0;
      const exports = { memory, cmd_ptr: () => 0, cmd_len: () => length, files_released: () => 0, metric: () => 0n, work_len: () => 0, fault: () => 0, drop: () => {} };
      const rt = new RocEngineRuntime(exports, root, options);
      const calls = []; rt.deliver = (node, handler, bytes) => calls.push({ node, handler, bytes: typeof bytes === "string" ? bytes : [...bytes] });
      const raw = (...parts) => { const bytes = join(...parts); if (bytes.length > memory.buffer.byteLength) memory.grow(Math.ceil((bytes.length - memory.buffer.byteLength) / 65536)); new Uint8Array(memory.buffer).set(bytes); length = bytes.length; rt.busy = true; try { rt.apply(); } finally { rt.busy = false; length = 0; } rt.drainQueue(); };
      const elem = (id, parent, tag) => join([8], u32(id), u32(parent), u32(0), str(tag));
      const attr = (id, name, value) => join([9], u32(id), str(name), [1], str(value));
      const listen = (id, handler, type, kind, policies = 8) => join([11], u32(id), u32(handler), str(type), [kind], u32(policies));
      const release = (id) => join([23], u32(id));
      const remove = (id) => join([5], u32(id));
      const ref = (id, ...parts) => join([18, 7], u32(id), ...parts);
      const end = () => { rt.unmount(); root.remove(); };
      return { rt, root, calls, raw, elem, attr, listen, release, remove, ref, u32, str, join, section, end };
    };
    window.__layoutFrame = () => new Promise((resolve) => requestAnimationFrame(() => setTimeout(resolve, 0)));
    window.__fakeLayout = () => {
      const instances = [];
      class Observer {
        constructor(callback, options) { this.callback = callback; this.options = options ?? {}; this.targets = new Set(); this.unobserved = []; this.disconnected = false; instances.push(this); }
        observe(element) { this.targets.add(element); }
        unobserve(element) { this.targets.delete(element); this.unobserved.push(element); }
        disconnect() { this.targets.clear(); this.disconnected = true; }
      }
      return { instances, window: { ResizeObserver: Observer, IntersectionObserver: Observer, getComputedStyle: getComputedStyle.bind(window), requestAnimationFrame: requestAnimationFrame.bind(window), cancelAnimationFrame: cancelAnimationFrame.bind(window), document, navigator } };
    };
    window.__mediaFixture = (queries, environment, declarationOverride) => {
      const memory = new WebAssembly.Memory({ initial: 2 });
      let staged = null, initialized = false;
      const declarations = declarationOverride ?? join(section(2, u32(0)), section(5, u32(0)), section(6, join(u32(queries.length), ...queries.map(str))));
      new Uint8Array(memory.buffer).set(declarations);
      const exports = { memory, protocol_version: () => PROTOCOL_VERSION, boot_keys: () => {}, cmd_ptr: () => 0, cmd_len: () => initialized ? 0 : declarations.length, files_released: () => 0, metric: () => 0n, work_len: () => 0, fault: () => 0, drop: () => {},
        payload_reserve: (length) => { staged = { start: 65536, length }; return staged.start; }, init: () => { initialized = true; } };
      const root = document.createElement("div"); document.body.append(root);
      const rt = new RocEngineRuntime(exports, root, { manualEffects: true, environment });
      const calls = []; rt.deliver = (node, handler, bytes) => calls.push([node, handler, [...bytes]]);
      return { rt, calls, memory, get staged() { return staged; }, end: () => { rt.unmount(); root.remove(); } };
    };
  });

  const declared = await page.evaluate(() => {
    const f = __layoutFixture({ manualEffects: true });
    f.raw(f.elem(1, 0, "div"), f.listen(1, 2, "size", 7), f.listen(1, 3, "seen", 8, 40));
    const element = f.rt.statics[1];
    const before = [f.rt.observations.size, f.rt.observationOwners.size, f.rt.layoutObservers.size, f.rt.listening.has("size"), f.rt.listening.has("seen")];
    f.rt.injectLayout(element, 7, { width: 400, height: 200 });
    f.rt.injectLayout(element, 7, { width: 420, height: 240 });
    f.rt.injectLayout(element, 8, { intersecting: false, ratio_permille: 0 });
    f.rt.injectLayout(element, 8, { intersecting: true, ratio_permille: 375 });
    const held = [f.calls.length, f.rt.queue.length, f.rt.reportsReplaced];
    f.rt.releaseReports();
    const result = [before, held, f.calls]; f.raw(f.release(1), f.remove(1)); f.end(); return result;
  });
  check("manual size and seen are distinct reports, with no DOM listener or real observer", declared, [[1, 1, 0, false, false], [0, 2, 2], [{ node: 1, handler: 2, bytes: [164, 1, 0, 0, 240, 0, 0, 0] }, { node: 1, handler: 3, bytes: [1, 119, 1] }]]);

  const routing = await page.evaluate(() => {
    const fake = __fakeLayout(), f = __layoutFixture({ window: fake.window });
    const { join, str, u32 } = f;
    const tree = join([1], str("section"), [0, 1, 1], str("div"), [0, 0]);
    const hole = (handler, type, kind) => join([3, 1, 0, handler], str(type), [kind], u32(8));
    const reference = [5, 1, 0];
    const template = join(tree, [3], hole(0, "size", 7), hole(1, "seen", 8), reference);
    f.raw(join([7], u32(1), u32(template.length), template), join([1], u32(7), u32(0), u32(0), u32(1), u32(9)));
    const target = f.rt.statics[9], owner = f.rt.statics[7];
    const registered = [fake.instances.length, f.rt.observationOwners.get(owner).size, f.rt.observations.get(target).size];
    fake.instances[0].callback([{ target, contentRect: { width: 10, height: 20 } }]);
    fake.instances[1].callback([{ target, isIntersecting: true, intersectionRatio: 1 }]); f.rt.releaseReports();
    const calls = f.calls.slice();
    fake.instances[1].callback([{ target, isIntersecting: false, intersectionRatio: 0 }]);
    f.raw(f.release(7), f.remove(7)); f.rt.releaseReports();
    const result = [registered, calls, f.calls.length, f.rt.observations.size, f.rt.observationOwners.size, fake.instances.map((observer) => observer.unobserved.length)]; f.end(); return result;
  });
  check("a referenced row descendant routes through its row root and one RELEASE unobserves both kinds", routing, [[2, 2, 2], [{ node: 7, handler: 0, bytes: [10, 0, 0, 0, 20, 0, 0, 0] }, { node: 7, handler: 1, bytes: [1, 232, 3] }], 2, 0, 0, [1, 1]]);

  const callback = await page.evaluate(() => {
    const fake = __fakeLayout(), f = __layoutFixture({ window: fake.window });
    f.raw(f.elem(1, 0, "div"), f.elem(2, 0, "div"), f.listen(1, 0, "size", 7), f.listen(2, 1, "size", 7), f.listen(1, 2, "seen", 8), f.listen(2, 3, "seen", 8, 40));
    const first = f.rt.statics[1], second = f.rt.statics[2];
    fake.instances[0].callback([{ target: first, contentRect: { width: 1.4, height: 2.5 } }, { target: first, contentRect: { width: 3.5, height: -2 } }, { target: second, contentRect: { width: 1e20, height: 6 } }]);
    const result = [fake.instances.length, fake.instances.map((observer) => observer.options), f.calls, f.rt.queue.length]; f.end(); return result;
  });
  check("one shared size observer coalesces a callback and drains before return; seen has two margin modes", callback, [3, [{}, {}, { rootMargin: "100%", scrollMargin: "100%" }], [{ node: 1, handler: 0, bytes: [4, 0, 0, 0, 0, 0, 0, 0] }, { node: 2, handler: 1, bytes: [255, 255, 255, 255, 6, 0, 0, 0] }], 0]);

  const lifecycle = await page.evaluate(() => {
    const fake = __fakeLayout(), f = __layoutFixture({ window: fake.window });
    f.raw(f.elem(1, 0, "div"), f.elem(2, 0, "div"), f.listen(1, 0, "size", 7), f.listen(2, 1, "seen", 8));
    const old = f.rt.statics[1];
    f.raw(f.release(1), f.remove(1), f.elem(1, 0, "div"), f.listen(1, 2, "size", 7));
    fake.instances[0].callback([{ target: old, contentRect: { width: 1, height: 1 } }, { target: f.rt.statics[1], contentRect: { width: 8, height: 9 } }]);
    const result = [fake.instances.length, f.calls, fake.instances[0].unobserved.length];
    f.end(); result.push(fake.instances.every((observer) => observer.disconnected)); return result;
  });
  check("RELEASE leaves other observations live; old callbacks cannot target a reused node id; teardown disconnects", lifecycle, [2, [{ node: 1, handler: 2, bytes: [8, 0, 0, 0, 9, 0, 0, 0] }], 1, true]);

  const malformed = await page.evaluate(() => {
    const cases = [["size", 7, 0], ["scroll", 6, 40], ["size", 7, 9], ["seen", 8, 42], ["resize", 7, 8], ["intersection", 8, 8], ["scroll", 7, 8], ["seen", 8, 72]];
    return cases.map(([type, kind, policies]) => {
      const f = __layoutFixture({ manualEffects: true }); let rejected = false;
      try { f.raw(f.elem(1, 0, "div"), f.listen(1, 0, type, kind, policies)); } catch (_) { rejected = true; }
      f.end(); return rejected;
    });
  });
  check("layout kinds reject mismatched events and closed policy combinations", malformed, Array(8).fill(true));

  const media = await page.evaluate(() => {
    const dark = new EventTarget(); dark.matches = true;
    const reduced = new EventTarget(); reduced.matches = false;
    const queried = [];
    const f = __mediaFixture(["dark", "reduced"], { matchMedia: (query) => { queried.push(query); return query === "dark" ? dark : reduced; } });
    f.rt.mount();
    const bytes = new Uint8Array(f.memory.buffer, f.staged.start, f.staged.length);
    let at = 0, flags;
    while (at < bytes.length) { const tag = bytes[at], size = new DataView(bytes.buffer, bytes.byteOffset + at + 1, 4).getUint32(0, true); if (tag === 6) flags = [...bytes.slice(at + 5, at + 5 + size)]; at += 5 + size; }
    f.rt.perform({ op: "media", id: 1, query: "dark" });
    dark.matches = false; dark.dispatchEvent(new Event("change")); dark.matches = true; dark.dispatchEvent(new Event("change"));
    const before = [f.calls.length, f.rt.reportsReplaced]; f.rt.releaseReports();
    const calls = f.calls.slice(); f.rt.cancel(1); dark.matches = false; dark.dispatchEvent(new Event("change")); f.rt.releaseReports();
    const result = [flags, queried, before, calls, f.calls.length, f.rt.live.size]; f.end(); return result;
  });
  check("declared media reads boot in order and change is a cancellable replaceable subscription", media, [[1, 0], ["dark", "reduced", "dark"], [0, 1], [[4294967295, 1, [22, 1]]], 1, 0]);

  const mediaSnapshot = await page.evaluate(() => {
    let reads = 0;
    const query = new EventTarget(); Object.defineProperty(query, "matches", { get: () => { reads += 1; return reads === 1 ? false : true; } });
    const f = __mediaFixture(["q"], { matchMedia: () => query }); f.rt.mount();
    const bytes = new Uint8Array(f.memory.buffer, f.staged.start, f.staged.length);
    const result = [reads, bytes.at(-1)]; f.end(); return result;
  });
  check("a media boot snapshot reads and validates its match exactly once", mediaSnapshot, [1, 0]);

  const badMedia = await page.evaluate(() => {
    const results = [];
    for (const queries of [[""], ["x".repeat(257)], ["same", "same"], Array.from({ length: 33 }, (_, i) => `q${i}`)]) {
      const f = __mediaFixture(queries, { matchMedia: () => ({ matches: true, addEventListener() {}, removeEventListener() {} }) });
      try { f.rt.mount(); results.push(false); } catch (error) { results.push(error.message.includes("declaration section 6")); } f.end();
    }
    for (const reader of [() => { throw new Error("no reader"); }, () => ({ matches: 1, addEventListener() {}, removeEventListener() {} }), () => ({ matches: true })]) {
      const f = __mediaFixture(["q"], { matchMedia: reader });
      try { f.rt.mount(); results.push(false); } catch (_) { results.push(true); } f.end();
    }
    return results;
  });
  check("media declaration bounds and failed or malformed boot readers refuse mount", badMedia, Array(7).fill(true));

  const mediaWire = await page.evaluate(() => {
    const query = new EventTarget(); query.matches = false;
    const f = __layoutFixture({ manualEffects: true, environment: { matchMedia: () => query } });
    f.rt.mediaQueries = ["q"];
    f.raw(f.join([13], f.u32(7), [16], f.str("q")));
    query.matches = true; query.dispatchEvent(new Event("change")); f.rt.releaseReports();
    f.raw(f.join([14], f.u32(7)));
    query.matches = false; query.dispatchEvent(new Event("change")); f.rt.releaseReports();
    const result = [f.calls, f.rt.live.size]; f.end(); return result;
  });
  check("FX16 decodes the query and CANCEL removes the real change listener", mediaWire, [[{ node: 4294967295, handler: 7, bytes: [22, 1] }], 0]);

  const mediaCancellation = await page.evaluate(() => {
    const query = new EventTarget(); query.matches = false;
    const f = __layoutFixture({ manualEffects: true, environment: { matchMedia: () => query } }); f.rt.mediaQueries = ["q"];
    f.rt.perform({ op: "media", id: 1, query: "q" }); query.matches = true; query.dispatchEvent(new Event("change"));
    const before = f.rt.queue.length; f.rt.cancel(1); f.rt.releaseReports(); const result = [before, f.calls.length, f.rt.queue.length, f.rt.reportSources.size]; f.end(); return result;
  });
  check("cancelling a media subscription drops a waiting report without delivery", mediaCancellation, [1, 0, 0, 0]);

  const faults = await page.evaluate(() => {
    const fake = __fakeLayout(), f = __layoutFixture({ window: fake.window });
    f.raw(f.elem(1, 0, "div"), f.listen(1, 0, "size", 7));
    fake.instances[0].callback([{ target: f.rt.statics[1], contentRect: { width: NaN, height: 2 } }]);
    const result = [f.rt.poisoned.class, f.rt.observations.size, fake.instances[0].disconnected]; f.end();
    const query = new EventTarget(); query.matches = false;
    const m = __layoutFixture({ manualEffects: true, environment: { matchMedia: () => query } }); m.rt.mediaQueries = ["q"];
    m.rt.perform({ op: "media", id: 1, query: "q" }); query.matches = "invalid"; query.dispatchEvent(new Event("change"));
    result.push(m.rt.poisoned.class, m.rt.live.size); m.end(); return result;
  });
  check("nonfinite layout and malformed later media facts are executor faults and release retained work", faults, ["executor", 0, true, "executor", 0]);

  const fanout = await page.evaluate(() => {
    const fake = __fakeLayout(), f = __layoutFixture({ window: fake.window });
    const commands = [], entries = [];
    for (let id = 1; id <= 4100; id += 1) commands.push(f.elem(id, 0, "div"), f.listen(id, 0, "size", 7));
    f.raw(...commands);
    for (let id = 1; id <= 4100; id += 1) entries.push({ target: f.rt.statics[id], contentRect: { width: id, height: 1 } });
    fake.instances[0].callback(entries);
    const result = [f.rt.observations.size, fake.instances.length, f.calls.length, f.rt.queue.length, f.rt.poisoned];
    f.end(); return result;
  });
  check("data-sized observation fanout drains a full report queue without an observation cap", fanout, [4100, 1, 4100, 0, null]);

  const scroll = await page.evaluate(async () => {
    const f = __layoutFixture({ manualEffects: true });
    f.raw(f.elem(1, 0, "div"), f.attr(1, "style", "height:80px;width:100px;overflow:auto;overflow-anchor:none"), f.elem(2, 1, "div"), f.attr(2, "style", "height:800px;width:1000px"), f.listen(1, 0, "scroll", 6));
    const element = f.rt.statics[1]; f.rt.expectManualScroll(element, { top: 125, left: 75 }); element.scrollTo({ top: 125, left: 75, behavior: "instant" }); await __layoutFrame(); f.rt.checkManualScrolls();
    const held = [f.calls.length, f.rt.queue.length]; f.rt.releaseReports();
    const first = f.calls.slice(); const replaced = f.rt.reportsReplaced;
    f.rt.expectManualScroll(element, { top: 125, left: 75 }); element.scrollTo({ top: 125, left: 75, behavior: "instant" }); await __layoutFrame(); f.rt.checkManualScrolls(); f.rt.releaseReports();
    const result = [held, first, f.calls.length, f.rt.reportsReplaced === replaced]; f.end(); return result;
  });
  check("real scroll reports capture unsigned CSS pixels; setting the same position raises no report", scroll, [[0, 1], [{ node: 1, handler: 0, bytes: [125, 0, 0, 0, 75, 0, 0, 0] }], 1, true]);

  const textScroll = await page.evaluate(async () => {
    const f = __layoutFixture({ manualEffects: true });
    f.raw(f.elem(1, 0, "div"), f.attr(1, "style", "height:50px;width:100px;overflow:auto"), f.elem(3, 1, "div"), f.attr(3, "style", "height:500px"), f.listen(1, 1, "scroll", 1, 0), f.elem(2, 0, "div"), f.listen(2, 2, "size", 7));
    f.rt.injectLayout(f.rt.statics[2], 7, { width: 20, height: 10 });
    f.rt.expectManualScroll(f.rt.statics[1], { top: 40, left: 0 }); f.rt.statics[1].scrollTop = 40; await __layoutFrame(); f.rt.checkManualScrolls();
    f.rt.injectLayout(f.rt.statics[2], 7, { width: 30, height: 10 });
    const before = [f.calls.slice(), f.rt.queue.length]; f.rt.releaseReports();
    const result = [before, f.calls]; f.end(); return result;
  });
  check("a generic text scroll stays an occurrence and drains earlier reports while later reports remain held", textScroll, [[[{ node: 2, handler: 2, bytes: [20, 0, 0, 0, 10, 0, 0, 0] }, { node: 1, handler: 1, bytes: "" }], 1], [{ node: 2, handler: 2, bytes: [20, 0, 0, 0, 10, 0, 0, 0] }, { node: 1, handler: 1, bytes: "" }, { node: 2, handler: 2, bytes: [30, 0, 0, 0, 10, 0, 0, 0] }]]);

  const rtl = await page.evaluate(async () => {
    const f = __layoutFixture({ manualEffects: true });
    f.raw(f.elem(1, 0, "div"), f.attr(1, "style", "direction:rtl;height:80px;width:100px;overflow:auto;overflow-anchor:none"), f.elem(2, 1, "div"), f.attr(2, "style", "height:800px;width:1000px"), f.listen(1, 0, "scroll", 6));
    const element = f.rt.statics[1]; f.rt.expectManualScroll(element, { top: 0, left: 90 }); element.scrollTo({ left: -90, behavior: "instant" }); await __layoutFrame(); f.rt.checkManualScrolls(); f.rt.releaseReports();
    const direct = f.calls.slice(); f.calls.length = 0;
    f.raw(f.ref(1, [1, 3], f.u32(140), [1])); await __layoutFrame(); f.rt.checkManualScrolls(); f.rt.releaseReports();
    const command = f.calls.slice(); const result = [direct, command, element.scrollLeft, f.rt.scrollPosition(element)]; f.end(); return result;
  });
  check("RTL scroll and ScrollTo expose positive distance from the start edge", rtl, [[{ node: 1, handler: 0, bytes: [0, 0, 0, 0, 90, 0, 0, 0] }], [{ node: 1, handler: 0, bytes: [0, 0, 0, 0, 140, 0, 0, 0] }], -140, { top: 0, left: 140 }]);

  const rtlEnd = await page.evaluate(async () => {
    const f = __layoutFixture();
    f.raw(f.elem(1, 0, "div"), f.attr(1, "style", "direction:rtl;height:80px;width:100px;overflow:auto"), f.elem(2, 1, "div"), f.attr(2, "style", "height:800px;width:1000px"), f.listen(1, 0, "scroll", 6));
    f.raw(f.ref(1, [0, 2, 1])); await __layoutFrame(); await __layoutFrame();
    const element = f.rt.statics[1], maximum = element.scrollWidth - element.clientWidth;
    const payload = f.calls.at(-1).bytes;
    const result = [element.scrollLeft === -maximum, f.rt.scrollPosition(element).left === maximum, new DataView(new Uint8Array(payload).buffer).getUint32(4, true) === maximum]; f.end(); return result;
  });
  check("production RTL End resolves the browser's maximum start-edge distance", rtlEnd, [true, true, true]);

  const negative = await page.evaluate(() => {
    const f = __layoutFixture({ manualEffects: true }); f.raw(f.elem(1, 0, "div"), f.listen(1, 0, "scroll", 6));
    const element = f.rt.statics[1]; Object.defineProperty(element, "scrollTop", { value: -17.2 }); Object.defineProperty(element, "scrollLeft", { value: -2 });
    element.dispatchEvent(new Event("scroll")); f.rt.releaseReports(); const result = f.calls; f.end(); return result;
  });
  check("negative reverse-layout or overscroll offsets clamp to zero", negative, [{ node: 1, handler: 0, bytes: [0, 0, 0, 0, 0, 0, 0, 0] }]);

  const reverse = await page.evaluate(async () => {
    const f = __layoutFixture({ manualEffects: true });
    f.raw(f.elem(1, 0, "div"), f.attr(1, "style", "display:flex;flex-direction:column-reverse;height:80px;width:100px;overflow:auto"), f.elem(2, 1, "div"), f.attr(2, "style", "min-height:500px"), f.listen(1, 0, "scroll", 6));
    const element = f.rt.statics[1]; element.scrollTop = -50; await __layoutFrame(); f.rt.releaseReports();
    let error = ""; try { f.rt.checkManualScrolls(); } catch (failure) { error = failure.message; }
    const result = [element.scrollTop < 0, f.calls[0].bytes, error.includes("scroll first"), f.rt.poisoned]; f.end(); return result;
  });
  check("negative physical movement fails manual proof even while its production payload validly clamps to zero", reverse, [true, [0, 0, 0, 0, 0, 0, 0, 0], true, null]);

  const strict = await page.evaluate(async () => {
    const results = [];
    for (const command of ["stray", "end", "into", "smooth"]) {
      const f = __layoutFixture({ manualEffects: true });
      f.raw(f.elem(1, 0, "div"), f.attr(1, "style", "height:50px;width:100px;overflow:auto;overflow-anchor:none"), f.elem(2, 1, "button"), f.attr(2, "style", "display:block;margin-top:1000px"), f.listen(1, 0, "scroll", 6));
      if (command === "stray") f.rt.statics[2].scrollIntoView();
      if (command === "end") f.raw(f.ref(1, [2, 0, 1]));
      if (command === "into") f.rt.perform({ op: "ref", mode: 6, node: 2, element: f.rt.statics[2], options: { block: "center", inline: "nearest", behavior: "instant" } });
      if (command === "smooth") f.raw(f.ref(1, [3], f.u32(700), [0, 2]));
      await __layoutFrame(); let error = ""; try { f.rt.checkManualScrolls(); } catch (failure) { error = failure.message; }
      results.push([error.includes(command === "stray" ? "scroll first" : command === "end" ? "End" : command === "into" ? "ScrollIntoView" : "requested position"), f.rt.poisoned === null]); f.end();
    }
    return results;
  });
  check("manual replay rejects stray scrolling, layout-dependent edges and unfinished smooth movement without poisoning", strict, Array(4).fill([true, true]));

  const realSize = await page.evaluate(async () => {
    const f = __layoutFixture(); f.raw(f.elem(1, 0, "div"), f.attr(1, "style", "width:123px;height:45px;padding:7px;border:3px solid"), f.listen(1, 0, "size", 7));
    const start = performance.now(); while (!f.calls.length) { if (performance.now() - start > 3000) throw new Error("no real size observation"); await __layoutFrame(); }
    const first = f.calls[0], element = f.rt.statics[1];
    let resized = false; const original = f.rt.deliver; f.rt.deliver = (...args) => { original(...args); if (!resized) { resized = true; element.style.height = "65px"; } };
    element.style.width = "133px";
    while (f.calls.length < 3) { if (performance.now() - start > 3000) throw new Error("size change did not settle"); await __layoutFrame(); }
    const result = [first, f.calls.slice(-2), f.rt.queue.length, f.rt.poisoned]; f.raw(f.release(1), f.remove(1)); f.end(); return result;
  });
  check("real ResizeObserver reports the content box and a handler that resizes once settles", realSize, [{ node: 1, handler: 0, bytes: [123, 0, 0, 0, 45, 0, 0, 0] }, [{ node: 1, handler: 0, bytes: [133, 0, 0, 0, 45, 0, 0, 0] }, { node: 1, handler: 0, bytes: [133, 0, 0, 0, 65, 0, 0, 0] }], 0, null]);

  const ahead = await page.evaluate(async () => {
    const f = __layoutFixture();
    f.raw(f.elem(1, 0, "div"), f.attr(1, "style", "height:100px;width:200px;overflow:auto;position:relative"), f.elem(2, 1, "div"), f.attr(2, "style", "height:500px"), f.elem(3, 2, "div"), f.attr(3, "style", "position:absolute;top:150px;height:10px;width:10px"), f.elem(4, 2, "div"), f.attr(4, "style", "position:absolute;top:150px;left:20px;height:10px;width:10px"), f.listen(3, 0, "seen", 8, 40), f.listen(4, 1, "seen", 8, 8));
    const start = performance.now(); while (f.calls.length < 2) { if (performance.now() - start > 3000) throw new Error("no real intersection observations"); await __layoutFrame(); }
    const result = f.calls.sort((a, b) => a.handler - b.handler); f.raw(f.release(3), f.release(4), f.remove(1)); f.end(); return result;
  });
  check("ahead observes one screen through a nested scroll clip while the ordinary sentinel remains unseen", ahead, [{ node: 3, handler: 0, bytes: [1, 232, 3] }, { node: 4, handler: 1, bytes: [0, 0, 0] }]);

  const table = await page.evaluate(async () => {
    const { instantiateEngineBytes, RocEngineRuntime } = await import("/runtime.mjs");
    const { module, instance } = await instantiateEngineBytes(await (await fetch("/app.wasm")).arrayBuffer());
    const root = document.createElement("main"); document.body.append(root);
    const rt = new RocEngineRuntime(instance.exports, root, { module }); rt.mount();
    [...root.querySelectorAll("button")].find((button) => button.textContent === "Show scrolled list").click();
    for (let frame = 0; frame < 4; frame += 1) await __layoutFrame();
    const scroller = root.querySelector('[aria-label="Scrolled todos"]');
    const before = rt.workRecord().counters[30]; scroller.scrollTop = 80;
    for (let frame = 0; frame < 5; frame += 1) await __layoutFrame();
    const result = [root.querySelector('[data-testid="scrolled-status"]').textContent, (rt.workRecord().counters[30] - before).toString(), scroller.scrollTop, rt.poisoned];
    rt.unmount(); root.remove(); return result;
  });
  check("the table's fixed-height window draws one real scroll in exactly one turn without moving its scrollbar", table, ["80:0:1", "1", 80, null]);

  const tableStray = await page.evaluate(async () => {
    const { instantiateEngineBytes, RocEngineRuntime } = await import("/runtime.mjs");
    const { module, instance } = await instantiateEngineBytes(await (await fetch("/app.wasm")).arrayBuffer());
    const root = document.createElement("main"); document.body.append(root);
    const rt = new RocEngineRuntime(instance.exports, root, { module, manualEffects: true }); rt.mount();
    [...root.querySelectorAll("button")].find((button) => button.textContent === "Show scrolled list").click(); await __layoutFrame(); rt.checkManualScrolls();
    [...root.querySelectorAll("button")].find((button) => button.textContent === "Focus distant scrolled control").click(); await __layoutFrame();
    let error = ""; try { rt.checkManualScrolls(); } catch (failure) { error = failure.message; }
    const result = [error.includes("scroll first"), rt.poisoned]; rt.unmount(); root.remove(); return result;
  });
  check("a table action that scrolls its handled container by focus fails manual replay without an app fault", tableStray, [true, null]);

  // The same parser supplies negative replay input too. Native has no layout
  // to reject this click; Chrome must prove that its auto-scroll changed a
  // handled container without a preceding explicit scroll step.
  const fixture = path.join(here, "../apps/table/contracts/offscreen-click.scm");
  const emitted = spawnSync(options.runner, ["--emit-steps", fixture], { encoding: "utf8", timeout: 30000 });
  if (emitted.status !== 0) throw new Error(`could not parse layout contract: ${emitted.stderr}`);
  const native = spawnSync(options.runner, [fixture], { encoding: "utf8", timeout: 30000 });
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "roc-signals-layout-contract-"));
  try {
    const steps = path.join(directory, "steps.jsonl"); fs.writeFileSync(steps, emitted.stdout);
    const replay = spawnSync(process.execPath, [path.join(here, "replay.mjs"), "--wasm", options.wasm, "--runtime", options.runtime, "--steps", steps, "--chrome", options.chrome, "--json-lines"], { encoding: "utf8", timeout: 30000 });
    const result = replay.stdout.split("\n").filter(Boolean).map((line) => JSON.parse(line))[0];
    check("the shared offscreen-click spec fails only Chrome's layout proof and names the explicit scroll step", [native.status === 0, replay.status === 1, result?.failure?.message.includes("scroll first")], [true, true, true]);
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }

  await page.close();
} finally {
  await browser.close();
  server.close();
}
console.log(failures ? `layout-browser: ${failures} failures` : "layout-browser: all pass");
process.exitCode = failures ? 1 : 0;
