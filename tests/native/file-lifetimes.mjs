// Specs remain the source of behavior; this contract varies their process-local
// order so teardown and worker answers cannot consume the next page's handles.
import { spawnSync } from "node:child_process";
import path from "node:path";

const args = process.argv.slice(2);
if (args.length !== 2 || args[0] !== "--runner") {
  throw new Error("usage: node tests/native/file-lifetimes.mjs --runner FILES_RUNNER");
}
const runner = path.resolve(args[1]);
const cases = [
  { name: "disposed page before saturation", specs: ["panel", "bound"] },
  { name: "worker answer before saturation", specs: ["count", "bound"] },
  { name: "two saturated pages", specs: ["bound", "bound"] },
  { name: "original unsorted reproduction", specs: ["count", "panel", "bound", "probe", "drop", "release", "decision", "choose"] },
  { name: "retirement within one page and across teardown", specs: ["reuse-retired", "bound", "reuse-retired"] },
];
let failures = 0;
for (const contract of cases) {
  const result = spawnSync(runner, contract.specs.map(name => `tests/apps/files/specs/${name}.scm`), {
    encoding: "utf8", timeout: 120000, maxBuffer: 4 * 1024 * 1024,
  });
  const records = (result.stdout ?? "").split("\n").filter(Boolean).map(line => JSON.parse(line));
  const passed = !result.error && result.status === 0 && records.length === contract.specs.length
    && records.every((record, index) => record.protocol === "roc-signals/spec-result/v2"
      && record.id === contract.specs[index] && record.status === "passed" && record.failure === null);
  if (!passed) failures++;
  console.log(`${passed ? "ok" : "FAIL"} ${contract.name}`);
  if (!passed) console.error(result.error ?? result.signal ?? `${result.stdout}${result.stderr}`);
}
console.log(`file-lifetimes: ${cases.length} contracts, ${failures} failed`);
process.exitCode = failures ? 1 : 0;
