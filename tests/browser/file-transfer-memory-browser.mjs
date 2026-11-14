import { installProtocolFixture } from "./protocol-fixture.mjs";
// A fixed 32 MiB transport retention proof, not a throughput benchmark.
// Chunked EOF is held while the real runtime is in flight. CDP's byte events
// prove complete renderer arrival for XHR and streamed Fetch. Native Fetch.blob
// can bypass those events: its route is guarded, its server writes are drained,
// and its eventual full-size File independently proves completion. Both the
// in-flight sample and retained final File are measured, with that observability
// difference printed explicitly. A buffered Fetch positive control must retain
// the body in measured JavaScript backing storage before EOF. No response body
// is captured through DevTools. These metrics cover renderer JavaScript/Wasm,
// not whole-browser RSS or the browser's Blob storage.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";

const opts = parseArgs(process.argv.slice(2), [], ["runtime"]);
const files = runtimeFiles(opts.runtime);
const MIB = 1024 * 1024;
const BODY_BYTES = 32 * MIB;
const chunk = Buffer.alloc(64 * 1024, 65);
const held = new Map();
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://x");
  if (url.pathname === "/body") {
    res.writeHead(202, { "content-type": "application/x-memory-test", "cache-control": "no-store", "x-answer": "memory" });
    held.set(url.searchParams.get("case"), res);
    for (let sent = 0; sent < BODY_BYTES; sent += chunk.length) {
      if (!res.write(chunk)) await new Promise(resolve => res.once("drain", resolve));
      res.sentBytes = sent + chunk.length;
    }
    // All bytes are written; the test alone releases EOF after measuring.
    return;
  }
  if (url.pathname === "/") {
    res.writeHead(200, { "content-type": "text/html" });
    res.end("<!doctype html><title>File transfer retention</title>");
    return;
  }
  const file = files[path.basename(url.pathname)];
  if (!file) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { "content-type": "text/javascript" });
  res.end(fs.readFileSync(file));
});
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
const base = `http://127.0.0.1:${server.address().port}`;

function assert(condition, message) {
  if (!condition) throw new Error(message);
}
async function until(predicate, message) {
  const deadline = Date.now() + 15000;
  while (!await predicate()) {
    if (Date.now() >= deadline) throw new Error(`timed out: ${message}`);
    await new Promise(resolve => setTimeout(resolve, 10));
  }
}
async function memory(page) {
  await page.send("HeapProfiler.collectGarbage");
  const heap = await page.send("Runtime.getHeapUsage");
  for (const key of ["usedSize", "backingStorageSize"]) {
    assert(Number.isFinite(heap[key]) && heap[key] >= 0, `Runtime.getHeapUsage did not supply ${key}`);
  }
  return {
    jsHeap: heap.usedSize,
    backingStorage: heap.backingStorageSize,
    wasm: await page.evaluate(() => window.rt.x.memory.buffer.byteLength),
  };
}
function growth(before, after) {
  return Object.fromEntries(Object.keys(before).map(key => [key, after[key] - before[key]]));
}

