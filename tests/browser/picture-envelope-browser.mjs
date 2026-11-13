// Run the same independent binary envelope contracts in actual Chrome. No app
// Wasm or producer is involved; metadata decoding must not access the DOM.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";
const options = parseArgs(process.argv.slice(2), [], ["runtime"]);
const files = { ...runtimeFiles(options.runtime), "picture-envelope-vectors.json": fileURLToPath(new URL("../picture-envelope-vectors.json", import.meta.url)), "picture-envelope-cases.mjs": fileURLToPath(new URL("./picture-envelope-cases.mjs", import.meta.url)) };
const server = http.createServer((request, response) => {
  const file = files[path.basename(new URL(request.url, "http://x").pathname)];
  response.writeHead(200, { "content-type": file ? "text/javascript" : "text/html" });
  response.end(file ? fs.readFileSync(file) : "<!doctype html>");
});
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
const browser = await launch({ executablePath: options.chrome });
try {
  const page = await browser.newPage();
  await page.goto(`http://127.0.0.1:${server.address().port}/`);
  const checks = await page.evaluate(async () => {
    const { decodePictureEnvelope } = await import("/runtime.mjs");
    const { pictureEnvelopeCases, pictureEnvelopeVectors } = await import("/picture-envelope-cases.mjs");
    const vectors = await (await fetch("/picture-envelope-vectors.json")).json();
    const methods = ["createElement", "createElementNS", "createTextNode", "createComment", "createDocumentFragment", "querySelector", "querySelectorAll"];
    const originals = methods.map(name => document[name]);
    for (const name of methods) document[name] = () => { throw new Error(`decoder called document.${name}`); };
    try { return [...pictureEnvelopeCases(decodePictureEnvelope), ...pictureEnvelopeVectors(decodePictureEnvelope, vectors), ["binary decoding invokes no DOM factory or selector", true]]; }
    finally { methods.forEach((name, i) => { document[name] = originals[i]; }); }
  });
  for (const [name, ok] of checks) console.log(`${ok ? "ok  " : "FAIL"} ${name}`);
  if (checks.some(([, ok]) => !ok)) process.exitCode = 1;
} finally { await browser.close(); await new Promise(resolve => server.close(resolve)); }
