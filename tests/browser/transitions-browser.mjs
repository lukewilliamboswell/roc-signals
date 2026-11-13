// The runtime's transition boundary, independently driven by wire fixtures.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";
const options = parseArgs(process.argv.slice(2));
const files = runtimeFiles(options.runtime);
const server = http.createServer((req, res) => {
  const name = path.basename(new URL(req.url, "http://x").pathname);
  if (!name) { res.writeHead(200, { "content-type": "text/html" }); res.end('<!doctype html><style>body{margin:0}</style>'); return; }
  if (!files[name]) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { "content-type": "text/javascript" }); res.end(fs.readFileSync(files[name]));
});
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
const browser = await launch({ executablePath: options.chrome });
let failures = 0;
const check = (name, actual, expected) => {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  if (!ok) failures++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok ? "" : `: got ${JSON.stringify(actual)}, expected ${JSON.stringify(expected)}`}`);
};
try {
  const page = await browser.newPage();
  await page.goto(`http://127.0.0.1:${server.address().port}/`);
  await page.evaluate(async () => {
    const { RocEngineRuntime } = await import("/runtime.mjs");
    const enc = new TextEncoder();
    const join = (...parts) => { const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0)); let at = 0; for (const p of parts) { out.set(p, at); at += p.length; } return out; };
    const u32 = n => { const out = new Uint8Array(4); new DataView(out.buffer).setUint32(0, n, true); return out; };
    const str = s => { const b = enc.encode(s); return join(u32(b.length), b); };
    const elem = (id, tag = "div") => join([8], u32(id), u32(0), u32(0), str(tag));
    const text = (id, value) => join([12], u32(id), str(value));
    const title = value => join([17], str(value));
    const mark = (...types) => join([24], u32(types.length), ...types.map(str));
    window.__transitionFixture = (options = {}) => {
      const root = document.createElement("main"); document.body.append(root);
      const memory = new WebAssembly.Memory({ initial: 64 }); let length = 0, releases = 0;
      const calls = [], starts = [], effects = [];
      const x = { memory, cmd_ptr: () => 0, cmd_len: () => length, files_released: () => { releases++; return 0; }, metric: () => 0n, work_len: () => 0, fault: () => 0, drop: () => {}, payload_reserve: () => { throw new Error("unexpected staging"); } };
      const start = options.start ?? (arg => {
        let ready, finish;
        const transition = { ready: new Promise(r => { ready = r; }), finished: new Promise(r => { finish = r; }), skips: 0, skipTransition() { this.skips++; } };
        starts.push({ arg, update: typeof arg === "function" ? arg : arg.update, transition, ready, finish });
        return transition;
      });
      const doc = new Proxy(document, { get(target, key) {
        if (key === "startViewTransition") return options.absent ? undefined : start;
        if (key === "visibilityState") return options.hidden ? "hidden" : "visible";
        const value = Reflect.get(target, key, target); return typeof value === "function" ? value.bind(target) : value;
      } });
      const rt = new RocEngineRuntime(x, root, { manualEffects: true, ...options, document: doc });
      const original = rt.perform.bind(rt);
      rt.perform = fx => { effects.push([fx.op, root.childNodes.length]); original(fx); };
      rt.deliver = (node, handler, payload) => calls.push([node, handler, payload]);
      const raw = (flags, ...parts) => {
        if (rt.pendingTransition) throw new Error("fixture attempted to overwrite a waiting batch");
        const bytes = join([flags], ...parts); new Uint8Array(memory.buffer).set(bytes); length = bytes.length;
        rt.busy = true; try { rt.guard(() => rt.apply()); } finally { rt.busy = rt.pendingTransition !== null; } rt.drainQueue();
      };
      const end = () => { rt.unmount(); root.remove(); };
      return { rt, root, x, starts, calls, effects, raw, end, elem, text, title, mark, join, u32, str, get releases() { return releases; } };
    };
  });
  const deferred = await page.evaluate(async () => {
    const f = __transitionFixture();
    f.raw(1, f.elem(1, "input"), f.join([18, 1], f.u32(1)), f.title("early"), f.mark("shelf", "odd value"));
    const before = [f.root.childNodes.length, f.rt.busy, structuredClone(f.effects), f.releases, f.starts[0].arg.types];
    f.rt.dispatch(0, 2, "gap");
    const queued = [f.calls.length, f.rt.queue.length];
    f.starts[0].update(); f.starts[0].update();
    let idle = false; f.rt.idle().then(() => { idle = true; }); await Promise.resolve();
    const after = [f.root.childNodes.length, f.rt.busy, f.effects, f.releases, f.calls, f.starts[0].transition.skips, idle, f.rt.transitionLog.total().toString(), f.rt.transitionLog.at(1n).types];
    f.starts[0].finish(); await f.rt.idle(); const finished = idle; f.end();
    return { before, queued, after, finished };
  });
  check("early effects precede the guarded callback; node references follow it once; idle waits for finished", deferred, {
    before: [0, true, [["title", 0]], 0, ["shelf", "odd value"]], queued: [0, 1],
    after: [1, false, [["title", 0], ["ref", 1]], 1, [[0, 2, "gap"]], 1, false, "1", ["shelf", "odd value"]], finished: true,
  });
  const fallbacks = await page.evaluate(() => {
    const results = [];
    for (const options of [{ absent: true }, { hidden: true }, { viewTransitions: "off" }, { start() { throw new Error("unavailable"); } }]) {
      const f = __transitionFixture(options); f.raw(1, f.elem(1), f.title("fallback"), f.mark());
      results.push([f.root.childNodes.length, f.rt.busy, f.rt.poisoned, f.rt.transitionLog.total().toString(), f.effects]); f.end();
    }
    return results;
  });
  check("absent, hidden and off use ordinary ordering; synchronous API failure applies after early effects", fallbacks, [
    [1, false, null, "1", [["title", 1]]], [1, false, null, "1", [["title", 1]]], [1, false, null, "1", [["title", 1]]], [1, false, null, "1", [["title", 0]]],
  ]);
  const readings = await page.evaluate(() => {
    const results = [];
    for (const options of [{}, { absent: true }, { hidden: true }, { viewTransitions: "off" }]) {
      const f = __transitionFixture(options), modes = [];
      const read = f.rt.applyBatch.bind(f.rt); f.rt.applyBatch = (...args) => { modes.push(args[0]); return read(...args); };
      f.raw(0, f.elem(1)); const normal = modes.splice(0);
      f.raw(1, f.title("count"), f.mark()); if (f.starts.length) { f.starts[0].update(); f.starts[0].finish(); }
      results.push([normal, modes, f.effects.length]); f.end();
    }
    return results;
  });
  check("ordinary and fallback batches read once; an animated batch reads twice", readings,
    [[["normal"], ["early", "update"], 1], ...Array(3).fill([["normal"], ["normal"], 1])]);
  const emptyRelease = await page.evaluate(() => {
    const f = __transitionFixture(); f.rt.files.set(1, new File(["x"], "released.txt"));
    f.x.cmd_len = () => 0; f.x.files_released = () => 1; f.x.files_tokens = () => 100;
    new DataView(f.x.memory.buffer).setBigUint64(100, 1n, true);
    const bytes = f.rt.apply(), held = f.rt.files.size; f.end(); return [bytes, held];
  });
  check("an empty batch still drains handles released by the host call", emptyRelease, [0, 0]);
  const overload = await page.evaluate(async () => {
    let calls = 0, callback;
    const f = __transitionFixture({ start(arg) { calls++; if (typeof arg !== "function") throw new TypeError("function required"); callback = arg; return { ready: Promise.resolve(), finished: Promise.resolve(), skipTransition() {} }; } });
    f.raw(1, f.elem(1), f.mark("shelf")); let idle = false; f.rt.idle().then(() => { idle = true; }); await Promise.resolve(); await Promise.resolve();
    const before = [calls, f.root.childNodes.length, idle]; callback(); await f.rt.idle(); const after = [f.root.childNodes.length, f.rt.transitionLog.at(1n).types]; f.end(); return [before, after];
  });
  check("callback overload fallback retains one update and idle includes the pending update", overload, [[2, 0, false], [1, ["shelf"]]]);
  const malformed = await page.evaluate(() => {
    const result = [];
    for (const options of [{}, { absent: true }, { hidden: true }, { viewTransitions: "off" }]) {
      for (const [flags, marker] of [[2, true], [1, false], [0, true]]) {
        const f = __transitionFixture(options); f.raw(flags, f.elem(1), ...(marker ? [f.mark()] : []));
        result.push([f.rt.poisoned?.class, f.root.childNodes.length, f.starts.length, f.effects.length]); f.end();
      }
    }
    return result;
  });
  check("framing rejects before animated publication; ordinary streaming faults stop before effects", malformed,
    [0, 0, 1, 0, 1, 1, 0, 1, 1, 0, 1, 1].map(nodes => ["executor", nodes, 0, 0]));
  const timeout = await page.evaluate(async () => {
    const f = __transitionFixture(); f.raw(1, f.elem(1), f.mark());
    await new Promise(resolve => setTimeout(resolve, 1100));
    const before = [f.root.childNodes.length, f.rt.busy, f.starts[0].transition.skips, f.rt.transitionLog.at(1n).cause];
    f.starts[0].update(); const count = f.rt.transitionLog.total().toString(); f.starts[0].finish(); await f.rt.idle(); f.end(); return [before, count];
  });
  check("timeout applies the held batch and a late callback cannot repeat it", timeout, [[1, false, 1, "timer"], "1"]);
  const queued = await page.evaluate(() => {
    const f = __transitionFixture(); f.raw(0, f.elem(1)); const old = f.rt.statics[1]; old.__rn = 1;
    f.raw(1, f.join([5], f.u32(1)), f.mark()); f.rt.dispatch(1, 1, "removed", old); f.starts[0].update();
    const removed = [f.calls.length, f.rt.queue.length]; f.starts[0].finish(); f.end();
    const g = __transitionFixture(); g.raw(1, g.elem(1), g.mark());
    for (let i = 0; i < 4097; i++) g.rt.dispatch(0, 1, i);
    const full = [g.root.childNodes.length, g.calls.length, g.rt.queue.length, g.rt.poisoned, g.rt.transitionLog.at(1n).cause]; g.starts[0].finish(); g.end(); return [removed, full];
  });
  check("gap events drop removed targets; a full queue forces apply and drains without loss", queued, [[0, 0], [1, 4097, 0, null, "queue"]]);
  const occurrenceBarrier = await page.evaluate(() => {
    const f = __transitionFixture(); f.rt.live.set(7, { cancel() {} });
    const delivered = [];
    f.rt.deliver = (_node, _handler, payload) => {
      delivered.push(payload);
      if (payload === 1) f.rt.report(7, "new report");
    };
    f.raw(1, f.elem(1), f.mark());
    for (let i = 0; i < 4096; i++) f.rt.dispatch(0, 1, i);
    f.rt.dispatch(0, 1, "incoming occurrence");
    const beforeFrame = delivered.slice(-2);
    f.rt.releaseReports();
    const result = [beforeFrame, delivered.slice(-2), delivered.slice(0, 4096).every((value, index) => value === index), f.rt.queue.length, f.rt.poisoned];
    f.starts[0].finish(); f.end(); return result;
  });
  check("full waiting queue admits an occurrence before reports raised by older deliveries", occurrenceBarrier,
    [[4095, "incoming occurrence"], ["incoming occurrence", "new report"], true, 0, null]);
  const fullReports = await page.evaluate(() => {
    const results = [];
    for (const animated of [false, true]) {
      const f = __transitionFixture(); f.rt.live.set(7, { cancel() {} });
      const delivered = []; let peak = 0;
      const dispatch = f.rt.dispatch.bind(f.rt);
      f.rt.dispatch = (...args) => { peak = Math.max(peak, f.rt.queue.length); const result = dispatch(...args); peak = Math.max(peak, f.rt.queue.length); return result; };
      f.rt.deliver = (_node, _handler, payload) => {
        delivered.push(payload);
        if (payload === 0) f.rt.report(7, "replacement");
      };
      if (animated) f.raw(1, f.elem(1), f.mark());
      else f.rt.busy = true;
      for (let i = 0; i < 4096; i++) f.rt.dispatch(0, 1, i);
      if (!animated) f.rt.busy = false;
      f.rt.report(7, "incoming report");
      const beforeFrame = delivered.slice(-2); f.rt.releaseReports();
      results.push([beforeFrame, delivered.slice(-2), delivered.slice(0, 4096).every((value, index) => value === index), f.rt.reportsReplaced, peak, f.rt.queue.length, f.rt.poisoned]);
      f.starts[0]?.finish(); f.end();
    }
    return results;
  });
  check("full idle and waiting queues admit reports before older turns replace the same source", fullReports,
    Array(2).fill([[4094, 4095], [4095, "replacement"], true, 1, 4096, 0, null]));
  const reportBarrier = await page.evaluate(() => {
    const f = __transitionFixture(); f.rt.live.set(7, { cancel() {} }); f.rt.live.set(8, { cancel() {} });
    const delivered = [];
    f.rt.deliver = (_node, _handler, payload) => { delivered.push(payload); if (payload === 1) f.rt.report(8, "later report"); };
    f.raw(1, f.elem(1), f.mark());
    for (let i = 0; i < 4096; i++) f.rt.dispatch(0, 1, i);
    f.rt.report(7, "incoming report"); const before = [delivered.length, f.rt.queue.length];
    f.rt.releaseReports(); const result = [before, delivered.slice(-2), f.rt.queue.length, f.rt.poisoned]; f.starts[0].finish(); f.end(); return result;
  });
  check("a full waiting queue keeps an arriving report ahead of a later source while both remain paced", reportBarrier,
    [[4096, 2], ["incoming report", "later report"], 0, null]);
  const pausedHandoff = await page.evaluate(() => {
    const f = __transitionFixture(); f.rt.live.set(7, { cancel() {} }); f.rt.live.set(8, { cancel() {} });
    const delivered = [];
    f.rt.deliver = (_node, _handler, payload) => {
      delivered.push(payload);
      if (payload === 0) f.raw(1, f.elem(2), f.mark("next"));
      if (payload === 1) f.rt.report(8, "later report");
    };
    f.raw(1, f.elem(1), f.mark());
    for (let i = 0; i < 4096; i++) f.rt.dispatch(0, 1, i);
    f.rt.report(7, "incoming report");
    const paused = [delivered.slice(), f.rt.queue.length, f.rt.reportDue, f.starts.length];
    f.starts[1].update(); const beforeFrame = [delivered.slice(-2), f.rt.queue.length, f.rt.poisoned];
    f.rt.releaseReports(); const afterFrame = [delivered.slice(-2), f.rt.queue.length, f.rt.poisoned];
    f.starts.forEach(start => start.finish()); f.end(); return [paused, beforeFrame, afterFrame];
  });
  check("a handoff paused by another marked batch keeps capacity draining separate from an actual frame", pausedHandoff,
    [[[0], 4096, false, 2], [[4094, 4095], 2, null], [["incoming report", "later report"], 0, null]]);
  const cancelledIncoming = await page.evaluate(() => {
    const results = [];
    for (const animated of [false, true]) {
      const f = __transitionFixture(); f.rt.live.set(7, { cancel() {} }); let cancelled;
      const delivered = [];
      f.rt.deliver = (_node, _handler, payload) => {
        delivered.push(payload);
        if (payload === 0) { cancelled = f.rt.reportSources.get(7); f.rt.cancel(7); }
      };
      if (animated) f.raw(1, f.elem(1), f.mark()); else f.rt.busy = true;
      for (let i = 0; i < 4096; i++) f.rt.dispatch(0, 1, i);
      if (!animated) f.rt.busy = false;
      f.rt.report(7, { files: [new File(["x"], "incoming.txt")] });
      results.push([cancelled.payload, delivered.length, f.rt.queue.length, f.rt.reportSources.size, f.rt.live.has(7), f.rt.poisoned]); f.starts[0]?.finish(); f.end();
    }
    return results;
  });
  check("a canceled incoming report clears its file payload and tombstone in full idle and waiting queues", cancelledIncoming,
    Array(2).fill([null, 4096, 0, 0, false, null]));
  const activeCleanup = await page.evaluate(() => {
    const results = [];
    for (const faults of [false, true]) {
      const f = __transitionFixture(); f.raw(0, f.elem(1)); const old = f.rt.statics[1]; old.__rn = 1;
      f.raw(1, f.join([5], f.u32(faults ? 77 : 1)), f.mark());
      f.rt.dispatch(1, 1, { files: [new File(["x"], "old.txt")] }, old);
      const oldest = f.rt.queue.head;
      for (let i = 0; i < 4095; i++) f.rt.dispatch(0, 1, i);
      f.rt.dispatch(0, 1, "incoming");
      results.push([oldest.payload, f.calls.length, f.rt.queue.length, f.rt.poisoned?.class ?? null]); f.starts[0].finish(); f.end();
    }
    return results;
  });
  check("the held oldest payload clears when its target is removed or forced apply faults", activeCleanup,
    [[null, 4096, 0, null], [null, 0, 0, "executor"]]);
  const faults = await page.evaluate(() => {
    const f = __transitionFixture(); f.rt.perform = () => { throw new Error("early fault"); }; f.raw(1, f.elem(1), f.title("bad"), f.mark());
    const early = [f.root.childNodes.length, f.starts.length, f.rt.poisoned?.class]; f.end();
    const g = __transitionFixture(); g.raw(1, g.join([5], g.u32(77)), g.mark()); g.starts[0].update();
    const update = [g.rt.poisoned?.class, g.rt.busy, g.starts[0].transition.skips]; g.starts[0].finish(); g.end();
    const h = __transitionFixture(); h.raw(1, h.elem(1), h.mark()); h.end(); h.starts[0].update();
    return [early, update, [h.root.childNodes.length, h.starts[0].transition.skips, h.rt.transitionLog.total().toString()]];
  });
  check("early faults preserve DOM; update faults are contained; unmount cancels and invalidates callback", faults, [[0, 0, "executor"], ["executor", false, 1], [0, 1, "0"]]);
  const earlyIngress = await page.evaluate(() => {
    const f = __transitionFixture(); const performed = [];
    f.rt.perform = fx => { performed.push(fx.text); for (let i = 0; i < 4097; i++) f.rt.dispatch(0, 1, i); };
    f.raw(1, f.elem(1), f.title("first"), f.title("second"), f.mark());
    const result = [f.root.childNodes.length, f.starts.length, f.rt.poisoned?.class, performed, f.releases]; f.end(); return result;
  });
  check("synchronous early-effect ingress cannot force apply before later early effects", earlyIngress, [0, 0, "resource_limit", ["first"], 0]);
  const staged = await page.evaluate(() => {
    const f = __transitionFixture(); f.x.files_stage = () => { throw new Error("page file staging in gap"); };
    f.raw(1, f.elem(1), f.mark());
    const file = new File(["answer"], "result.txt"); f.rt.result(7, { parts: [new Uint8Array([14])], files: [file] });
    const before = [f.calls.length, f.rt.queue.length, f.rt.poisoned]; f.starts[0].update();
    const after = [f.calls.length, f.calls[0][2].files[0] === file, f.root.childNodes.length, f.rt.poisoned]; f.starts[0].finish(); f.end(); return [before, after];
  });
  check("file-bearing completions retain browser data without page staging in the gap", staged, [[0, 1, null], [1, true, 1, null]]);
  const templates = await page.evaluate(() => {
    const f = __transitionFixture();
    const template = f.join([1], f.str("p"), [0, 1, 2], f.str(""), [1, 1, 1, 0]);
    let parses = 0; const original = f.rt.parseTemplate.bind(f.rt); f.rt.parseTemplate = (...args) => { parses++; return original(...args); };
    f.raw(1, f.join([7], f.u32(1), f.u32(template.length), template), f.join([1], f.u32(2), f.u32(0), f.u32(0), f.u32(1), f.str("row")), f.title("once"), f.mark());
    const before = [parses, f.root.textContent, f.effects.length]; f.starts[0].update();
    const after = [parses, f.root.textContent, f.effects.length, f.rt.poisoned]; f.starts[0].finish(); f.end(); return [before, after];
  });
  check("template definitions are parsed once and effects are not repeated", templates, [[1, "", 1], [1, "row", 1, null]]);
  const rejected = await page.evaluate(async () => {
    let update, rejectReady, rejectFinished;
    const f = __transitionFixture({ start(arg) {
      update = arg.update;
      return { ready: new Promise((_, reject) => { rejectReady = reject; }), finished: new Promise((_, reject) => { rejectFinished = reject; }), skipTransition() {} };
    } });
    const events = []; f.rt.monitor.subscribe(event => { if (event.kind === "transition") events.push([event.state, event.message?.length ?? 0]); });
    f.raw(1, f.elem(1), f.mark()); update(); rejectReady(new Error("x".repeat(2000))); rejectFinished(new Error("duplicate CSS name"));
    await f.rt.idle(); const result = [events, f.rt.poisoned, f.root.childNodes.length]; f.end(); return result;
  });
  check("ready and finished rejection are bounded passive observations", rejected, [[["applied", 0], ["ready-rejected", 1024], ["finished-rejected", 18]], null, 1]);
  const lateRejections = await page.evaluate(async () => {
    const results = [];
    for (const action of ["unmount", "poison", "fresh-generation"]) {
      let update, readyReject, finishedReject;
      const f = __transitionFixture({ start(arg) { update = arg.update; return {
        ready: new Promise((_, reject) => { readyReject = reject; }),
        finished: new Promise((_, reject) => { finishedReject = reject; }), skipTransition() {},
      }; } });
      const events = []; f.rt.monitor.subscribe(event => { if (event.kind === "transition") events.push(event.state); });
      f.raw(1, f.elem(1), f.mark()); update(); const idle = f.rt.idle();
      const oldReadyReject = readyReject, oldFinishedReject = finishedReject;
      if (action === "unmount") f.rt.unmount();
      else if (action === "poison") f.rt.contain(new Error("test teardown"));
      else f.rt.cancelTransition(); // recover invalidates this token before its asynchronous instantiate.
      await idle;
      let newerIdle = true;
      if (action === "fresh-generation") {
        f.raw(1, f.mark("new")); update(); newerIdle = false;
        f.rt.idle().then(() => { newerIdle = true; });
      }
      oldReadyReject(new Error("old ready")); oldFinishedReject(new Error("old finished"));
      await Promise.resolve(); await Promise.resolve();
      results.push([events, newerIdle]); f.end();
    }
    return results;
  });
  check("late ready and finished rejections are consumed silently after every lifecycle boundary", lateRejections,
    [[["applied"], true], [["applied"], true], [["applied", "applied"], false]]);
  const retainedFiles = await page.evaluate(() => {
    const f = __transitionFixture(); const file = new File(["abc"], "source.txt"); f.rt.files.set(1, file);
    const u64 = n => f.join(f.u32(n), f.u32(0));
    const save = f.join([20], u64(1), u64(0), u64(3), f.str("answer.txt"));
    f.raw(1, f.elem(1), save, f.mark());
    const before = [f.rt.saveLog.map(record => record.name), f.releases, f.rt.files.get(1) === file];
    f.starts[0].update(); const after = f.releases; f.starts[0].finish(); f.end(); return [before, after];
  });
  check("SAVE resolves files in the early pass and release draining waits for apply", retainedFiles, [[["answer.txt"], 0, true], 1]);
  await page.evaluate(() => {
    const f = __transitionFixture(); const button = document.createElement("button"); button.textContent = "save"; button.style.cssText = "position:fixed;left:10px;top:10px;width:100px;height:40px"; document.body.append(button);
    f.rt.files.set(1, new File(["abc"], "source.txt")); const u64 = n => f.join(f.u32(n), f.u32(0));
    let listener = false; const performed = [];
    const original = f.rt.perform.bind(f.rt); f.rt.perform = fx => { if (fx.op === "save") performed.push([listener, navigator.userActivation.isActive]); original(fx); };
    button.addEventListener("click", () => { listener = true; f.raw(1, f.elem(1), f.join([20], u64(1), u64(0), u64(3), f.str("gesture.txt")), f.mark()); listener = false; });
    window.__gestureTransition = { f, button, performed };
  });
  await page.send("Input.dispatchMouseEvent", { type: "mousePressed", x: 40, y: 25, button: "left", buttons: 1, clickCount: 1 });
  await page.send("Input.dispatchMouseEvent", { type: "mouseReleased", x: 40, y: 25, button: "left", buttons: 0, clickCount: 1 });
  check("SAVE is performed in the trusted click listener before deferred DOM publication", await page.evaluate(() => {
    const { f, button, performed } = __gestureTransition; const result = [performed, f.root.childNodes.length]; f.starts[0].update(); f.starts[0].finish(); f.end(); button.remove(); return result;
  }), [[[true, true]], 0]);
  const histories = await page.evaluate(() => {
    const f = __transitionFixture({ absent: true });
    for (let i = 0; i < 4097; i++) f.raw(1, f.mark(String(i)));
    let evicted; try { f.rt.transitionLog.at(1n); } catch (error) { evicted = /retained/.test(error.message); }
    const retained = [f.rt.transitionLog.total().toString(), f.rt.transitionLog.at(4097n).types, evicted];
    f.raw(1, f.mark("x".repeat(1048577)));
    let oversized; try { f.rt.transitionLog.at(4098n); } catch (error) { oversized = /retained/.test(error.message); }
    f.rt.transitionLog.maximum = 4098n; f.raw(1, f.elem(1), f.mark());
    let exhausted; try { f.rt.transitionLog.total(); } catch (error) { exhausted = /exhausted/.test(error.message); }
    const result = [retained, oversized, f.rt.transitionLog.records.size, exhausted, f.root.childNodes.length, f.rt.poisoned]; f.end(); return result;
  });
  check("manual history bounds records and encoded type bytes; exhaustion affects observation only", histories, [["4097", ["4096"], true], true, 0, true, 1, null]);
  const unmountIdle = await page.evaluate(async () => {
    const f = __transitionFixture(); f.raw(1, f.elem(1), f.mark()); f.starts[0].update();
    const idle = f.rt.idle(); f.end(); await idle;
    f.starts[0].finish(); await Promise.resolve(); return [f.rt.poisoned, f.root.childNodes.length];
  });
  check("unmount releases idle callers after update even before finished settles", unmountIdle, [null, 0]);
  const overlapping = await page.evaluate(async () => {
    const f = __transitionFixture({ manualEffects: false });
    f.raw(1, f.elem(1), f.mark("first")); f.starts[0].update();
    f.raw(1, f.elem(2), f.mark("second")); f.starts[1].update();
    const result = [f.starts.length, f.root.childNodes.length, f.rt.busy, f.starts.map(s => s.transition.skips), f.rt.poisoned];
    f.starts.forEach(start => start.finish()); await f.rt.idle(); f.end(); return result;
  });
  check("a second marked batch may apply during the preceding animation", overlapping, [2, 2, false, [0, 0], null]);
  for (const allow of [false, true]) {
    await page.evaluate(async allow => {
      const style = document.createElement("style"); style.textContent = `:root{view-transition-name:none}::view-transition-group(*){animation-duration:2s}::view-transition-old(root),::view-transition-new(root){animation-duration:2s}${allow ? "::view-transition,::view-transition-group(*),::view-transition-image-pair(*),::view-transition-old(*),::view-transition-new(*){pointer-events:none}" : ""}`; document.head.append(style);
      let transition;
      const decoration = document.createElement("aside"); decoration.style.cssText = "position:fixed;left:200px;top:200px;width:20px;height:20px;background:red;view-transition-name:decoration"; document.body.append(decoration);
      const f = __transitionFixture({ manualEffects: false, start(arg) { transition = document.startViewTransition(arg); return transition; } });
      f.raw(0, f.elem(1, "button")); const button = f.rt.statics[1]; button.textContent = "overlay target"; button.style.cssText = "position:fixed;left:10px;top:70px;width:150px;height:40px";
      let clicks = 0; button.addEventListener("click", () => { clicks++; });
      f.raw(1, f.mark()); await transition.ready;
      window.__overlayTransition = { f, style, decoration, transition, count: () => clicks };
    }, allow);
    await page.send("Input.dispatchMouseEvent", { type: "mousePressed", x: 50, y: 85, button: "left", buttons: 1, clickCount: 1 });
    await page.send("Input.dispatchMouseEvent", { type: "mouseReleased", x: 50, y: 85, button: "left", buttons: 0, clickCount: 1 });
    check(`real transition overlay ${allow ? "permits clicks with pointer-events CSS" : "intercepts clicks by default"}`, await page.evaluate(async () => {
      const { f, style, decoration, transition, count } = __overlayTransition; const result = [count(), f.rt.busy, f.rt.poisoned]; transition.skipTransition(); await f.rt.idle(); f.end(); style.remove(); decoration.remove(); return result;
    }), [allow ? 1 : 0, false, null]);
  }
  const duplicates = await page.evaluate(async () => {
    const f = __transitionFixture({ manualEffects: false, start: document.startViewTransition.bind(document) });
    f.raw(0, f.elem(1), f.elem(2)); f.rt.statics[1].style.viewTransitionName = "same-name"; f.rt.statics[2].style.viewTransitionName = "same-name";
    const events = []; f.rt.monitor.subscribe(event => { if (event.kind === "transition") events.push(event.state); });
    f.raw(1, f.elem(3), f.mark()); await f.rt.idle(); const result = [f.root.childNodes.length, f.rt.poisoned, events.includes("ready-rejected")]; f.end(); return result;
  });
  check("duplicate CSS names reject only the animation and still publish the batch", duplicates, [3, null, true]);
  const real = await page.evaluate(async () => {
    if (typeof document.startViewTransition !== "function") return "absent";
    const f = __transitionFixture({ start: document.startViewTransition.bind(document) });
    f.raw(0, f.elem(1)); f.rt.statics[1].style.viewTransitionName = "duplicate";
    const original = f.rt.perform.bind(f.rt); f.rt.perform = fx => original(fx);
    f.raw(1, f.elem(2), f.mark("shelf")); f.rt.statics[1].style.viewTransitionName = "duplicate";
    await f.rt.idle(); const a = [f.root.childNodes.length, f.rt.poisoned, f.rt.busy];
    f.raw(1, f.elem(3), f.mark("shelf")); await f.rt.idle(); const b = [f.root.childNodes.length, f.rt.poisoned]; f.end(); return [a, b];
  });
  check("real browser transition settles in manual mode and allows a subsequent marked batch", real, [[2, null, false], [3, null]]);
} finally { await browser.close(); await new Promise(resolve => server.close(resolve)); }
if (failures) process.exitCode = 1;
else console.log("transitions-browser: all pass");
