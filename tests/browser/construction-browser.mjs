// Real app dispatch must refuse the same bounded constructor rules as the
// native event fixtures, before publishing the failing turn's command batch.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";

const options = parseArgs(process.argv.slice(2));
const files = runtimeFiles(options.runtime);
const cases = [
  { mode: "branch", rule: "the HTML parser would close the paragraph first", site: "/0/0" },
  { mode: "row", rule: "the HTML parser would close the paragraph first", site: "/0/0/0/0" },
  { mode: "state", rule: "the HTML parser would close the paragraph first", site: "/0/0/0" },
  { mode: "text", rule: "the HTML parser would move the text outside the table", site: "/0" },
  { mode: "row-text", rule: "the HTML parser would move the text outside the table", site: "/0/0" },
];
const server = http.createServer((request, response) => {
  const name = path.basename(new URL(request.url, "http://x").pathname);
  if (name === "app.wasm") {
    response.writeHead(200, { "content-type": "application/wasm" });
    response.end(fs.readFileSync(options.wasm));
  } else if (files[name]) {
    response.writeHead(200, { "content-type": "text/javascript" });
    response.end(fs.readFileSync(files[name]));
  } else if (cases.some(({ mode }) => mode === name)) {
    response.writeHead(200, { "content-type": "text/html" });
    response.end("<!doctype html><div id=app></div>");
  } else { response.writeHead(404); response.end(); }
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const browser = await launch({ executablePath: options.chrome });
let failures = 0;
try {
  for (const test of cases) {
    const context = await browser.createBrowserContext();
    try {
      const page = await context.newPage();
      await page.goto(`http://127.0.0.1:${server.address().port}/${test.mode}`);
      const result = await page.evaluate(async () => {
        const { mountRocEngineApp } = await import("/runtime.mjs");
        const root = document.getElementById("app");
        const faults = [];
        const runtime = await mountRocEngineApp({ wasmUrl: "/app.wasm", root, onFault: (fault) => faults.push(fault) });
        const initial = { healthy: !runtime.poisoned, button: root.querySelector("button")?.textContent, faults: faults.length };
        const before = root.innerHTML;
        root.querySelector("button").click();
        const fault = runtime.poisoned;
        const unchanged = root.innerHTML === before;
        runtime.unmount();
        return { initial, class: fault?.class, message: fault?.message, faults: faults.length, unchanged, listeners: runtime.listening.size, documents: runtime.documentListeners.size };
      });
      const pass = result.initial.healthy && result.initial.button === "Trigger construction" && result.initial.faults === 0 &&
        result.class === "contract" && result.message.includes(test.rule) && result.message.includes(`at site ${test.site}`) &&
        result.faults === 1 && result.unchanged && result.listeners === 0 && result.documents === 0;
      if (!pass) failures += 1;
      console.log(`${pass ? "ok  " : "FAIL"} construction ${test.mode}: actual dispatch refuses ${test.rule} at ${test.site}${pass ? "" : ` ${JSON.stringify(result)}`}`);
    } finally { await context.close(); }
  }
} finally { await browser.close(); await new Promise((resolve) => server.close(resolve)); }
process.exitCode = failures ? 1 : 0;
