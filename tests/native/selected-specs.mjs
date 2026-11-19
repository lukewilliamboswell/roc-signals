// Geometry/modifiers, startup opportunities and prepared-description lifetimes
// run as the same stories on every native CI system. The SCM
// parser emits the browser's steps; this driver never interprets SCM itself.
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import os from "node:os";
import { launch } from "../browser/cdp.mjs";
import { effectiveProfile, profileNotice } from "../compiler-profile.mjs";

const options = Object.fromEntries(Array.from({ length: (process.argv.length - 2) / 2 }, (_, i) => [process.argv[2 + i * 2].replace(/^--/, ""), process.argv[3 + i * 2]]));
for (const key of ["roc", "target", "exe", "chrome", "build"]) assert.ok(Object.hasOwn(options, key), `--${key} is required`);
const logs = path.resolve(options.build, "commands");
fs.mkdirSync(logs, { recursive: true });
fs.writeFileSync(path.join(logs, "system.json"), JSON.stringify({ platform: process.platform, arch: process.arch, release: os.release(), node: process.version, cpus: os.cpus().length, memory: os.totalmem() }, null, 2));
let command = 0;
const run = (program, args) => {
  const file = path.join(logs, String(++command).padStart(3, "0"));
  const started = Date.now();
  const description = { program, args, timeoutMs: 600000 };
  fs.writeFileSync(`${file}.json`, JSON.stringify(description, null, 2));
  console.log(`RUN ${program} ${args.join(" ")}`);
  const result = spawnSync(program, args, { encoding: "utf8", timeout: 600000, maxBuffer: 32 * 1024 * 1024 });
  // Preserve partial output and the exact invocation even when the compiler,
  // browser or outer command bound fails. Each stream is already bounded by
  // maxBuffer; observing it does not change the replay or retry a failed step.
  fs.writeFileSync(`${file}.stdout`, result.stdout ?? "");
  fs.writeFileSync(`${file}.stderr`, result.stderr ?? "");
  fs.writeFileSync(`${file}.json`, JSON.stringify({ ...description, elapsedMs: Date.now() - started, status: result.status, signal: result.signal, error: result.error?.message ?? null }, null, 2));
  if (result.stderr) process.stderr.write(result.stderr);
  assert.ifError(result.error);
  assert.equal(result.signal, null);
  assert.equal(result.status, 0, `${program} ${args.join(" ")}\n${result.stdout}`);
  return result.stdout;
};
const compiler = run(options.roc, ["version"]).trim().split(/\s+/).at(-1);
const profile = { compiler, target: "wasm32", requested: "dev" };
const effective = effectiveProfile(profile);
if (profileNotice(profile)) console.log(profileNotice(profile));
fs.writeFileSync(path.join(logs, "compiler-profile.json"), JSON.stringify({ ...profile, effective }, null, 2));
const versionBrowser = await launch({ executablePath: options.chrome });
try {
  fs.writeFileSync(path.join(logs, "browser-version.json"), JSON.stringify(await versionBrowser.version(), null, 2));
} finally {
  await versionBrowser.close();
}
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

for (const app of ["examples/log-explorer", "examples/kanban-board", "tests/apps/table", "www/samples/scores", "tests/apps/startup", "tests/apps/description-preparation"]) {
  const dir = path.resolve(options.build, path.basename(app));
  fs.mkdirSync(dir, { recursive: true });
  const specs = fs.readdirSync(`${app}/specs`).filter(file => file.endsWith(".scm")).sort().map(file => `${app}/specs/${file}`);
  assert.ok(specs.length, `${app} has no specs`);
  const ids = specs.map(file => path.basename(file, ".scm"));
  const runner = path.join(dir, `runner${options.exe}`);
  const wasm = path.join(dir, "app.wasm");
  run(options.roc, ["build", "--opt=dev", `--target=${options.target}`, `${app}/main.roc`, `--output=${runner}`]);
  run(options.roc, ["build", `--opt=${effective}`, "--target=wasm32", `${app}/main.roc`, `--output=${wasm}`]);
  for (const args of [["--check-suite", ...specs], specs]) records(run(runner, args), ids, "roc-signals/spec-result/v2");
  const steps = run(runner, ["--emit-steps", ...specs]);
  records(steps, ids, null);
  const stepsPath = path.join(dir, "steps.jsonl");
  fs.writeFileSync(stepsPath, steps);
  const publicArgs = fs.existsSync(path.join(app, "public")) ? ["--public", path.join(app, "public")] : [];
  const browser = run(process.execPath, ["tests/browser/replay.mjs", "--wasm", wasm, "--runtime", "platform/runtime.mjs", "--steps", stepsPath, "--chrome", options.chrome, "--json-lines", ...publicArgs]);
  records(browser, ids, "roc-signals/spec-result/v2");
  fs.writeFileSync(path.join(dir, "browser.jsonl"), browser);
  console.log(`${app}: ${specs.length} specs passed natively and in Chrome (--opt=${effective})`);
}
