// Mount declarations and requests through the real Wasm host. Invalid timing
// and conflicting declarations are contracts; raw elements keep their attributes.
// Failed mounts and unmount both release every browser listener.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { launch } from "./cdp.mjs";
import { runtimeFiles } from "./args.mjs";

const options = {};
for (let i = 2; i < process.argv.length; i += 2) {
  const name = process.argv[i].replace(/^--/, "");
  if (!["fixtures", "runtime", "chrome"].includes(name) || !process.argv[i + 1]) throw new Error("usage: --fixtures DIR --runtime FILE --chrome FILE");
  options[name] = process.argv[i + 1];
}
for (const name of ["fixtures", "runtime", "chrome"]) if (!options[name]) throw new Error(`--${name} is required`);
const fixtures = [
  ["text-key", ["on_key", "site"]],
  ["document-bound", ["more than 32", "site"]],
  ["apply-noncontrol", ["ApplyValue", "reference \"bad\"", "site"]],
  ["apply-without-value", ["ApplyValue", "reference \"bad\"", "site"]],
  ["dialog-open", ["owned by the controlled dialog", "site"]],
  ["dialog-dynamic-open", ["owned by the controlled dialog", "site"]],
  ["dialog-popover", ["popover and closedby", "site"]],
  ["dialog-dynamic-popover", ["popover and closedby", "site"]],
  ["dialog-closedby", ["popover and closedby", "site"]],
  ["dialog-dynamic-closedby", ["popover and closedby", "site"]],
  ["controlled-beforetoggle", ["beforetoggle", "site"]],
  ["popover-beforetoggle", ["beforetoggle", "site"]],
  ["popover-duplicate", ["one static popover", "site"]],
  ["popover-dynamic-popover", ["one static popover", "site"]],
  ["media-undeclared", ["missing-media", "site"]],
  ["interval-zero", ["Interval(0) has no period"]],
  ["timer-overflow", ["Timer(3000000000)", "2147483647 ms"]],
  ["interval-overflow", ["Interval(2147483648)", "2147483647 ms"]],
  ["timer-overflow-boundary", ["Timer(2147483648)", "2147483647 ms"]],
  ["timeout-zero", ["a timeout of Ms(0)", "write Unlimited"]],
  ["raw-controlled-attributes", [], false],
];
const runtime = runtimeFiles(options.runtime);
const server = http.createServer((request, response) => {
  const url = new URL(request.url, "http://x");
  if (url.pathname === "/") { response.writeHead(200, { "content-type": "text/html" }); response.end("<!doctype html><div id=app></div>"); return; }
  const name = path.basename(url.pathname);
  let file = runtime[name];
  if (name === "app.wasm" && fixtures.some(([fixture]) => url.pathname === `/${fixture}/app.wasm`)) file = path.join(options.fixtures, url.pathname.slice(1));
  if (!file) { response.writeHead(404); response.end(); return; }
  response.writeHead(200, { "content-type": name.endsWith("wasm") ? "application/wasm" : "text/javascript" }); response.end(fs.readFileSync(file));
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const browser = await launch({ executablePath: options.chrome });
let failures = 0;
try {
  for (const [fixture, needles, rejected = true] of fixtures) {
    const context = await browser.createBrowserContext();
    try {
      const page = await context.newPage();
      await page.goto(`http://127.0.0.1:${server.address().port}/`);
      const result = await page.evaluate(async (fixture) => {
        const { mountRocEngineApp } = await import("/runtime.mjs");
        const faults = [];
        const runtime = await mountRocEngineApp({ wasmUrl: `/${fixture}/app.wasm`, root: document.getElementById("app"), onFault: (fault) => faults.push(fault) });
        const fault = runtime.poisoned;
        runtime.unmount();
        const result = { class: fault?.class, message: fault?.message, faults: faults.length, rootListeners: runtime.listening.size, documentListeners: runtime.documentListeners.size, documentHandlers: runtime.documentKeys.size };
        return result;
      }, fixture);
      const pass = (rejected ? result.class === "contract" && needles.every((needle) => result.message.includes(needle)) && result.faults === 1 : result.class === undefined && result.faults === 0) && result.rootListeners === 0 && result.documentListeners === 0 && result.documentHandlers === 0;
      if (!pass) failures += 1;
      console.log(`${pass ? "ok  " : "FAIL"} ${fixture}: ${rejected ? "real Core contract diagnostic" : "raw attributes remain ordinary"} and listener cleanup${pass ? "" : ` ${JSON.stringify(result)}`}`);
    } finally { await context.close(); }
  }
} finally { await browser.close(); await new Promise((resolve) => server.close(resolve)); }
if (failures) process.exitCode = 1;
