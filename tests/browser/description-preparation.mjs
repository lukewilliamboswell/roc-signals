// A prepared ordinary description is reused across simultaneous independent
// instances. Runtime boot values, local row scopes and routes belong to each.
import assert from "node:assert/strict";
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";

const opts = parseArgs(process.argv.slice(2));
const here = path.dirname(fileURLToPath(import.meta.url));
const files = { "index.html": path.join(here, "index.html"), "app.wasm": opts.wasm, ...runtimeFiles(opts.runtime) };
const server = http.createServer((request, response) => {
  const name = path.basename(new URL(request.url, "http://local").pathname) || "index.html";
  const file = files[name];
  if (!file) { response.writeHead(404); response.end(); return; }
  response.writeHead(200, { "content-type": name.endsWith(".wasm") ? "application/wasm" : name.endsWith(".html") ? "text/html" : "text/javascript" });
  response.end(fs.readFileSync(file));
});
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
const browser = await launch({ executablePath: opts.chrome });
try {
  const context = await browser.createBrowserContext();
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", error => errors.push(String(error)));
  await page.evaluateOnNewDocument(() => { window.__mountOptions = { environment: { now: () => 31 } }; });
  await page.goto(`http://127.0.0.1:${server.address().port}/index.html`);
  await page.waitForFunction("window.__ready || window.__error");
  assert.equal(await page.evaluate(() => window.__error ?? null), null);
  const result = await page.evaluate(async () => {
    const { mountRocEngineApp } = await import("./runtime.mjs");
    const first = window.__rt;
    const secondRoot = document.createElement("div");
    document.body.append(secondRoot);
    const second = await mountRocEngineApp({ wasmUrl: "app.wasm", root: secondRoot, environment: { now: () => -9 } });
    const text = (runtime, id) => runtime.root.querySelector(`[data-testid="${id}"]`).textContent;
    const click = (runtime, label) => {
      const button = [...runtime.root.querySelectorAll("button")].find(element => element.textContent === label);
      if (!button) throw new Error(`missing fixture button ${label}`);
      button.click();
    };
    const initial = [text(first, "stamp"), text(second, "stamp")];
    click(first, "Cell above");
    click(first, "Tap one");
    const isolated = [text(first, "cell-above"), text(second, "cell-above"), text(first, "row-one"), text(second, "row-one")];
    const kept = first.root.querySelector('[data-testid="row-one"]');
    click(first, "Reverse");
    const sameRow = kept === first.root.querySelector('[data-testid="row-one"]');
    first.unmount();
    const firstDropped = [Number(first.x.metric(4)), Number(first.x.metric(5))];
    click(second, "Local above");
    const survivor = text(second, "local-above");
    const replacement = await mountRocEngineApp({ wasmUrl: "app.wasm", root: first.root, environment: { now: () => 73 } });
    const fresh = [text(replacement, "stamp"), text(replacement, "cell-above"), text(replacement, "row-one")];
    second.unmount();
    replacement.unmount();
    return {
      initial, isolated, sameRow, firstDropped, survivor, fresh,
      dropped: [second, replacement].map(runtime => [Number(runtime.x.metric(4)), Number(runtime.x.metric(5))]),
    };
  });
  assert.deepEqual(result, {
    initial: ["31", "-9"], isolated: ["1/2", "0/0", "one:1", "one:0"], sameRow: true,
    firstDropped: [0, 0], survivor: "2/1", fresh: ["73", "0/0", "one:0"], dropped: [[0, 0], [0, 0]],
  });
  assert.deepEqual(errors, []);
  await context.close();
  console.log("prepared descriptions: independent live instances, kept rows and fresh remount; zero live allocations/bytes after teardown");
} finally {
  await browser.close();
  await new Promise(resolve => server.close(resolve));
}
