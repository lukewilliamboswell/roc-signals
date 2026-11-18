// The same geometry/modifier stories on every native CI system. The SCM
// parser emits the browser's steps; this driver never interprets SCM itself.
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";

const options = Object.fromEntries(Array.from({ length: (process.argv.length - 2) / 2 }, (_, i) => [process.argv[2 + i * 2].replace(/^--/, ""), process.argv[3 + i * 2]]));
for (const key of ["roc", "target", "exe", "chrome", "build"]) assert.ok(Object.hasOwn(options, key), `--${key} is required`);
const run = (program, args) => {
  const result = spawnSync(program, args, { encoding: "utf8", timeout: 600000, maxBuffer: 32 * 1024 * 1024 });
  if (result.stderr) process.stderr.write(result.stderr);
  assert.ifError(result.error);
  assert.equal(result.signal, null);
  assert.equal(result.status, 0, `${program} ${args.join(" ")}\n${result.stdout}`);
  return result.stdout;
};
const records = (source, ids, protocol) => {
  const rows = source.trim().split("\n").map(JSON.parse);
  assert.equal(rows.length, ids.length, "every file needs exactly one result");
  assert.deepEqual(rows.map(row => row.id).sort(), [...ids].sort());
  for (const row of rows) {
    if (protocol === null) assert.ok(Array.isArray(row.steps), JSON.stringify(row));
    else {
      assert.equal(row.protocol, protocol);
      assert.equal(row.status, "passed", JSON.stringify(row));
    }
  }
};

for (const app of ["examples/log-explorer", "examples/kanban-board", "tests/apps/table", "www/samples/scores"]) {
  const dir = path.resolve(options.build, path.basename(app));
  fs.mkdirSync(dir, { recursive: true });
  const specs = fs.readdirSync(`${app}/specs`).filter(file => file.endsWith(".scm")).sort().map(file => `${app}/specs/${file}`);
  assert.ok(specs.length, `${app} has no specs`);
  const ids = specs.map(file => path.basename(file, ".scm"));
  const runner = path.join(dir, `runner${options.exe}`);
  const wasm = path.join(dir, "app.wasm");
  run(options.roc, ["build", "--opt=dev", `--target=${options.target}`, `${app}/main.roc`, `--output=${runner}`]);
  run(options.roc, ["build", "--opt=dev", "--target=wasm32", `${app}/main.roc`, `--output=${wasm}`]);
  for (const args of [["--check-suite", ...specs], specs]) records(run(runner, args), ids, "roc-signals/spec-result/v2");
  const steps = run(runner, ["--emit-steps", ...specs]);
  records(steps, ids, null);
  const stepsPath = path.join(dir, "steps.jsonl");
  fs.writeFileSync(stepsPath, steps);
  const browser = run(process.execPath, ["tests/browser/replay.mjs", "--wasm", wasm, "--runtime", "platform/runtime.mjs", "--steps", stepsPath, "--chrome", options.chrome, "--json-lines"]);
  records(browser, ids, "roc-signals/spec-result/v2");
  fs.writeFileSync(path.join(dir, "browser.jsonl"), browser);
  console.log(`${app}: ${specs.length} specs passed natively and in Chrome`);
}
