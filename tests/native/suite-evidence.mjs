import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

assert.equal(process.argv[2], "--runner");
const runner = path.resolve(process.argv[3]);
const dir = fs.mkdtempSync(path.join(os.tmpdir(), "signals-suite-evidence-"));
const write = (name, steps) => {
  const file = path.join(dir, `${name}.scm`);
  fs.writeFileSync(file, `(test "${name}"\n (steps\n  ${steps}))`);
  return file;
};
const check = (files, status) => {
  const result = spawnSync(runner, ["--check-suite", ...files], { encoding: "utf8", timeout: 30000 });
  assert.ifError(result.error);
  assert.equal(result.status, status, result.stdout + result.stderr);
  assert.equal(result.stderr, "", "suite validation must not mount the debug app or run a reader");
  const rows = result.stdout.trim().split("\n").map(JSON.parse);
  assert.equal(rows.length, files.length);
  assert.deepEqual(rows.map(row => row.id), files.map(file => path.basename(file, ".scm")));
  assert.ok(rows.every(row => row.protocol === "roc-signals/spec-result/v2" && row.duration_ns === 0));
  return rows;
};
try {
  const absent = write("absent", '(expect-absent (role button :name "Delete") :never-drawn)');
  const present = write("present", '(expect-visible (role button :name "Delete"))');
  assert.ok(check([absent, present], 0).every(row => row.status === "passed"));
  assert.ok(check([present, absent], 0).every(row => row.status === "passed"));
  const typo = write("typo", '(expect-absent (role button :name "Delte") :never-drawn)');
  const bad = check([typo, present], 1)[0];
  assert.equal(bad.failure.phase, "suite");
  assert.equal(bad.failure.line, 3);
  assert.match(bad.failure.message, /Delte/);
  assert.equal(check([absent], 1)[0].status, "error");
  const invalid = write("invalid", '(unknown-step "Delete")');
  const parseError = check([invalid, present], 1)[0];
  assert.equal(parseError.status, "error");
  assert.equal(parseError.failure.phase, "parse");
  assert.equal(parseError.failure.kind, "parse");
  const mixed = check([invalid, typo, present], 1);
  assert.equal(mixed[0].failure.phase, "parse");
  assert.equal(mixed[1].failure.phase, "suite");
  assert.equal(mixed[2].status, "passed");
  for (const [name, negative, positive] of [
    ["attribute", '(expect-no-attr (test-id "a") title :never-written)', '(expect-has-attr (test-id "b") title)'],
    ["cleanup", '(expect-cleanup "cleanup" 0 :never-runs)', '(expect-cleanup "cleanup" 1)'],
    ["interval", '(expect-interval 500 0 :never-started)', '(expect-interval 500 1)'],
  ]) {
    const absentFile = write(`${name}-absent`, negative);
    const presentFile = write(`${name}-present`, positive);
    assert.equal(check([absentFile], 1)[0].failure.phase, "suite");
    assert.ok(check([absentFile, presentFile], 0).every(row => row.status === "passed"));
  }
  for (const options of [["--emit-steps"], ["--grammar"], ["--soak", "3"], ["--walk", "3"], ["--warm", "3"], ["--seed", "3"], ["--filter", "absent"], ["--filter", "*"]]) {
    const rejected = spawnSync(runner, ["--check-suite", ...options, present], { encoding: "utf8", timeout: 30000 });
    assert.ifError(rejected.error);
    assert.equal(rejected.status, 2, rejected.stdout + rejected.stderr);
    assert.equal(rejected.stdout, "");
  }
  console.log("suite evidence: every marker family, independent file order, omitted evidence, misspellings, parse errors and incompatible modes");
} finally {
  fs.rmSync(dir, { recursive: true, force: true });
}
