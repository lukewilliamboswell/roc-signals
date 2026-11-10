// ports-browser.mjs --wasm APP.wasm --runtime runtime.mjs --chrome PATH --
// browser contract test of ports with tests/apps/ports in headless Chrome
// (design.md, "Request kinds"; Appendix B). The page passes real port
// handlers, which specs never call, and the test checks what only a browser
// shows: the mount check against the app's declarations; values revived
// for the handler and answers serialised strictly; sync and async handlers,
// throws and rejections; a call's signal aborted by supersession, by its
// timeout, by poisoning and by unmounting, and not by disposal; delivery
// policies (`Latest` replaces, `Every(n)` refuses `emit` beyond n) and a
// subscription's end from either side; the payload bound; bytes copied
// once each way; files in both directions, with their handles released;
// containment (nothing a handler does poisons the instance); and the
// contract errors for an undeclared port and a port used as another shape.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";

const opts = parseArgs(process.argv.slice(2));
const files = { ...runtimeFiles(opts.runtime), "app.wasm": opts.wasm };
const server = http.createServer((req, res) => {
  const u = new URL(req.url, "http://x");
  if (u.pathname === "/") {
    res.writeHead(200, { "content-type": "text/html" });
    res.end('<!doctype html><html><head><meta charset="utf-8"><title>ports</title></head><body></body></html>');
    return;
  }
  const f = files[path.basename(u.pathname)];
  if (!f || !fs.existsSync(f)) {
    res.writeHead(404);
    res.end();
    return;
  }
  res.writeHead(200, { "content-type": f.endsWith(".wasm") ? "application/wasm" : "text/javascript" });
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

const P = "test.roc-signals/";

// Runs in the page: the handlers, with switches the test flips
// (window.__mode) and a record of what they saw (window.__seen).
function install() {
  const P = "test.roc-signals/";
  window.__seen = { log: [], signals: [], unsubscribed: 0, faults: [], emits: [] };
  window.__mode = { get: "sync", ticks: "none", feed: "none" };
  window.__pending = new Map();
  const seen = window.__seen;
  window.__handlers = () => ({
    [`${P}log`]: {
      command: (v) => {
        seen.log.push(v.text);
        if (v.text === "hello 2") throw new Error("command handler threw");
        if (v.text === "hello 3") return Promise.reject(new Error("command handler rejected"));
      },
    },
    [`${P}get`]: {
      call: (v, { signal }) => {
        seen.signals.push(signal);
        const m = window.__mode.get;
        if (m === "sync") return { value: `v:${v.key}` };
        if (m === "async") return new Promise((r) => setTimeout(() => r({ value: `a:${v.key}` }), 5));
        if (m === "throw") throw new Error("no store");
        if (m === "reject") return Promise.reject(new Error("rejected"));
        if (m === "map") return { value: new Map() };
        if (m === "nan") return { value: NaN };
        if (m === "undefined") return undefined;
        if (m === "never") return new Promise(() => {});
        if (m === "held") return new Promise((r) => window.__pending.set(v.key, r));
        return null;
      },
    },
    [`${P}echo`]: {
      call: (bytes) => {
        seen.echoIn = { isBytes: bytes instanceof Uint8Array, len: bytes.length };
        return bytes;
      },
    },
    [`${P}inspect`]: { call: (file) => ({ name: file.name, size: BigInt(file.size), isFile: undefined }) },
    [`${P}make`]: { call: (text) => new File([text], `${text.replace(" ", "-")}.txt`, { type: "text/plain" }) },
    [`${P}ticks`]: {
      subscribe: (_arg, { emit, close }) => {
        const m = window.__mode.ticks;
        if (m === "burst") {
          seen.emits.push(emit(1n), emit(2n), emit(3n));
        }
        if (m === "throw") throw new Error("cannot subscribe");
        window.__ticks = { emit, close };
        return () => {
          seen.unsubscribed += 1;
        };
      },
    },
    [`${P}feed`]: {
      subscribe: (arg, { emit, close, signal }) => {
        seen.feedArg = arg;
        seen.feedSignal = signal;
        if (window.__mode.feed === "burst") {
          for (let i = 0; i < 6; i += 1) seen.emits.push(emit(`m${i}`));
        }
        window.__feed = { emit, close };
        return () => {
          seen.unsubscribed += 1;
        };
      },
    },
  });
  window.__mount = async (options = {}) => {
    const { mountRocEngineApp } = await import("/runtime.mjs");
    const root = document.createElement("div");
    document.body.append(root);
    window.__root = root;
    try {
      window.__rt = await mountRocEngineApp({ wasmUrl: "/app.wasm", root, onFault: () => {}, onPortFault: (f) => seen.faults.push(f), ports: window.__handlers(), ...options });
      return "mounted";
    } catch (e) {
      return String(e.message);
    }
  };
  window.__click = (label) => [...window.__root.querySelectorAll("button")].find((b) => b.textContent === label).click();
  window.__log = () => window.__root.querySelector("[data-testid=log]").textContent;
  window.__until = (pred) =>
    new Promise((resolve, reject) => {
      const t = setTimeout(() => reject(new Error(`timed out: ${window.__log()}`)), 20000);
      const tick = () => {
        if (pred(window.__log())) {
          clearTimeout(t);
          resolve(window.__log());
        } else setTimeout(tick, 2);
      };
      tick();
    });
  window.__turns = () => new Promise((r) => setTimeout(r, 20));
  window.__fill = (label, value) => {
    const el = window.__root.querySelector(`[aria-label="${label}"]`);
    el.value = value;
    el.dispatchEvent(new Event("input", { bubbles: true }));
  };
}

async function open(options = {}, mountWith = null) {
  const ctx = await browser.createBrowserContext();
  const page = await ctx.newPage();
  page.on("pageerror", (e) => console.log("pageerror", String(e)));
  await page.evaluateOnNewDocument(install);
  await page.goto(`${base}/`);
  const mounted = await page.evaluate(mountWith ?? ((o) => window.__mount(o)), options);
  return { page, ctx, mounted };
}

// The mount check: every declared port needs a handler of its shape, and
// every handler a declared port; the page is refused before anything runs.
{
  const { page, ctx } = await open();
  const r = await page.evaluate(async (P) => {
    const tryWith = async (edit) => {
      const h = window.__handlers();
      edit(h);
      document.body.textContent = "";
      return window.__mount({ ports: h });
    };
    return [
      await tryWith((h) => delete h[`${P}get`]),
      await tryWith((h) => (h[`${P}nope`] = { command() {} })),
      await tryWith((h) => (h[`${P}get`] = { command() {} })),
      await tryWith((h) => (h[`${P}log`] = { command() {}, call() {} })),
      await tryWith((h) => (h[`${P}feed`] = { push: true })),
      await window.__mount({ ports: undefined }).then((m) => m.slice(0, 40)),
    ];
  }, P);
  check("a page whose handlers do not match the declarations is refused before it mounts", r, [
    `port "${P}get" is declared by the app as a call, but options.ports has no call handler for it`,
    `options.ports has a handler for port "${P}nope", which the app does not declare in with_ports`,
    `port "${P}get" is declared by the app as a call, but options.ports["${P}get"] is a command handler`,
    `options.ports["${P}log"] must have exactly one of command, call, subscribe (functions) or push: true`,
    "mounted",
    "the app declares 7 ports (\"test.roc-sign",
  ]);
  await ctx.close();
}

// Commands: the value revived from JSON, delivered after the batch; a
// handler that throws or rejects is reported and poisons nothing.
{
  const { page, ctx } = await open();
  const r = await page.evaluate(async () => {
    for (let i = 0; i < 3; i += 1) window.__click("Send");
    await window.__turns();
    return { log: window.__seen.log, faults: window.__seen.faults.map((f) => `${f.kind}:${f.message}`), poisoned: !!window.__rt.poisoned };
  });
  check("commands reach their handler; a throw or rejection is reported, never poisoning", r, {
    log: ["hello 1", "hello 2", "hello 3"],
    faults: ["command:command handler threw", "command:command handler rejected"],
    poisoned: false,
  });
  await ctx.close();
}

// Calls: sync and async answers are their own turns; throws, rejections
// and answers that are not JSON data are typed failures.
{
  const { page, ctx } = await open();
  const r = await page.evaluate(async () => {
    const out = [];
    for (const m of ["sync", "async", "throw", "reject", "map", "nan", "undefined"]) {
      window.__mode.get = m;
      const before = window.__log();
      window.__click("Get");
      out.push(await window.__until((t) => t !== before).then((t) => t.split("|").pop()));
    }
    return { out, poisoned: !!window.__rt.poisoned, live: window.__rt.live.size };
  });
  check("a call's answers and failures are values", r, {
    out: [
      "get k1:v:k1",
      "get k2:a:k2",
      "get k3:threw no store",
      "get k4:threw rejected",
      "get k5:threw the answer is not JSON data: a Map at .value",
      "get k6:threw the answer is not JSON data: NaN at .value",
      `get k7:undecodable port "${P}get": missing field \"value\"`,
    ],
    poisoned: false,
    live: 0,
  });
  await ctx.close();
}

// Supersession aborts the older call's signal and drops its late answer; a
// timeout aborts with TimeoutError and answers Timeout.
{
  const { page, ctx } = await open();
  const r = await page.evaluate(async () => {
    window.__mode.get = "held";
    window.__click("Get");
    window.__click("Get");
    const [first, second] = window.__seen.signals;
    const firstReason = first.aborted ? first.reason.name : "not aborted";
    window.__pending.get("k1")({ value: "late" });
    window.__pending.get("k2")({ value: "fresh" });
    await window.__until((t) => t.includes("fresh"));
    await window.__turns();
    window.__mode.get = "never";
    window.__click("Get");
    const third = window.__seen.signals[2];
    const timedOut = await window.__until((t) => t.includes("timeout"));
    return { firstReason, secondAborted: second.aborted, log: timedOut, thirdReason: third.reason.name, timers: window.__rt.timers };
  });
  check("supersession aborts the older call and drops its answer; a timeout aborts and answers Timeout", r, {
    firstReason: "AbortError",
    secondAborted: false,
    log: "get k2:fresh|get k3:timeout",
    thirdReason: "TimeoutError",
    timers: 0,
  });
  await ctx.close();
}

// Disposal keeps a call (its signal is not aborted, its answer delivered)
// and stops a subscription (unsubscribed, signal aborted, emit refused).
{
  const { page, ctx } = await open();
  const r = await page.evaluate(async () => {
    window.__mode.get = "held";
    window.__click("Panel");
    await window.__turns();
    const call = window.__seen.signals[0];
    window.__click("Panel");
    const afterDispose = { callAborted: call.aborted, unsubscribed: window.__seen.unsubscribed, emitAfter: window.__ticks.emit(5n) };
    window.__pending.get("panel")({ value: "kept" });
    const log = await window.__until((t) => t.includes("kept"));
    return { ...afterDispose, log };
  });
  check("disposal keeps a call and stops a subscription", r, { callAborted: false, unsubscribed: 1, emitAfter: false, log: "panel get:kept" });
  await ctx.close();
}

// Delivery: emit never runs a turn synchronously; Latest keeps the newest
// undelivered message; Every(4) takes four and refuses the rest; close
// ends the subscription after its buffered messages.
{
  const { page, ctx } = await open();
  const r = await page.evaluate(async () => {
    window.__mode.ticks = "burst";
    window.__mode.get = "held";
    window.__click("Panel");
    const latest = await window.__until((t) => t.includes("tick:"));
    await window.__turns();
    const ticksLog = window.__log();
    window.__mode.feed = "burst";
    window.__click("Feed");
    await window.__until((t) => t.includes("m3"));
    window.__feed.emit("last");
    window.__feed.close();
    window.__feed.emit("after close");
    const fed = await window.__until((t) => t.includes("closed"));
    // The monitor's per-port counters see the same.
    const ports = window.__rt.monitor.snapshot().ports;
    const feed = ports["test.roc-signals/feed"];
    return { latest, ticksLog, emits: window.__seen.emits, arg: window.__seen.feedArg, fed, live: window.__rt.portSubscriptions("test.roc-signals/feed"), refused: feed.refusedEmits, coalesced: ports["test.roc-signals/ticks"].coalesced, delivered: [feed.messages, feed.closed] };
  });
  check("Latest replaces, Every(n) refuses beyond n, close ends after the buffered messages", r, {
    latest: "tick:3",
    ticksLog: "tick:3",
    emits: [true, true, true, true, true, true, true, false, false],
    arg: "news",
    fed: "tick:3|feed:m0|feed:m1|feed:m2|feed:m3|feed:last|feed:closed",
    live: 0,
    refused: 2,
    coalesced: 2,
    delivered: [5, 1],
  });
  await ctx.close();
}

// A subscribe handler that throws ends its subscription with Threw.
{
  const { page, ctx } = await open();
  const r = await page.evaluate(async () => {
    window.__mode.ticks = "throw";
    window.__mode.get = "held";
    window.__click("Panel");
    return window.__until((t) => t.includes("threw"));
  });
  check("a subscribe handler that throws ends the subscription with Threw", r, "tick:threw cannot subscribe");
  await ctx.close();
}

// The payload bound: an answer larger than maxPayloadBytes is TooLarge.
{
  const { page, ctx } = await open({ maxPayloadBytes: 1000 });
  const r = await page.evaluate(async () => {
    window.__fill("Size", "900");
    window.__click("Echo");
    await window.__until((t) => t.includes("echo:"));
    window.__fill("Size", "1001");
    window.__click("Echo");
    return window.__until((t) => t.includes("too large"));
  });
  check("an answer over maxPayloadBytes is TooLarge", r, "echo:900 1 132|echo:too large");
  const bad = await page.evaluate(() => window.__mount({ maxPayloadBytes: 65 * 1024 * 1024 }));
  check("maxPayloadBytes above 64 MiB is refused", bad, "maxPayloadBytes: 68157440 is not a whole number of bytes from 1 to 67108864");
  await ctx.close();
}

// 8 MiB each way: the handler gets a Uint8Array and the app the same bytes
// back, with no base64 and no growth of the page's heap beyond the bytes.
{
  const { page, ctx } = await open({ maxPayloadBytes: 16 << 20 });
  const r = await page.evaluate(async () => {
    const n = 8 << 20;
    window.__fill("Size", String(n));
    const t0 = performance.now();
    window.__click("Echo");
    const log = await window.__until((t) => t.includes("echo:"));
    const ms = performance.now() - t0;
    return { log, seen: window.__seen.echoIn, ms, live: Number(window.__rt.x.metric(5)) };
  });
  console.log(`     8 MiB round trip: ${r.ms.toFixed(1)} ms, page heap live ${r.live} bytes after`);
  check("8 MiB of bytes cross both ways as bytes", { log: r.log, seen: r.seen, heap: r.live < 40 << 20 }, { log: "echo:8388608 1 0", seen: { isBytes: true, len: 8 << 20 }, heap: true });
  await ctx.close();
}

// Files both ways: a chosen file reaches the handler as the browser's File;
// a File the handler answers becomes a handle, released when the app lets
// it go.
{
  const { page, ctx } = await open();
  const r = await page.evaluate(async () => {
    const input = window.__root.querySelector('[aria-label="Upload"]');
    const dt = new DataTransfer();
    dt.items.add(new File(["hello world"], "greeting.txt", { type: "text/plain" }));
    input.files = dt.files;
    // Choosing a file asks for its inspection.
    input.dispatchEvent(new Event("change", { bubbles: true }));
    await window.__until((t) => t.includes("inspect:"));
    window.__click("Make");
    await window.__until((t) => t.includes("make:"));
    const held = { handles: Number(window.__rt.x.metric(6)), files: window.__rt.files.size };
    window.__click("Forget");
    await window.__turns();
    return { log: window.__log(), held, after: { handles: Number(window.__rt.x.metric(6)), files: window.__rt.files.size } };
  });
  check("files cross both ways as handles and are released with the app's last reference", r, {
    log: "inspect:greeting.txt 11|make:made-1.txt 6",
    held: { handles: 2, files: 2 },
    after: { handles: 0, files: 0 },
  });
  await ctx.close();
}

// Contract errors: a port the program does not declare, and a call port
// used as a subscription, poison the instance naming the port and the site.
{
  const faults = [];
  for (const button of ["Undeclared", "Wrong"]) {
    const { page, ctx } = await open();
    faults.push(
      await page.evaluate(async (button) => {
        window.__click(button);
        const p = window.__rt.poisoned;
        return p ? `${p.class}: ${p.message.replace(/ \(site [^)]*\)/, " (site …)")}` : "healthy";
      }, button),
    );
    await ctx.close();
  }
  check("an undeclared port and a port used as another shape are contract errors", faults, [
    `contract: contract: port "${P}undeclared" is not declared; add its declaration to with_ports (site …)`,
    `contract: contract: port "${P}get" is declared as a call but used as a subscription (site …)`,
  ]);
}

// Poisoning and unmounting abort every call and unsubscribe every
// subscription, with the reason; emitPort then refuses.
{
  const out = [];
  for (const how of ["poison", "unmount"]) {
    const { page, ctx } = await open();
    out.push(
      await page.evaluate(async (how) => {
        window.__mode.get = "held";
        window.__click("Panel");
        await window.__turns();
        if (how === "poison") window.__click("Undeclared");
        else window.__rt.unmount();
        const s = window.__seen.signals[0];
        return { reason: s.reason.message, unsubscribed: window.__seen.unsubscribed, live: window.__rt.live.size };
      }, how),
    );
    await ctx.close();
  }
  check("poisoning and unmounting abort calls and unsubscribe subscriptions", out, [
    { reason: "poisoned", unsubscribed: 1, live: 0 },
    { reason: "unmounted", unsubscribed: 1, live: 0 },
  ]);
}

// A push port: the page's own code feeds every live subscription.
{
  const { page, ctx } = await open();
  const r = await page.evaluate(async () => {
    document.body.textContent = "";
    const h = window.__handlers();
    h["test.roc-signals/feed"] = { push: true };
    await window.__mount({ ports: h });
    const none = window.__rt.emitPort("test.roc-signals/feed", "nobody");
    window.__click("Feed");
    await window.__turns();
    const one = window.__rt.emitPort("test.roc-signals/feed", "pushed");
    const log = await window.__until((t) => t.includes("pushed"));
    let wrong = "";
    try {
      window.__rt.emitPort("test.roc-signals/get", 1);
    } catch (e) {
      wrong = e.message;
    }
    return { none, one, log, wrong };
  });
  check("emitPort feeds a push port's live subscriptions", r, { none: 0, one: 1, log: "feed:pushed", wrong: 'emitPort: port "test.roc-signals/get" is not a subscription port with a push handler' });
  await ctx.close();
}

await browser.close();
server.close();
if (failures > 0) {
  console.log(`${failures} failed`);
  process.exit(1);
}
console.log("ports-browser: all pass");
