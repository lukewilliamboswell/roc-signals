// The Files app's table record retains File handles after row removal.
// Ordinary teardown must retire those exact handles through Roc reference
// counting, free its allocations, and preserve counters as evidence. A fresh
// browser context alone could hide a leaked retired instance, so this keeps
// its original exports readable after runtime.unmount.
import assert from "node:assert/strict";
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";

const opts = parseArgs(process.argv.slice(2));
const files = { ...runtimeFiles(opts.runtime), "app.wasm": opts.wasm };
const server = http.createServer((req, res) => {
  const name = path.basename(new URL(req.url, "http://localhost").pathname);
  if (!name) {
    res.writeHead(200, { "content-type": "text/html" });
    res.end('<!doctype html><html><head><meta charset="utf-8"><title>Table File lifetime</title></head><body><main></main></body></html>');
    return;
  }
  const file = files[name];
  if (!file) { res.writeHead(404); res.end(); return; }
  res.writeHead(200, { "content-type": file.endsWith(".wasm") ? "application/wasm" : "text/javascript" });
  res.end(fs.readFileSync(file));
});
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
let browser;
try {
  browser = await launch({ executablePath: opts.chrome });
  for (const count of [1, 64]) {
    const context = await browser.createBrowserContext();
    try {
      const page = await context.newPage();
      await page.goto(`http://127.0.0.1:${server.address().port}/`);
      const result = await page.evaluate(async count => {
        const { mountRocEngineApp } = await import("/runtime.mjs");
        const root = document.querySelector("main");
        const faults = [];
        const runtime = await mountRocEngineApp({ wasmUrl: "/app.wasm", root, onFault: fault => faults.push(String(fault)), viewTransitions: "off" });
        const exports = runtime.x;
        const stats = () => ({ allocations: Number(exports.metric(0)), deallocations: Number(exports.metric(1)), requestedBytes: Number(exports.metric(2)), liveAllocations: Number(exports.metric(4)), liveBytes: Number(exports.metric(5)), handles: Number(exports.metric(6)) });
        const click = label => {
          const button = [...root.querySelectorAll("button")].find(button => button.textContent === label);
          if (!button) throw new Error(`Missing ${label}`);
          button.click();
        };
        const transfer = new DataTransfer();
        for (let index = 0; index < count; index += 1) transfer.items.add(new File(["retained"], `table-${index}.txt`, { type: "text/plain" }));
        root.querySelector('[aria-label="Table files"]').dispatchEvent(new DragEvent("drop", { dataTransfer: transfer, bubbles: true, cancelable: true }));
        const loaded = stats();
        click("Remove table files");
        const removed = stats();
        click("Table unrelated");
        const unrelated = stats();
        const rows = root.querySelector('[data-testid="table-rows"]').textContent;
        const tokens = [...runtime.files.keys()].map(String).sort();
        const released = [];
        let drops = 0;
        let resets = 0;
        // Observe existing exports while always calling the real Wasm code.
        // In particular, a reset cannot manufacture the balance below.
        const observed = { ...exports,
          reset_metrics() { resets += 1; throw new Error("Teardown reset allocator counters"); },
          drop() { drops += 1; return exports.drop(); },
          files_released() {
            const length = exports.files_released();
            const address = exports.files_tokens();
            for (const token of new BigUint64Array(exports.memory.buffer, address, length)) released.push(String(token));
            return length;
          },
        };
        runtime.x = observed;
        runtime.unmount();
        const afterDrop = stats();
        // metric(6) includes retired slots. This protocol drain can release
        // only slots whose last Roc reference already went; it cannot free
        // a live handle or conceal a force-reset with missing retirements.
        while (observed.files_released() !== 0) {}
        const drained = stats();
        exports.drop();
        const secondDrop = stats();
        const secondRelease = observed.files_released();
        return { count, loaded, removed, unrelated, rows, tokens, released: released.sort(), afterDrop, drained, secondDrop, secondRelease, drops, resets, runtimeFiles: runtime.files.size, rootChildren: root.childNodes.length, faults };
      }, count);
      for (const phase of ["loaded", "removed", "unrelated"]) assert.equal(result[phase].handles, count, `${phase}: retained handles`);
      assert.equal(result.rows, "table rows 0");
      assert.equal(result.tokens.length, count);
      assert.deepEqual(result.released, result.tokens, "Only actual RC retirement can produce every retained token");
      assert.equal(result.drops, 1);
      assert.equal(result.resets, 0);
      assert.ok(result.unrelated.allocations > 0);
      assert.ok(result.afterDrop.allocations >= result.unrelated.allocations);
      assert.ok(result.afterDrop.requestedBytes >= result.unrelated.requestedBytes);
      assert.ok(result.afterDrop.deallocations > result.unrelated.deallocations);
      assert.equal(result.afterDrop.allocations, result.afterDrop.deallocations);
      assert.equal(result.afterDrop.liveAllocations, 0);
      assert.equal(result.afterDrop.liveBytes, 0);
      assert.equal(result.drained.handles, 0);
      assert.deepEqual(result.secondDrop, result.drained, "A second ordinary drop leaves counters intact");
      assert.equal(result.secondRelease, 0);
      assert.equal(result.runtimeFiles, 0);
      assert.equal(result.rootChildren, 0);
      assert.deepEqual(result.faults, []);
      console.log(JSON.stringify({ case: "retained-table-files-teardown", ...result }));
    } finally { await context.close(); }
  }
} finally {
  if (browser) await browser.close();
  await new Promise(resolve => server.close(resolve));
}
