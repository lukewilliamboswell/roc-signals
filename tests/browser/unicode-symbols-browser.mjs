// Compare the native DOM oracle and the actual browser matcher over all scalars.
import assert from "node:assert/strict";
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";
const options = parseArgs(process.argv.slice(2), ["oracle"]);
if (!options.oracle) throw new Error("--oracle PATH to the native unicode-symbols output is required");
const bytes = fs.readFileSync(options.oracle);
assert.equal(bytes.length, 139264, "the native oracle must supply one bit per Unicode code point");
const files = runtimeFiles(options.runtime);
const server = http.createServer((request, response) => {
  const name = path.basename(new URL(request.url, "http://x").pathname);
  if (name === "oracle.bin") { response.writeHead(200); response.end(bytes); return; }
  if (name === "unicode-runtime.mjs") {
    response.writeHead(200, { "content-type": "text/javascript" });
    response.end(`${fs.readFileSync(files["runtime.mjs"], "utf8")}\nexport { symbolKey };`); return;
  }
  const file = files[name];
  response.writeHead(200, { "content-type": file ? "text/javascript" : "text/html" });
  response.end(file ? fs.readFileSync(file) : "<!doctype html>");
});
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
const browser = await launch({ executablePath: options.chrome });
try {
  const page = await browser.newPage();
  await page.goto(`http://127.0.0.1:${server.address().port}/`);
  const result = await page.evaluate(async () => {
    const { symbolKey } = await import("/unicode-runtime.mjs");
    const bytes = new Uint8Array(await (await fetch("/oracle.bin")).arrayBuffer());
    let scalars = 0, symbols = 0, mismatches = 0, surrogateBits = 0;
    const examples = [];
    for (let point = 0; point <= 0x10ffff; point += 1) {
      const native = (bytes[point >>> 3] & (1 << (point & 7))) !== 0;
      if (point >= 0xd800 && point <= 0xdfff) { if (native) surrogateBits++; continue; }
      const browser = symbolKey(String.fromCodePoint(point));
      scalars++; if (browser) symbols++;
      if (native !== browser) { mismatches++; if (examples.length < 20) examples.push({ point: point.toString(16), native, browser }); }
    }
    return { scalars, symbols, mismatches, surrogateBits, examples, userAgent: navigator.userAgent };
  });
  assert.equal(result.scalars, 1112064);
  assert.equal(result.surrogateBits, 0);
  assert.equal(result.mismatches, 0, `native/package versus Chrome Unicode disagreement: ${JSON.stringify(result)}`);
  console.log(JSON.stringify(result));
} finally { await browser.close(); await new Promise(resolve => server.close(resolve)); }
