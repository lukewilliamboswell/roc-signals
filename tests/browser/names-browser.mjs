// node tests/browser/names-browser.mjs --chrome PATH [--corpus FILE]
// The shared corpus checks context-free HTML local-name and Fetch grammar.
// Namespace-specific qualification depends on construction context (#246).
import fs from "node:fs";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { launch } from "./cdp.mjs";

const { values: options } = parseArgs({ options: {
  chrome: { type: "string", default: process.env.CHROME ?? "chrome" },
  corpus: { type: "string", default: fileURLToPath(new URL("../../fuzz/names/corpus.tsv", import.meta.url)) },
  runtime: { type: "string" },
} });
// A leading U+FEFF is name data, not a file signature to discard.
const utf8 = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });
const cases = fs.readFileSync(options.corpus, "utf8").split("\n").filter((line) => line.length !== 0).map((line) => {
  const columns = line.split("\t");
  if (columns.length !== 3 || !/^[01]{3}$/.test(columns[1]) || !/^(?:[0-9a-f]{2})*$/.test(columns[2])) throw new Error("invalid name corpus row");
  const [name, flags, hex] = columns;
  return { name, text: utf8.decode(Buffer.from(hex, "hex")), expected: { tag: flags[0] === "1", attribute: flags[1] === "1", method: flags[2] === "1" } };
});
if (cases.length === 0 || new Set(cases.map((entry) => entry.name)).size !== cases.length) throw new Error("the name corpus must be nonempty with unique names");
const browser = await launch({ executablePath: options.chrome });
let failed = 0;
try {
  const context = await browser.createBrowserContext();
  const page = await context.newPage();
  await page.goto("data:text/html;charset=utf-8,<!doctype html><title>Name grammar</title>");
  const actual = await page.evaluate((inputs) => {
    const accepted = (run) => { try { run(); return true; } catch (_) { return false; } };
    return inputs.map(({ name, text }) => ({ name, result: {
      tag: accepted(() => document.createElement(text)),
      attribute: accepted(() => document.createElement("div").setAttribute(text, "value")),
      method: accepted(() => new Request("http://localhost/name-grammar", { method: text })),
    } }));
  }, cases);
  for (let index = 0; index < cases.length; index += 1) {
    const expected = cases[index];
    const result = actual[index];
    if (result.name !== expected.name || JSON.stringify(result.result) !== JSON.stringify(expected.expected)) {
      failed += 1;
      console.log(`FAIL ${expected.name}: got ${JSON.stringify(result.result)}, expected ${JSON.stringify(expected.expected)}`);
    }
  }
  const facts = await page.evaluate(() => {
    const target = new EventTarget();
    let heard = 0;
    target.addEventListener("", () => { heard += 1; });
    target.dispatchEvent(new Event(""));
    return { emptyEventHeard: heard, lowerGet: new Request("http://localhost/", { method: "get" }).method, lowerPatch: new Request("http://localhost/", { method: "patch" }).method };
  });
  if (JSON.stringify(facts) !== JSON.stringify({ emptyEventHeard: 1, lowerGet: "GET", lowerPatch: "patch" })) {
    failed += 1;
    console.log(`FAIL browser rule attribution: ${JSON.stringify(facts)}`);
  }
  await context.close();
  console.log(JSON.stringify({ corpus: options.corpus, cases: cases.length, failed, facts }));
} finally {
  await browser.close();
}
console.log(failed === 0 ? "== names browser contract: all pass" : `== names browser contract: ${failed} failures`);
process.exit(failed === 0 ? 0 : 1);
