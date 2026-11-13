// Transport/failure contracts only: these synthetic reports never count as
// actual roc-fuzz replays. Real profiles are compared separately after builds.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { validateReport, compareProfiles } from "./check-report.mjs";

const root = fs.mkdtempSync(path.join(os.tmpdir(), "signals-fuzz-report-"));
const helper = fileURLToPath(new URL("./check-report.mjs", import.meta.url));
const host = process.platform === "darwin" ? "arm64mac" : "x64musl";
let checks = 0, serial = 0;
const encode = value => JSON.stringify(value, (_key, item) => typeof item === "bigint" ? JSON.rawJSON(item.toString()) : item);
const write = (file, value) => fs.writeFileSync(file, encode(value));
function fixture({ profile = "fixed-examples-plain", empty = false, large = false } = {}) {
  const directory = path.join(root, String(serial++)); fs.mkdirSync(directory);
  const reportDir = path.join(directory, "report"); fs.mkdirSync(reportDir);
  const binary = path.join(directory, "target"); fs.writeFileSync(binary, "synthetic transport fixture, not compiled Roc");
  fs.writeFileSync(path.join(directory, "entry.roc"), "unit fixture, never compiled");
  fs.writeFileSync(path.join(directory, "build.log"), "synthetic compiler log");
  fs.writeFileSync(path.join(directory, "check.log"), "demo: passed (synthetic)");
  const prepared = { format: "roc-fuzz-examples/1", examples: empty ? [] : [{ name: "utf8", revision: "1", bytes: "λ" }, { name: "bytes", revision: "1", bytes: [0, 255] }] };
  const examples = prepared.examples.map((declaration, index) => {
    const input = typeof declaration.bytes === "string" ? Buffer.from(declaration.bytes) : Buffer.from(declaration.bytes);
    const inputFile = path.join(reportDir, `example-${index}.bin`); fs.writeFileSync(inputFile, input);
    const stats = { allocs: large ? 9007199254740993n : 1, reallocs: 0, deallocs: large ? 9007199254740993n : 1, requested_bytes: large ? 18446744073709551615n : 1, entry_live_allocs: 0, entry_live_bytes: 0, exit_live_allocs: 0, exit_live_bytes: 0, peak_live_bytes: 1 };
    const observations = [{ id: 1, parent_id: 0, name: "$property", occurrence: 1, complete: true, stats }];
    const diagnostics = { format: "roc-fuzz-trace/1", metric_version: "roc-fuzz-allocations/1", metric_valid: true, trace_rules_valid: true, trace_rules_passed: true, capture_complete: true, complete: true, regions: observations, rules: [], events: [{ kind: "begin", sequence: 1 }, { kind: "end", sequence: 2 }], gap: null };
    const worker = { format: "roc-fuzz-worker/1", metric_version: "roc-fuzz-allocations/1", accepted: true, metric_valid: true, trace_rules_passed: true, capture_complete: true, observations, diagnostics };
    write(path.join(reportDir, `example-${index}.json`), worker);
    return { name: declaration.name, revision: declaration.revision, input_sha256: crypto.createHash("sha256").update(input).digest("hex"), input_path: inputFile, outcome: "passed", termination: { exit_code: 0, signal: null, timed_out: false }, finding_kind: null, metric_valid: true, trace_rules_passed: true, capture_complete: true, observations, diagnostics };
  });
  const report = { format: "roc-fuzz-quality/1", metric_version: "roc-fuzz-allocations/1", target: "demo", host_target: host, profile, command: "check", outcome: "passed", baseline_status: "unbaselined", error_message: null, examples, preparation: { status: "passed", termination: { exit_code: 0, signal: null, timed_out: false }, finding_kind: null, error_message: null }, exploration: { status: "not_requested", attempted: 0, accepted: 0, rejected: 0, termination: null, finding_kind: null }, configuration: { invocation_deadline_ms: 1800000, campaign_deadline_ms: null, leak_detection: true, detailed_capture: true, corpus: null, exploration_options: [] } };
  write(path.join(reportDir, "report.json"), report); write(path.join(reportDir, "prepared-examples.json"), prepared);
  return { directory, reportDir, binary, report, prepared, options: { reportDir, target: "demo", profile, binary, exitCode: 0, hostTarget: host } };
}
async function refused(label, mutate) {
  const test = fixture(); mutate(test);
  write(path.join(test.reportDir, "report.json"), test.report); write(path.join(test.reportDir, "prepared-examples.json"), test.prepared);
  await assert.rejects(() => validateReport(test.options), undefined, label); checks++;
}
function cli(test, overrides = {}) {
  const options = { ...test.options, ...overrides };
  return spawnSync(process.execPath, [helper,
    "--report-dir", options.reportDir, "--target", options.target, "--profile", options.profile,
    "--binary", options.binary, "--check-exit", String(options.exitCode), "--build-exit", String(overrides.buildExit ?? 0),
    "--build-log", path.join(test.directory, "build.log"), "--check-log", path.join(test.directory, "check.log"),
    "--compiler-version", "unit-test", "--build-cwd", test.directory, "--build-batch-ns", "42", "--check-batch-ns", "7",
    "--build-command", "roc", "build", ...(overrides.covered ? ["--fuzz"] : []), "--opt=speed", "--timings", "entry.roc", `--output=${test.binary}`,
  ], { encoding: "utf8" });
}
try {
  const plain = await validateReport(fixture().options), covered = await validateReport(fixture({ profile: "default" }).options);
  assert.equal(compareProfiles(covered, plain).fixed_examples, 2); checks++;
  const empty = await validateReport(fixture({ empty: true }).options); assert.equal(empty.fixed_examples, 0); checks++;
  const large = await validateReport(fixture({ large: true }).options);
  assert.equal(large.semantics[0].observations[0].stats.allocs, 9007199254740993n);
  assert.equal(large.semantics[0].observations[0].stats.requested_bytes, 18446744073709551615n); checks++;
  for (const [label, mutate] of [
    ["bad process exit despite passed report", t => { t.options.exitCode = 1; }],
    ["wrong target", t => { t.report.target = "other"; }],
    ["wrong profile", t => { t.report.profile = "default"; }],
    ["wrong host", t => { t.report.host_target = "other"; }],
    ["wrong schema", t => { t.report.format = "future"; }],
    ["baseline changed", t => { t.report.baseline_status = "changed"; }],
    ["preparation failure", t => { t.report.preparation.status = "failed"; }],
    ["preparation signal", t => { t.report.preparation.termination.signal = 9; }],
    ["preparation timeout", t => { t.report.preparation.termination.timed_out = true; }],
    ["wrong deadline", t => { t.report.configuration.invocation_deadline_ms = 10000; }],
    ["leaks disabled", t => { t.report.configuration.leak_detection = false; }],
    ["exploration requested", t => { t.report.exploration.status = "passed"; }],
    ["missing case", t => { t.report.examples.pop(); }],
    ["extra case", t => { t.report.examples.push(t.report.examples[0]); }],
    ["reordered cases", t => { t.report.examples.reverse(); }],
    ["duplicate declaration", t => { t.prepared.examples[1].name = "utf8"; }],
    ["wrong revision", t => { t.report.examples[0].revision = "2"; }],
    ["wrong input hash", t => { t.report.examples[0].input_sha256 = "0".repeat(64); }],
    ["wrong artifact bytes", t => { fs.writeFileSync(t.report.examples[0].input_path, "wrong"); }],
    ["missing artifact", t => { fs.unlinkSync(t.report.examples[0].input_path); }],
    ["artifact outside report", t => { const file = path.join(t.directory, "outside.bin"); fs.copyFileSync(t.report.examples[0].input_path, file); t.report.examples[0].input_path = file; }],
    ["symlink artifact escape", t => { const file = path.join(t.directory, "outside.bin"); fs.copyFileSync(t.report.examples[0].input_path, file); fs.unlinkSync(t.report.examples[0].input_path); fs.symlinkSync(file, t.report.examples[0].input_path); }],
    ["rejected input", t => { t.report.examples[0].outcome = "rejected"; }],
    ["worker signal", t => { t.report.examples[0].termination.signal = 11; }],
    ["invalid metrics", t => { t.report.examples[0].metric_valid = false; }],
    ["trace failure", t => { t.report.examples[0].trace_rules_passed = false; }],
    ["incomplete capture", t => { t.report.examples[0].capture_complete = false; }],
    ["trace gap", t => { t.report.examples[0].diagnostics.gap = { lost: 1 }; }],
    ["missing detailed events", t => { delete t.report.examples[0].diagnostics.events; }],
    ["outer leak", t => { t.report.examples[0].observations[0].stats.exit_live_bytes = 1; }],
    ["allocation imbalance", t => { t.report.examples[0].observations[0].stats.deallocs = 0; }],
    ["U64 overflow", t => { t.report.examples[0].observations[0].stats.requested_bytes = 18446744073709551616n; }],
    ["fractional metric", t => { t.report.examples[0].observations[0].stats.requested_bytes = 1.5; }],
    ["unfinished region", t => { t.report.examples[0].observations[0].complete = false; }],
    ["missing worker", t => { fs.unlinkSync(path.join(t.reportDir, "example-0.json")); }],
  ]) await refused(label, mutate);
  for (const kind of ["malformed", "missing", "oversized"]) {
    const test = fixture(), file = path.join(test.reportDir, "report.json");
    if (kind === "malformed") fs.writeFileSync(file, "{");
    else if (kind === "missing") fs.unlinkSync(file);
    else fs.truncateSync(file, 32 * 1024 * 1024 + 1);
    await assert.rejects(() => validateReport(test.options), undefined, kind); checks++;
  }
  const different = structuredClone(plain); different.inventory[0].revision = "2";
  assert.throws(() => compareProfiles(covered, different)); checks++;
  const differentWork = structuredClone(plain); differentWork.semantics[0].observations[0].stats.requested_bytes = 2;
  assert.throws(() => compareProfiles(covered, differentWork)); checks++;
  // The executable facade must propagate failures even when a target file and
  // a plausible passed report exist, and retain the original evidence.
  for (const [overrides, expected] of [[{}, 0], [{ exitCode: 1 }, 1], [{ buildExit: 1 }, 1], [{ covered: true }, 1]]) {
    const test = fixture(), before = fs.readFileSync(path.join(test.reportDir, "report.json"));
    const result = cli(test, overrides); assert.equal(result.status, expected, result.stderr);
    assert.equal(JSON.parse(fs.readFileSync(path.join(test.directory, "validation.json"))).passed, expected === 0);
    assert.ok(fs.readFileSync(path.join(test.reportDir, "report.json")).equals(before)); checks++;
  }
  console.log(`Fixed-report transport contracts: ${checks} checks passed (no Roc compiler or property replay)`);
} finally { fs.rmSync(root, { recursive: true, force: true }); }
