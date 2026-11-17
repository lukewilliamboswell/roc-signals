// Real development Wasm must reclaim empty UTF-8 crypto inputs too. Separate
// password/plaintext cases identify whether protocol encoding or app-provided
// bytes retained an allocation; repeated cycles make per-request leaks visible.
import assert from "node:assert/strict";
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";

const options = parseArgs(process.argv.slice(2));
const here = path.dirname(fileURLToPath(import.meta.url));
const files = { "index.html": path.join(here, "index.html"), "app.wasm": options.wasm, ...runtimeFiles(options.runtime) };
const server = http.createServer((request, response) => {
  const route = new URL(request.url, "http://x").pathname;
  const file = files[route.endsWith("/") ? "index.html" : path.basename(route)];
  if (!file) { response.writeHead(404); response.end(); return; }
  response.writeHead(200, { "content-type": file.endsWith(".wasm") ? "application/wasm" : file.endsWith(".html") ? "text/html" : "text/javascript" });
  response.end(fs.readFileSync(file));
});
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
let browser;
try {
  browser = await launch({ executablePath: options.chrome });
  const results = [];
  for (const inputs of [
    { name: "empty password", password: "", plaintext: "secret λ" },
    { name: "empty plaintext", password: "correct horse", plaintext: "" },
    { name: "both empty", password: "", plaintext: "" },
  ]) {
    const context = await browser.createBrowserContext();
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", error => errors.push(String(error)));
    await page.evaluateOnNewDocument(() => { window.__manualFx = true; });
    await page.goto(`http://127.0.0.1:${server.address().port}/`);
    await page.waitForFunction("window.__ready || window.__error");
    assert.equal(await page.evaluate(() => window.__error ?? null), null, inputs.name);
    const result = await page.evaluate(async ({ password, plaintext }) => {
      const runtime = window.__rt;
      const need = (condition, message) => { if (!condition) throw new Error(message); };
      const read = id => document.querySelector(`[data-testid="${id}"]`).textContent;
      const fill = (name, value) => {
        const input = document.querySelector(`input[aria-label="${name}"]`);
        input.value = value;
        input.dispatchEvent(new Event("input", { bubbles: true }));
      };
      const click = label => [...document.querySelectorAll("button")].find(button => button.textContent === label).click();
      const answer = async label => {
        click(label);
        need(runtime.pendingEffects().length === 1, `${label}: expected exactly one pending request`);
        await runtime.runEffect(runtime.issued.at(-1));
        need(runtime.poisoned === null, `${label}: runtime poisoned`);
        need(runtime.pendingEffects().length === 0, `${label}: result was not delivered`);
      };
      for (let cycle = 0; cycle < 3; cycle += 1) {
        fill("Password", password); fill("Plaintext", plaintext);
        await answer("Unlock SHA-256");
        need(Number(runtime.x.metric(7)) === 1, "derived key must be held once");
        await answer("Seal");
        need(read("result") === `sealed iv=12 bytes=${new TextEncoder().encode(plaintext).length + 16}`, "sealed length differs");
        await answer("Open");
        need(read("result") === "opened" && read("plaintext") === plaintext, "authenticated bytes differ");
        click("Lock");
        need(Number(runtime.x.metric(7)) === 0, "lock retained a key");
        click("Reset");
      }
      runtime.unmount();
      return { allocations: Number(runtime.x.metric(4)), bytes: Number(runtime.x.metric(5)), keys: Number(runtime.x.metric(7)), browserKeys: runtime.keys.size };
    }, inputs);
    assert.deepEqual(errors, [], `${inputs.name}: browser errors`);
    results.push({ name: inputs.name, ...result });
    await context.close();
  }
  console.log(JSON.stringify({ cycles: 3, results }));
  for (const result of results) {
    const { name, ...retained } = result;
    assert.deepEqual(retained, { allocations: 0, bytes: 0, keys: 0, browserKeys: 0 }, `${name}: unmount retained ownership`);
  }
  console.log("ok   empty cryptographic inputs release all Wasm allocations and keys");
} finally {
  if (browser) await browser.close();
  await new Promise(resolve => server.close(resolve));
}
