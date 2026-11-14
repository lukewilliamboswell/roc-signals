import { installProtocolFixture } from "./protocol-fixture.mjs";
// Report delivery contracts: real browser tasks and the runtime's ingress,
// followed by the existing ports app to check the engine's result turns.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";

const opts = parseArgs(process.argv.slice(2));
const files = { ...runtimeFiles(opts.runtime), "app.wasm": opts.wasm };
const server = http.createServer((req, res) => {
  if (req.url === "/") {
    res.writeHead(200, { "content-type": "text/html" });
    res.end('<!doctype html><html><head><meta charset="utf-8"></head><body></body></html>');
    return;
  }
  const file = files[path.basename(new URL(req.url, "http://x").pathname)];
  if (!file) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { "content-type": file.endsWith("wasm") ? "application/wasm" : "text/javascript" });
  res.end(fs.readFileSync(file));
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const browser = await launch({ executablePath: opts.chrome });
const ctx = await browser.createBrowserContext();
const page = await ctx.newPage();
await page.goto(`http://127.0.0.1:${server.address().port}/`);
await installProtocolFixture(page);
let failures = 0;
const check = (name, got, want) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  if (!ok) failures += 1;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok ? "" : `: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`}`);
};

// The delivery recorder replaces only the Wasm call. All queue, scheduler,
// cancellation and port serialization paths remain the real runtime's.
const ingress = await page.evaluate(async () => {
  const { RocEngineRuntime, MAX_QUEUED, FRAME_WAIT_MS } = await import("/runtime.mjs");
  const fixture = (options = {}) => {
    const root = document.createElement("div"); document.body.append(root);
    const frames = new Map(); let frameId = 0, visible = true;
    const win = { requestAnimationFrame: (callback) => { frames.set(++frameId, callback); return frameId; }, cancelAnimationFrame: (id) => frames.delete(id) };
    const rt = new RocEngineRuntime({ drop: () => {} }, root, { window: win, environment: { visible: () => visible }, ...options });
    __bindProtocolFixture(rt);
    const calls = [];
    rt.deliver = (node, handler, payload) => { if (payload.before) payload.before(); calls.push({ node, handler, payload }); };
    const add = (id) => rt.live.set(id, { cancel: () => {} });
    const frame = () => { for (const callback of [...frames.values()]) callback(); };
    const end = () => { rt.unmount(); root.remove(); };
    return { rt, calls, add, frame, frames, end, visible: (value) => { visible = value; } };
  };
  const tasks = (count, fn) => new Promise((resolve) => {
    const channel = new MessageChannel(); let at = 0;
    channel.port1.onmessage = () => {
      fn(at++);
      if (at === count) { channel.port1.close(); channel.port2.close(); resolve(); }
      else channel.port2.postMessage(null);
    };
    channel.port2.postMessage(null);
  });
  const out = {};
  {
    const f = fixture(); f.add(1);
    await tasks(50, (value) => f.rt.report(1, String(value)));
    out.tasks = [f.calls.length, f.rt.queue.length, f.rt.reportsReplaced];
    f.frame(); out.tasks.push(f.calls.map((call) => call.payload), f.rt.reportSources.size);
    f.end();
  }
  {
    const f = fixture(); f.add(1);
    f.rt.report(1, "before"); f.rt.dispatch(2, 0, "click"); f.rt.report(1, "after");
    out.order = f.calls.map((call) => call.payload);
    f.frame(); out.order.push(f.calls.map((call) => call.payload), f.rt.reportsReplaced);
    f.end();
  }
  {
    const f = fixture(); f.add(1); f.rt.busy = true;
    f.rt.report(1, "pinned"); f.rt.dispatch(2, 0, "click");
    f.rt.report(1, "old"); f.rt.report(1, "new"); f.rt.busy = false;
    f.rt.drainQueue(); out.pinned = [f.calls.map((call) => call.payload), f.rt.queue.length, f.rt.reportSources.size];
    f.frame(); out.pinned.push(f.calls.map((call) => call.payload), f.rt.reportsReplaced, f.rt.reportSources.size);
    f.end();
  }
  {
    const f = fixture(); f.rt.dispatch(2, 0, "click"); f.rt.dispatch(2, 0, "click");
    out.clicks = [f.calls.length, f.rt.reportsReplaced]; f.end();
  }
  {
    const f = fixture(); f.add(1); f.visible(false); f.rt.report(1, "hidden");
    out.hidden = [f.calls.length]; await Promise.resolve();
    out.hidden.push(f.calls.map((call) => call.payload), f.frames.size); f.end();
  }
  {
    const f = fixture(); f.add(1); f.rt.report(1, "visible"); f.visible(false); f.rt.report(1, "hidden");
    await Promise.resolve(); out.promoted = [f.calls.map((call) => call.payload), f.frames.size, f.rt.reportsReplaced]; f.end();
  }
  {
    const f = fixture(); f.add(1); f.rt.report(1, "no frame");
    await new Promise((resolve) => setTimeout(resolve, FRAME_WAIT_MS + 30));
    out.timer = [f.calls.map((call) => call.payload), f.frames.size, f.rt.reportDrain]; f.end();
  }
  {
    const f = fixture({ manualEffects: true }); f.add(1); f.rt.busy = true;
    f.rt.report(1, "pinned"); f.rt.dispatch(2, 0, "click"); f.rt.report(1, "later");
    const owner = f.rt.live.get(1); const entries = [...owner.reports];
    f.rt.cancel(1); f.rt.busy = false; f.rt.drainQueue();
    out.cancel = [f.calls.map((call) => call.payload), f.rt.reportSources.size, owner.reports.size, entries.every((entry) => entry.payload === null), f.rt.queue.length]; f.end();
  }
  {
    const f = fixture(); f.add(1);
    for (let value = 0; value < 100000; value += 1) f.rt.report(1, String(value));
    out.oneSource = [f.rt.queue.length, f.rt.reportSources.size, f.rt.reportsReplaced, f.rt.poisoned];
    f.rt.releaseReports(); out.oneSource.push(f.calls.map((call) => call.payload)); f.end();
  }
  {
    const f = fixture({ manualEffects: true });
    for (let id = 0; id < 5000; id += 1) { f.add(id); f.rt.report(id, String(id)); }
    out.sources = [f.calls.length, f.rt.queue.length, f.rt.reportSources.size, f.rt.poisoned];
    f.rt.releaseReports(); out.sources.push(f.calls.length, f.calls.every((call, index) => call.payload === String(index)), f.rt.reportSources.size); f.end();
  }
  {
    const f = fixture({ manualEffects: true });
    for (let id = 0; id < MAX_QUEUED; id += 1) { f.add(id); f.rt.report(id, String(id)); }
    f.rt.dispatch(1, 0, "click");
    out.fullOccurrence = [f.calls.length, f.calls.at(-1).payload, f.rt.queue.length, f.rt.reportSources.size, f.rt.poisoned]; f.end();
  }
  {
    const f = fixture({ manualEffects: true });
    for (let id = 0; id <= MAX_QUEUED; id += 1) f.add(id);
    for (let id = 0; id < MAX_QUEUED; id += 1) f.rt.report(id, "waiting");
    const deliver = f.rt.deliver.bind(f.rt); let first = true;
    f.rt.deliver = (...args) => { if (first) { first = false; f.rt.cancel(MAX_QUEUED); } deliver(...args); };
    f.rt.report(MAX_QUEUED, "cancelled while draining");
    out.earlyCancel = [f.calls.length, f.rt.queue.length, f.rt.reportSources.size, f.rt.live.has(MAX_QUEUED)]; f.end();
  }
  {
    const f = fixture({ manualEffects: true }); f.rt.busy = true;
    for (let id = 0; id <= MAX_QUEUED; id += 1) { f.add(id); f.rt.report(id, "busy"); }
    f.rt.busy = false;
    out.busy = [f.rt.poisoned?.class, f.rt.queue.length, f.rt.reportSources.size]; f.end();
  }
  {
    const f = fixture({ manualEffects: true }); f.add(1); f.visible(false); f.rt.report(1, "manual"); await Promise.resolve();
    out.manual = [f.calls.length, f.frames.size]; f.rt.releaseReports(); out.manual.push(f.calls.length); f.end();
    const paced = fixture({ manualWork: true, manualIntervals: true }); paced.add(1); paced.rt.report(1, "paced");
    out.manual.push(paced.calls.length, paced.frames.size); paced.frame(); out.manual.push(paced.calls.length); paced.end();
  }
  {
    const f = fixture(); f.add(1); f.rt.busy = true; f.rt.report(1, "batch"); f.frame();
    out.batch = [f.calls.length, f.rt.reportDue]; f.rt.busy = false; f.rt.drainQueue(); out.batch.push(f.calls.length, f.rt.reportDue); f.end();
  }
  {
    const storage = new Map([["key", "old"]]);
    const f = fixture({ storage: { getItem: (key) => storage.get(key) ?? null, setItem: (key, value) => storage.set(key, value) } });
    f.add(1); const deliver = f.rt.deliver.bind(f.rt);
    f.rt.deliver = (node, handler, payload) => {
      if (payload === "report") f.rt.perform({ op: "get", id: 9, key: "key" });
      if (payload === "click") f.rt.perform({ op: "set", key: "key", value: "new" });
      deliver(node, handler, payload);
    };
    f.rt.report(1, "report"); f.rt.dispatch(2, 0, "click");
    await new Promise((resolve) => setTimeout(resolve, 0));
    out.storage = f.calls.map((call) => typeof call.payload === "string" ? call.payload : new TextDecoder().decode(call.payload.subarray(1)));
    f.end();
  }
  {
    const f = fixture(); f.add(1); f.rt.report(1, "drop"); const owner = f.rt.live.get(1);
    f.end(); out.drop = [f.rt.queue.length, f.rt.reportSources.size, owner.reports.size, f.frames.size, f.rt.reportDrain];
  }
  {
    const f = fixture({ ports: { ticks: { subscribe: (_arg, context) => { window.__reportTicks = context; } } }, maxPortBytes: 100 });
    f.rt.portDecls = new Map([["ticks", { delivery: 2, bound: 1 }]]);
    f.rt.performPortSub({ id: 1, port: "ticks", msg: { json: "null", blobs: [], files: [] } });
    const bytes = new Uint8Array([1, 2]); const file = new File(["hello"], "held.txt");
    window.__reportTicks.emit({ bytes, file }); bytes.fill(9); f.frame();
    const payload = f.calls[0].payload;
    out.snapshot = [Array.from(payload.parts[5]), payload.files[0] === file];
    f.end();
  }
  return out;
});
check("fifty separate tasks share one waiting report and one turn", ingress.tasks, [0, 1, 49, ["49"], 0]);
check("a click drains the earlier report before a later report", ingress.order, ["before", "click", ["before", "click", "after"], 0]);
check("an occurrence pins earlier entries while the newest later report keeps its place", ingress.pinned, [["pinned", "click"], 1, 1, ["pinned", "click", "new"], 1, 0]);
check("two clicks remain two turns", ingress.clicks, [2, 0]);
check("a hidden report drains at the task's microtask checkpoint", ingress.hidden, [0, ["hidden"], 0]);
check("a replacement that hides the page replaces a pending frame with a microtask", ingress.promoted, [["hidden"], 0, 1]);
check("a visible page without frames drains by the 100 ms fallback", ingress.timer, [["no frame"], 0, null]);
check("cancel releases pinned and unpinned payloads without delivering them", ingress.cancel, [["click"], 0, 0, true, 0]);
check("100000 reports of one source retain one entry", ingress.oneSource, [1, 1, 99999, null, ["99999"]]);
check("5000 idle sources drain early, preserve order and never poison", ingress.sources, [4096, 904, 904, null, 5000, true, 0]);
check("an occurrence after 4096 idle reports drains them before its own turn", ingress.fullOccurrence, [4097, "click", 0, 0, null]);
check("an early drain cannot recreate a report source it cancelled", ingress.earlyCancel, [4096, 0, 0, false]);
check("the 4097th entry while busy poisons and drops its index", ingress.busy, ["resource_limit", 0, 0]);
check("manualEffects alone holds reports until the replay supplies a frame", ingress.manual, [0, 0, 1, 0, 1, 1]);
check("a frame that arrives during a batch drains after that batch", ingress.batch, [0, true, 1, false]);
check("a storage read issued by a report sees a queued occurrence's later write", ingress.storage, ["report", "click", "new"]);
check("unmount clears waiting reports, owners, scheduled frames and timer", ingress.drop, [0, 0, 0, 0, null]);
check("a Latest report snapshots mutable bytes and keeps immutable files by reference", ingress.snapshot, [[1, 2], true]);

// The ports app observes real result turns; nothing here substitutes a
// reducer or a result. Frames are controlled so reports meet deterministically.
const ports = await page.evaluate(async () => {
  const { mountRocEngineApp } = await import("/runtime.mjs");
  const frames = new Map(); let frameId = 0, bad = false;
  const actualFrame = window.requestAnimationFrame, actualCancel = window.cancelAnimationFrame;
  const actualTimeout = window.setTimeout, actualClear = window.clearTimeout;
  const reportTimers = new Map(); let timerId = 0;
  // This fixture controls both ways the frame could end. The earlier case
  // separately checks the real 100 ms fallback; load cannot split this burst.
  window.setTimeout = (fn, ms, ...args) => {
    if (ms !== 100) return actualTimeout(fn, ms, ...args);
    const id = --timerId; reportTimers.set(id, () => fn(...args)); return id;
  };
  window.clearTimeout = (id) => { if (!reportTimers.delete(id)) actualClear(id); };
  window.requestAnimationFrame = (callback) => { frames.set(++frameId, callback); return frameId; };
  window.cancelAnimationFrame = (id) => frames.delete(id);
  const root = document.createElement("div"); document.body.append(root);
  const prefix = "test.roc-signals/";
  const handlers = Object.fromEntries(["get", "echo", "inspect", "make"].map((name) => [prefix + name, { call: () => new Promise(() => {}) }]));
  handlers[prefix + "log"] = { command: () => {} };
  handlers[prefix + "ticks"] = { subscribe: (_arg, context) => { window.__ticksReport = context; } };
  handlers[prefix + "feed"] = { subscribe: (_arg, context) => { window.__feedReport = context; } };
  const rt = await mountRocEngineApp({ wasmUrl: "/app.wasm", root, ports: handlers, environment: { visible: () => { if (bad === "type") return "hidden"; if (bad) throw new Error("report visibility failed"); return true; } }, maxPortBytes: 16 });
  const click = (label) => [...root.querySelectorAll("button")].find((button) => button.textContent === label).click();
  const log = () => root.querySelector("[data-testid=log]").textContent;
  const frame = () => { for (const callback of [...frames.values()]) callback(); };
  click("Panel");
  const burstBefore = rt.workRecord().counters[30];
  await new Promise((resolve) => {
    const channel = new MessageChannel(); let value = 0;
    channel.port1.onmessage = () => {
      window.__ticksReport.emit(BigInt(value++));
      if (value === 50) { channel.port1.close(); channel.port2.close(); resolve(); }
      else channel.port2.postMessage(null);
    };
    channel.port2.postMessage(null);
  });
  const burst = [Number(rt.workRecord().counters[30] - burstBefore), rt.queue.length, rt.reportsReplaced];
  frame(); burst.push(log(), Number(rt.workRecord().counters[30] - burstBefore));
  const before = rt.workRecord().counters[30];
  window.__ticksReport.emit(1n); window.__ticksReport.emit("x".repeat(30)); window.__ticksReport.emit(2n);
  const waiting = [log(), Number(rt.workRecord().counters[30] - before), rt.reportsReplaced];
  frame();
  const latest = [log(), Number(rt.workRecord().counters[30] - before), rt.monitor.snapshot().ports[prefix + "ticks"].coalesced];
  window.__ticksReport.emit(3n); window.__ticksReport.close();
  const closed = [log(), rt.portSubscriptions(prefix + "ticks"), rt.reportSources.size];
  click("Feed");
  const everyBefore = rt.workRecord().counters[30];
  window.__feedReport.emit("one"); window.__feedReport.emit("two");
  await new Promise((resolve) => setTimeout(resolve, 0));
  const every = [log(), Number(rt.workRecord().counters[30] - everyBefore)];
  click("Panel"); click("Panel");
  const saved = log();
  const delivered = rt.workRecord().counters[33], stale = rt.workRecord().counters[34];
  const apply = rt.apply.bind(rt);
  rt.apply = () => { rt.apply = apply; window.__ticksReport.emit(8n); return apply(); };
  click("Panel");
  const cancelled = [log() === saved, Number(rt.workRecord().counters[33] - delivered), Number(rt.workRecord().counters[34] - stale), rt.reportSources.size, rt.portSubscriptions(prefix + "ticks")];
  click("Panel");
  bad = true; window.__ticksReport.emit(4n);
  const fault = [rt.poisoned?.class, rt.poisoned?.message, rt.reportSources.size];
  bad = false; await rt.recover(); click("Panel");
  bad = "type"; window.__ticksReport.emit(5n);
  const wrongType = [rt.poisoned?.class, rt.poisoned?.message, rt.reportSources.size];
  rt.unmount(); root.remove();
  window.requestAnimationFrame = actualFrame; window.cancelAnimationFrame = actualCancel;
  window.setTimeout = actualTimeout; window.clearTimeout = actualClear;
  return { burst, waiting, latest, closed, every, cancelled, fault, wrongType, timers: reportTimers.size };
});
check("fifty real Latest emits from fifty tasks reach the engine as one newest result", ports.burst, [0, 1, 49, "tick:49", 1]);
check("TooLarge is a replaceable Latest report and a newer value replaces it", ports.waiting, ["tick:49", 0, 51]);
check("one Latest result reaches the engine with the newest value", ports.latest, ["tick:49|tick:2", 1, 51]);
check("Latest close is an occurrence after its final waiting report", ports.closed, ["tick:49|tick:2|tick:3|tick:closed", 0, 0]);
check("Every messages remain separate result turns", ports.every, ["tick:49|tick:2|tick:3|tick:closed|feed:one|feed:two", 2]);
check("a port report raised in its cancelling batch is dropped without a stale result", ports.cancelled, [true, 0, 0, 0, 0]);
check("an external report's failed visibility read is an executor fault", ports.fault, ["executor", "report visibility failed", 0]);
check("an external report's wrong-type visibility read is an executor fault", ports.wrongType, ["executor", "options.environment.visible must answer a boolean", 0]);
check("every controlled frame fallback is cancelled at teardown", ports.timers, 0);

await ctx.close();
await browser.close();
await new Promise((resolve) => server.close(resolve));
if (failures) process.exitCode = 1;
else console.log("reports-browser: all pass");