const measurements = [];
try {
  for (const transport of [
    { name: "fetch-blob", progressMs: 0, cache: "default" },
    { name: "xhr-blob", progressMs: 16, cache: "default" },
    { name: "buffered-fetch", progressMs: 16, cache: "no-store" },
  ]) {
    // A fresh browser isolates each transport's heap, cache and Blob lifetime.
    const browser = await launch({ executablePath: opts.chrome });
    try {
      const page = await browser.newPage();
      const errors = [];
      page.on("pageerror", error => errors.push(String(error)));
      await page.goto(base);
      await installProtocolFixture(page);
      await page.evaluate(async () => {
        const { RocEngineRuntime } = await import("/runtime.mjs");
        const memory = new WebAssembly.Memory({ initial: 2 });
        // Like the HTTP contracts, isolate transport behavior with lightweight
        // exports. The unmodified runtime owns transport and request lifetime.
        window.rt = new RocEngineRuntime({ memory, cmd_ptr: () => 0, cmd_len: () => 0, drop: () => {} }, document.body, {});
        __bindProtocolFixture(window.rt);
        window.calls = { blob: 0, reader: 0, xhr: 0 };
        const blob = Response.prototype.blob, reader = ReadableStream.prototype.getReader, send = XMLHttpRequest.prototype.send;
        Response.prototype.blob = function (...args) { window.calls.blob++; return blob.apply(this, args); };
        ReadableStream.prototype.getReader = function (...args) { window.calls.reader++; return reader.apply(this, args); };
        XMLHttpRequest.prototype.send = function (...args) { window.calls.xhr++; return send.apply(this, args); };
        window.progress = 0;
        window.rt.deliver = (_node, _id, payload) => {
          payload.before?.();
          const tag = payload.parts?.[0]?.[0] ?? payload[0];
          if (tag === 26) window.progress += 1;
          else window.answer = payload;
        };
      });
      let requestId = null, received = 0, completed = false;
      page.conn.on(page.sessionId, "Network.requestWillBeSent", event => {
        if (event.request.url === `${base}/body?case=${transport.name}`) requestId = event.requestId;
      });
      page.conn.on(page.sessionId, "Network.dataReceived", event => {
        if (event.requestId === requestId) received += event.dataLength;
      });
      page.conn.on(page.sessionId, "Network.loadingFinished", event => {
        if (event.requestId === requestId) completed = true;
      });
      // Retain event metadata only, with a one-byte inspector body-cache bound.
      await page.send("Network.enable", { maxTotalBufferSize: 1, maxResourceBufferSize: 1 });
      const before = await memory(page);
      await page.evaluate(transport => window.rt.startTransfer({
        id: 1, op: "fetch", url: `/body?case=${transport.name}`, method: "GET", headers: [], body: "", timeout: 0,
        credentials: "same-origin", progressMs: transport.progressMs, cache: transport.cache,
      }), transport);
      await until(() => held.get(transport.name)?.sentBytes === BODY_BYTES, `${transport.name}: server wrote the bounded body`);
      if (transport.name !== "fetch-blob") {
        await until(() => received === BODY_BYTES, `${transport.name}: all body bytes reached the renderer before EOF`);
      } else {
        await until(() => page.evaluate(() => window.calls.blob === 1), "native Fetch.blob began consuming its response");
      }
      assert(!completed, `${transport.name}: request completed before its plateau`);
      assert(await page.evaluate(() => window.rt.live.size === 1 && !window.answer), `${transport.name}: plateau was not in flight`);
      const arrival = { serverWritten: held.get(transport.name).sentBytes, devtoolsReceived: received, rendererArrivalProven: received === BODY_BYTES };
      const plateau = await memory(page);
      assert(!completed, `${transport.name}: EOF escaped during measurement`);
      const calls = await page.evaluate(() => window.calls);
      const expectedCalls = transport.name === "fetch-blob" ? { blob: 1, reader: 0, xhr: 0 }
        : transport.name === "xhr-blob" ? { blob: 0, reader: 0, xhr: 1 } : { blob: 0, reader: 1, xhr: 0 };
      assert(JSON.stringify(calls) === JSON.stringify(expectedCalls), `${transport.name}: transport route changed ${JSON.stringify(calls)}`);
      held.get(transport.name).end();
      await until(() => page.evaluate(() => !!window.answer && window.rt.live.size === 0), `${transport.name}: terminal file answer`);
      const retainedFile = await memory(page);
      const answer = await page.evaluate(async () => {
        window.rt.releaseReports();
        const payload = window.answer, file = payload.files?.[0];
        return {
          tag: payload.parts?.[0]?.[0] ?? payload[0],
          status: payload.parts ? payload.parts[0][1] + payload.parts[0][2] * 256 : null,
          size: file?.size, type: file?.type,
          edges: file ? [new Uint8Array(await file.slice(0, 1).arrayBuffer())[0], new Uint8Array(await file.slice(-1).arrayBuffer())[0]] : [],
          progress: window.progress, live: window.rt.live.size, timers: window.rt.timers, reports: window.rt.reportSources.size,
        };
      });
      assert(answer.tag === 21 && answer.status === 202 && answer.size === BODY_BYTES && answer.type === "application/x-memory-test", `${transport.name}: wrong final file ${JSON.stringify(answer)}`);
      assert(JSON.stringify(answer.edges) === "[65,65]", `${transport.name}: file bytes changed`);
      assert(answer.live === 0 && answer.timers === 0 && answer.reports === 0, `${transport.name}: transfer resources survived completion`);
      assert((answer.progress > 0) === (transport.progressMs > 0), `${transport.name}: progress opt-in changed`);
      await page.evaluate(() => { window.answer = null; window.rt.unmount(); });
      const after = await memory(page);
      assert(errors.length === 0, `${transport.name}: browser errors ${JSON.stringify(errors)}`);
      measurements.push({ transport: transport.name, arrival, calls, before, plateau, growth: growth(before, plateau), retainedFile, retainedFileGrowth: growth(before, retainedFile), after, cleanupGrowth: growth(before, after), answer });
      console.log(JSON.stringify(measurements.at(-1)));
    } finally {
      held.get(transport.name)?.destroy();
      held.delete(transport.name);
      await browser.close();
    }
  }
  const [fetchBlob, xhrBlob, buffered] = measurements;
  for (const result of measurements) {
    assert(result.growth.wasm === 0 && result.retainedFileGrowth.wasm === 0 && result.cleanupGrowth.wasm === 0, `${result.transport}: file body grew Wasm memory`);
    assert(result.retainedFileGrowth.jsHeap + result.retainedFileGrowth.backingStorage < 4 * MIB, `${result.transport}: completed file retained body-sized JavaScript storage`);
    assert(result.cleanupGrowth.jsHeap + result.cleanupGrowth.backingStorage < 2 * MIB, `${result.transport}: body-sized backing storage survived cleanup`);
  }
  for (const result of [fetchBlob, xhrBlob]) {
    assert(result.growth.jsHeap + result.growth.backingStorage < 4 * MIB, `${result.transport}: body-sized JavaScript retention`);
  }
  assert(Math.abs(fetchBlob.growth.jsHeap + fetchBlob.growth.backingStorage - xhrBlob.growth.jsHeap - xhrBlob.growth.backingStorage) < 2 * MIB, "Fetch.blob and XHR.blob JavaScript retention diverged");
  assert(buffered.growth.backingStorage >= BODY_BYTES * 0.9, "positive control did not expose retained stream chunks");
  assert(buffered.growth.backingStorage - Math.max(fetchBlob.growth.backingStorage, xhrBlob.growth.backingStorage) >= BODY_BYTES * 0.75, "positive control did not materially exceed browser-owned paths");
  console.log("file-transfer-memory-browser: passed (32 MiB; renderer JavaScript/backing storage and Wasm only)");
} finally {
  for (const response of held.values()) response.destroy();
  server.closeAllConnections();
  await new Promise(resolve => server.close(resolve));
}
