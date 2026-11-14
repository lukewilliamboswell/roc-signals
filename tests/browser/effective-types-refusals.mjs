// The actual controls runner and Chrome replay must refuse file/checked
// actions on an invalid raw input type, whose effective type is text.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { parseArgs } from "./args.mjs";

const opts = parseArgs(process.argv.slice(2), ["native"], ["native", "wasm", "runtime"]);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "roc-signals-effective-types-"));
const fixtures = ["check", "choose-files"].map((name) => path.join(root, `tests/fixtures/effective-types/${name}.scm`));
const expected = ["is not a checkbox or radio button", "is not a file input"];
const run = (program, args) => {
  const result = spawnSync(program, args, { cwd: root, encoding: "utf8" });
  assert.ifError(result.error);
  assert.equal(result.signal, null, result.stderr);
  return result;
};
const validate = (result) => {
  assert.equal(result.status, 1, result.stderr);
  const rows = result.stdout.trim().split("\n").map(JSON.parse);
  assert.equal(rows.length, fixtures.length, result.stdout);
  rows.forEach((row, i) => {
    assert.equal(row.protocol, "roc-signals/spec-result/v2");
    assert.equal(row.status, "failed", JSON.stringify(row));
    assert.equal(row.failure.phase, "step");
    assert.equal(row.failure.kind, "assertion");
    assert.equal(row.failure.step, 0);
    assert.ok(row.failure.message.endsWith(expected[i]), JSON.stringify(row));
    assert.ok(row.id.endsWith(`${path.basename(fixtures[i], ".scm")}`), row.id);
  });
};
try {
  validate(run(opts.native, fixtures));
  const emitted = run(opts.native, ["--emit-steps", ...fixtures]);
  assert.equal(emitted.status, 0, emitted.stderr);
  const steps = path.join(temporary, "steps.jsonl");
  fs.writeFileSync(steps, emitted.stdout);
  validate(run(process.execPath, [path.join(root, "tests/browser/replay.mjs"), "--wasm", opts.wasm, "--runtime", opts.runtime, "--steps", steps, "--chrome", opts.chrome, "--json-lines"]));
  console.log("effective text types: both native and Chrome refuse check and choose-files");
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}
