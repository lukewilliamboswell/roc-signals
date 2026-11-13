import { installProtocolFixture } from "./protocol-fixture.mjs";
// Wire, report-lifetime and real Fetch/XHR transport contracts. Bounded blobs
// pin the browser-owned path without treating heap snapshots as a benchmark.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";

const opts = parseArgs(process.argv.slice(2));
const files = { ...runtimeFiles(opts.runtime), "app.wasm": opts.wasm };
let preflights = 0;
const server = http.createServer((req, res) => {
  res.sendDate = false;
  const u = new URL(req.url, "http://x");
  if (u.pathname === "/upload") {
    if (req.method === "OPTIONS") {
      preflights++;
      if (u.searchParams.has("deny")) { res.writeHead(403); res.end(); return; }
      res.writeHead(204, { "access-control-allow-origin": req.headers.origin, "access-control-allow-methods": "POST", "access-control-allow-headers": "content-type" }); res.end(); return;
    }
    let bytes = 0;
    req.on("data", c => { bytes += c.length; });
    req.on("end", () => { setTimeout(() => { res.writeHead(201, { "content-type": u.searchParams.has("latin") ? "text/plain; charset=iso-8859-1" : "text/plain", "access-control-allow-origin": req.headers.origin ?? "*" }); res.end(u.searchParams.has("latin") ? Buffer.from([0xe9]) : String(bytes)); }, u.searchParams.has("delay") ? 150 : 0); }); return;
  }
  if (u.pathname === "/slow" || u.pathname === "/data" || u.pathname === "/empty-type") {
    const size = u.pathname === "/slow" ? 262144 : 1024 * 1024;
    res.writeHead(202, { "content-length": size, "x-answer": "yes", ...(u.pathname !== "/empty-type" ? { "content-type": "application/x-test" } : {}) });
    if (u.pathname !== "/slow") { res.end(Buffer.alloc(size, 65)); return; }
    let sent = 0;
    const timer = setInterval(() => { if (sent === size) { clearInterval(timer); res.end(); } else { res.write(Buffer.alloc(16384, 65)); sent += 16384; } }, 20);
    req.on("close", () => clearInterval(timer)); return;
  }
  if (u.pathname === "/edge") {
    const body = u.searchParams.has("empty") ? Buffer.alloc(0) : Buffer.from("missing");
    res.writeHead(Number(u.searchParams.get("status") ?? 200), { "content-length": body.length, "content-type": "application/x-edge", "x-answer": "edge" });
    res.end(body); return;
  }
  if (u.pathname === "/reset") { req.socket.destroy(); return; }
  if (u.pathname === "/") { res.writeHead(200, { "content-type": "text/html" }); res.end("<!doctype html><title>HTTP contracts</title>"); return; }
  const file = files[path.basename(u.pathname)];
  if (!file) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { "content-type": file.endsWith(".wasm") ? "application/wasm" : "text/javascript" }); res.end(fs.readFileSync(file));
});
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
const base = `http://127.0.0.1:${server.address().port}`;
const browser = await launch({ executablePath: opts.chrome });
let failures = 0, checks = 0;
function check(name, got, expected = true) {
  checks++;
  const ok = JSON.stringify(got) === JSON.stringify(expected);
  if (!ok) failures++;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok ? "" : `: ${JSON.stringify(got)} != ${JSON.stringify(expected)}`}`);
}
try {
  const page = await browser.newPage();
  await page.goto(base);
  await installProtocolFixture(page);
  await page.evaluate(async () => {
    const { RocEngineRuntime } = await import("/runtime.mjs");
    window.make = (options = {}) => {
      const memory = new WebAssembly.Memory({ initial: 2 });
      const rt = new RocEngineRuntime({ memory, cmd_ptr: () => 0, cmd_len: () => rt.bytes?.length ?? 0 }, document.body, { manualEffects: true, ...options });
      __bindProtocolFixture(rt);
      rt.log = [];
      rt.deliver = (_node, id, payload) => { payload.before?.(); rt.log.push({ id, tag: payload.parts?.[0]?.[0] ?? payload[0], bytes: payload.parts ? null : [...payload], files: payload.files, payload }); };
      return rt;
    };
    window.request = (id, op = "fetch", overrides = {}) => ({ id, op, url: "/data", method: "GET", headers: [], body: "", timeout: 0, cache: "default", credentials: "same-origin", progressMs: 16, ...overrides });
    window.wait = async pred => {
      const deadline = performance.now() + 5000;
      while (!pred()) { if (performance.now() > deadline) throw new Error("contract timed out"); await new Promise(r => setTimeout(r, 5)); }
    };
  });
  const ordering = await page.evaluate(() => {
    const rt = make(); rt.perform(request(1, "http"));
    rt.progressEffect(1, "receiving", "9007199254740993", null);
    rt.progressEffect(1, "receiving", "9007199254740994", "18446744073709551615");
    const pending = rt.pendingEffects().length;
    rt.runEffect(1, { status: 200, body: "ok" });
    const count = new DataView(new Uint8Array(rt.log[0].bytes).buffer).getBigUint64(2, true).toString();
    return [pending, rt.reportsReplaced, rt.log.map(e => e.tag), count, rt.live.size, rt.progressEffect(1, "receiving", 1, null)];
  });
  check("replacement keeps exact U64 counts and drains before terminal result", ordering, [1, 1, [26, 1], "9007199254740994", 0, false]);
  const cancellation = await page.evaluate(() => {
    const rt = make(); rt.perform(request(1, "http")); rt.progressEffect(1, "receiving", 1, null); rt.cancel(1); rt.releaseReports();
    rt.perform(request(2, "http")); rt.progressEffect(2, "receiving", 2, null); rt.runEffect(2, { timeout: true });
    rt.perform(request(3, "http", { progressMs: 0 }));
    return [rt.log.map(e => e.tag), rt.progressEffect(3, "receiving", 3, null), rt.reportSources.size];
  });
  check("CANCEL and timeout discard reports; opt-out rejects manual progress", cancellation, [[7], false, 0]);
  const pinned = await page.evaluate(() => {
    const rt = make(); rt.perform(request(1, "http")); rt.busy = true;
    rt.progressEffect(1, "receiving", 1, null); rt.result(99, new Uint8Array([4])); rt.progressEffect(1, "receiving", 2, null);
    rt.runEffect(1, { status: 200 }); rt.busy = false; rt.drainQueue();
    return rt.log.map(e => [e.id, e.tag]);
  });
  check("progress retains source ownership across pinned epochs until final", pinned, [[1, 26], [99, 4], [1, 26], [1, 1]]);
  const raw = await page.evaluate(() => {
    const u32 = n => { const b = new Uint8Array(4); new DataView(b.buffer).setUint32(0, n, true); return [...b]; };
    const str = s => { const b = [...new TextEncoder().encode(s)]; return [...u32(b.length), ...b]; };
    const bytes = (kind, cache = 1, credentials = 1, progress = 16) => new Uint8Array([0, 13, ...u32(1), kind, ...str("GET"), ...str("/data"), ...u32(0), ...(kind === 1 ? str("") : kind === 12 ? [1, ...Array(23).fill(0)] : []), ...u32(0), cache, credentials, ...u32(progress)]);
    const decode = b => { const rt = make(); rt.files.set(1, new File([], "empty")); rt.bytes = b; new Uint8Array(rt.x.memory.buffer).set(b); rt.applyBatch(); return rt.fxOut[0]; };
    const bad = [bytes(1, 0), bytes(1, 6), bytes(15, 1, 0), bytes(15, 1, 3), bytes(15, 1, 1, 15), bytes(15).slice(0, -1), new Uint8Array([...bytes(1), 255]), bytes(12, 2), bytes(12, 1, 3)];
    return [decode(bytes(1, 2, 2)).cache, decode(bytes(15, 5, 1, 0)).credentials, bad.map(b => { try { decode(b); return false; } catch { return true; } })];
  });
  check("extended HTTP/Fetch wire consumes strict enums, floor and full framing", raw, ["no-store", "same-origin", Array(9).fill(true)]);
  const largeTimer = await page.evaluate(() => {
    const original = window.setTimeout, originalClear = window.clearTimeout, originalNow = performance.now;
    let time = 0, callback;
    const waits = []; window.setTimeout = (fn, ms) => { callback = fn; waits.push(ms); return 44; }; window.clearTimeout = () => {};
    performance.now = () => time;
    try {
      const rt = make(), fx = request(1, "http", { progressMs: 4294967295 }), entry = { req: fx };
      rt.live.set(1, entry); const sampler = rt.transferSampler(fx, entry); sampler.sample("receiving", 1, null);
      time = 2147483647; callback(); const first = rt.queue.length;
      time = 4294967294; callback(); const second = rt.queue.length;
      time = 4294967295; callback(); rt.releaseReports(); sampler.clear();
      return [waits, first, second, rt.log.map(e => e.tag), rt.timers];
    } finally { window.setTimeout = original; window.clearTimeout = originalClear; performance.now = originalNow; }
  });
  check("U32 sampling intervals split without reporting before their deadline", largeTimer, [[2147483647, 2147483647, 1], 0, 0, [26], 0]);
  const paths = await page.evaluate(async () => {
    const blob = Response.prototype.blob, reader = ReadableStream.prototype.getReader;
    let blobCalls = 0, reads = 0;
    Response.prototype.blob = function (...a) { blobCalls++; return blob.apply(this, a); };
    ReadableStream.prototype.getReader = function (...a) { reads++; return reader.apply(this, a); };
    const one = async (progressMs, cache, url = "/data") => { const rt = make(); rt.manual = false; rt.startTransfer(request(1, "fetch", { progressMs, cache, url })); await wait(() => !rt.live.size); rt.releaseReports(); const answer = rt.log.find(e => e.tag !== 26); return [answer.tag, answer.files?.[0]?.size, answer.files?.[0]?.type, rt.timers]; };
    try {
      const a = await one(0, "default"), first = [reads, blobCalls];
      const b = await one(16, "default"), second = [reads, blobCalls];
      const c = await one(16, "no-store"), third = [reads, blobCalls];
      const d = await one(0, "default", "/empty-type"), e = await one(16, "default", "/empty-type");
      return [a, b, c, first, second, third, d[2], e[2]];
    } finally { Response.prototype.blob = blob; ReadableStream.prototype.getReader = reader; }
  });
  check("bounded file paths: fetch blob / XHR blob avoid readers; cache progress reads", paths, [[21, 1048576, "application/x-test", 0], [21, 1048576, "application/x-test", 0], [21, 1048576, "application/x-test", 0], [0, 1], [0, 1], [1, 1], "", ""]);
  const parity = await page.evaluate(async () => {
    const one = async (progressMs, url) => {
      const rt = make(); rt.manual = false; rt.startTransfer(request(1, "fetch", { progressMs, url })); await wait(() => !rt.live.size);
      const answer = rt.log.find(e => e.tag !== 26);
      return answer.tag === 21 ? [answer.tag, [...answer.payload.parts[0]], ...answer.payload.parts.slice(1).map(b => [...b]), answer.files[0].type] : [answer.tag];
    };
    return [JSON.stringify(await one(0, "/data")) === JSON.stringify(await one(16, "/data")), await one(0, "/reset"), await one(16, "/reset")];
  });
  check("Fetch and XHR agree exactly on status, headers, type and failure class", parity, [true, [2], [2]]);
  const edgeParity = await page.evaluate(async () => {
    const one = async (progressMs, method, url) => {
      const rt = make(); rt.manual = false;
      rt.startTransfer(request(1, "fetch", { progressMs, method, url })); await wait(() => !rt.live.size);
      const answer = rt.log.find(e => e.tag !== 26), file = answer.files?.[0];
      const header = answer.payload.parts?.[0];
      return { tag: answer.tag, status: header ? header[1] + header[2] * 256 : null, record: answer.payload.parts?.map(b => [...b]), size: file?.size, type: file?.type, body: file ? await file.text() : null };
    };
    const results = [];
    for (const [method, url] of [["HEAD", "/edge"], ["GET", "/edge?empty"], ["GET", "/edge?status=404"], ["GET", "/edge?empty&status=404"]]) {
      const fetched = await one(0, method, url), xhr = await one(16, method, url);
      results.push([method, url, JSON.stringify(fetched) === JSON.stringify(xhr), xhr.tag, xhr.status, xhr.size, xhr.type, xhr.body]);
    }
    return results;
  });
  check("HEAD, empty and non-2xx file responses preserve Blob, status, headers and type across transports", edgeParity, [
    ["HEAD", "/edge", true, 21, 200, 0, "application/x-edge", ""],
    ["GET", "/edge?empty", true, 21, 200, 0, "application/x-edge", ""],
    ["GET", "/edge?status=404", true, 21, 404, 7, "application/x-edge", "missing"],
    ["GET", "/edge?empty&status=404", true, 21, 404, 0, "application/x-edge", ""],
  ]);
  const stream = await page.evaluate(async () => {
    const rt = make(); rt.manual = false; rt.startTransfer(request(1, "http", { url: "/slow" })); await wait(() => !rt.live.size);
    const progress = rt.log.filter(e => e.tag === 26);
    return [progress.length > 0, progress.every(e => e.bytes[1] === 2 && e.bytes[10] === 1), rt.log.at(-1).tag, rt.timers];
  });
  check("real HTTP stream emits Receiving reports before its final response", stream, [true, true, 1, 0]);
  const overrides = await page.evaluate(async () => {
    const calls = [];
    const rt = make({ fetch: (url, init) => { calls.push([url, init.cache, init.credentials, init.body?.size ?? null]); return new Response("hello", { status: 201, headers: { "content-type": "text/plain" } }); } });
    rt.manual = false;
    for (const [id, op] of [[1, "http"], [2, "fetch"], [3, "upload"]]) {
      rt.startTransfer(request(id, op, { method: op === "upload" ? "POST" : "GET", cache: "reload", credentials: "include", blob: new Blob(["123"]) })); await wait(() => !rt.live.size);
    }
    return [calls, rt.log.map(e => e.tag), rt.log.filter(e => e.tag === 26).map(e => e.bytes[1])];
  });
  check("explicit fetch backend receives every request and options; upload progress is coarse", overrides, [[["/data", "reload", "include", null], ["/data", "reload", "include", null], ["/data", "reload", "include", 3]], [1, 21, 26, 1], [1]]);
  const bounds = await page.evaluate(async () => {
    const one = async progressMs => { const rt = make({ maxFileBytes: 10 }); rt.manual = false; rt.startTransfer(request(1, "fetch", { progressMs, cache: "no-store" })); await wait(() => !rt.live.size); return [rt.log.at(-1).tag, rt.log.at(-1).bytes?.[1], rt.timers]; };
    return [await one(0), await one(16)];
  });
  check("blob and buffered file paths both refuse maxFileBytes as TooLarge", bounds, [[13, 2, 0], [13, 2, 0]]);
  const cancelled = await page.evaluate(async () => {
    const rt = make(); rt.manual = false; rt.startTransfer(request(1, "fetch", { url: "/slow" }));
    await wait(() => rt.log.some(e => e.tag === 26)); rt.cancel(1); const count = rt.log.length;
    await new Promise(r => setTimeout(r, 100));
    const timeout = make(); timeout.manual = false; timeout.startTransfer(request(2, "http", { url: "/slow", timeout: 30, progressMs: 100 })); await wait(() => !timeout.live.size);
    return [rt.log.length === count, rt.timers, rt.reportSources.size, timeout.log.map(e => e.tag), timeout.timers];
  });
  check("real cancel aborts XHR with no later result; timeout discards unsampled progress", cancelled, [true, 0, 0, [7], 0]);
  const sending = await page.evaluate(async () => {
    const rt = make(); rt.manual = false;
    rt.startTransfer(request(1, "upload", { url: "/upload?delay", method: "POST", blob: new Blob([new Uint8Array(1048576)]) }));
    await wait(() => !rt.live.size);
    const reports = rt.log.filter(e => e.tag === 26);
    return [reports.length > 0, reports.every(e => e.bytes[1] === 1 && e.bytes[10] === 1), rt.log.at(-1).tag, rt.timers];
  });
  check("real XHR upload reports sent counts while waiting for the answer", sending, [true, true, 1, 0]);
  const textParity = await page.evaluate(async () => {
    const one = async progressMs => { const rt = make(); rt.manual = false; rt.startTransfer(request(1, "upload", { url: "/upload?latin", method: "POST", blob: new Blob(["hi"]), progressMs })); await wait(() => !rt.live.size); return rt.log.at(-1).bytes; };
    return JSON.stringify(await one(0)) === JSON.stringify(await one(16));
  });
  check("XHR upload response decodes UTF-8 exactly as Fetch despite a different charset", textParity);
  const encoded = await page.evaluate(async () => {
    const rt = make({ fetch: () => new Response(new ReadableStream({ start(controller) { controller.enqueue(new Uint8Array(10)); setTimeout(() => controller.close(), 80); } }), { headers: { "content-length": "10", "content-encoding": "gzip" } }) });
    rt.manual = false; rt.startTransfer(request(1, "http")); await wait(() => !rt.live.size);
    return [rt.log.filter(e => e.tag === 26).map(e => e.bytes[10]), rt.log.at(-1).tag];
  });
  check("encoded receiving bodies have Unknown total", encoded, [[0], 1]);
  // A different port is a cross origin reachable on the same loopback address.
  const corsServer = http.createServer(server.listeners("request")[0]);
  await new Promise(r => corsServer.listen(0, "127.0.0.1", r));
  try {
    const url = `http://127.0.0.1:${corsServer.address().port}/upload`;
    const before = preflights;
    const upload = await page.evaluate(async url => {
      const one = async progressMs => { const rt = make(); rt.manual = false; rt.startTransfer(request(1, "upload", { url, method: "POST", blob: new Blob([new Uint8Array(1024 * 1024)], { type: "text/plain" }), progressMs })); await wait(() => !rt.live.size); return rt.log.at(-1).tag; };
      return [await one(0), await one(16)];
    }, url);
    check("cross-origin upload with progress sends a CORS preflight", [upload, preflights - before], [[1, 1], 1]);
    const denied = await page.evaluate(async url => {
      const one = async progressMs => { const rt = make(); rt.manual = false; rt.startTransfer(request(1, "upload", { url: url + "?deny", method: "POST", blob: new Blob(["hello"], { type: "text/plain" }), progressMs })); await wait(() => !rt.live.size); return rt.log.at(-1).tag; };
      return [await one(0), await one(16)];
    }, url);
    check("server refusing OPTIONS fails progress upload, while simple Fetch succeeds", denied, [1, 2]);
  } finally { corsServer.close(); }
  const rejected = await page.evaluate(async () => {
    const { mountRocEngineApp } = await import("/runtime.mjs");
    const progress = new Uint8Array(19); progress[0] = 26; progress[1] = 1; progress[2] = 1;
    const changed = (index, value) => { const b = progress.slice(); b[index] = value; return b; };
    const cases = [progress.slice(0, -1), new Uint8Array([...progress, 0]), changed(1, 0), changed(1, 3), changed(10, 2), changed(11, 1), progress];
    const results = [];
    for (const bytes of cases) {
      const root = document.createElement("div"); document.body.append(root);
      const rt = await mountRocEngineApp({ wasmUrl: "/app.wasm", root, manualEffects: true, onFault: () => {} });
      const dt = new DataTransfer(); dt.items.add(new File(["abc"], "input.txt", { type: "text/plain" }));
      const input = root.querySelector('[aria-label="Upload"]'); input.files = dt.files; input.dispatchEvent(new Event("change", { bubbles: true }));
      [...root.querySelectorAll("button")].find(e => e.textContent === "Send").click();
      const request = rt.pendingEffects().find(e => e.op === "upload");
      if (!request || request.progressMs !== 0) throw new Error("Send must provide a pending resource upload without a progress handler");
      rt.result(request.id, bytes);
      results.push([rt.poisoned?.class, rt.poisoned?.message.includes("progress")]);
      rt.unmount(); root.remove();
    }
    return results;
  });
  check("real engine rejects truncated, trailing, invalid and unsolicited progress", rejected, Array(7).fill(["contract", true]));
  const appProgress = await page.evaluate(async () => {
    const { mountRocEngineApp } = await import("/runtime.mjs");
    const root = document.createElement("div"); document.body.append(root);
    const rt = await mountRocEngineApp({ wasmUrl: "/app.wasm", root, manualEffects: true, onFault: () => {} });
    const click = name => [...root.querySelectorAll("button")].find(e => e.textContent === name).click();
    const text = id => root.querySelector(`[data-testid="${id}"]`).textContent;
    const dt = new DataTransfer(); dt.items.add(new File(["abc"], "input.txt", { type: "text/plain" }));
    const input = root.querySelector('[aria-label="Upload"]'); input.files = dt.files; input.dispatchEvent(new Event("change", { bubbles: true }));
    click("Send progress"); let req = rt.pendingEffects().find(e => e.op === "upload");
    const options = [req.credentials, req.progressMs];
    rt.progressEffect(req.id, "sending", 1, null);
    rt.progressEffect(req.id, "sending", "9007199254740993", "18446744073709551615");
    rt.runEffect(req.id, { status: 200, body: "ok" });
    const first = [text("transfer-progress"), text("transfer-result"), rt.reportsReplaced, String(rt.workRecord().counters[47]), String(rt.workRecord().counters[33])];
    click("Send panel"); req = rt.pendingEffects().find(e => e.op === "upload"); click("Send panel");
    rt.progressEffect(req.id, "receiving", 9, null); rt.releaseReports();
    const reparented = [text("transfer-progress"), String(rt.workRecord().counters[37]), rt.pendingEffects().length];
    rt.runEffect(req.id, { status: 200, body: "kept" });
    const final = [text("panel-sent"), String(rt.workRecord().counters[47]), String(rt.workRecord().counters[33]), rt.live.size];
    rt.unmount(); root.remove(); return [options, first, reparented, final];
  });
  check("real engine progress is a counted turn; queued progress precedes final and reparents", appProgress, [["include", 16], ["sending 9007199254740993/18446744073709551615", "sent ok", 1, "1", "1"], ["receiving 9/unknown", "1", 1], ["sent kept", "2", "2", 0]]);
  await page.close();
} finally { await browser.close(); server.close(); }
console.log(`== http-progress-browser: ${checks} contracts, ${failures} failed`);
process.exitCode = failures ? 1 : 0;
