// Evidence validation for actual roc-fuzz fixed checks. The published host runs
// the property and judges its observations; this helper checks its durable
// report, input artifacts and the build profile without evaluating Roc.
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";
import { isDeepStrictEqual } from "node:util";

const JSON_LIMIT = 32 * 1024 * 1024;
const INPUT_LIMIT = 1024 * 1024;
const U64_MAX = (1n << 64n) - 1n;
const STATS = ["allocs", "reallocs", "deallocs", "requested_bytes", "entry_live_allocs", "entry_live_bytes", "exit_live_allocs", "exit_live_bytes", "peak_live_bytes"];
function need(condition, message) { if (!condition) throw new Error(message); }
function integer(value, label) {
  need(typeof value === "bigint" || (typeof value === "number" && Number.isSafeInteger(value)), `${label}: expected an exact integer`);
  const result = BigInt(value);
  need(result >= 0n && result <= U64_MAX, `${label}: outside U64`);
  return result;
}
function parseJson(text) {
  return JSON.parse(text, (_key, value, context) => {
    if (typeof value !== "number" || Number.isSafeInteger(value)) return value;
    // Node 23's source context preserves host U64s beyond IEEE-754 precision.
    need(context && /^(0|[1-9][0-9]*)$/.test(context.source), "JSON number cannot be represented exactly");
    return BigInt(context.source);
  });
}
function readJson(file) {
  need(fs.statSync(file).size <= JSON_LIMIT, `${file}: report transport limit`);
  return parseJson(fs.readFileSync(file, "utf8"));
}
export async function hashFile(file) {
  const hash = crypto.createHash("sha256");
  for await (const chunk of fs.createReadStream(file)) hash.update(chunk);
  return hash.digest("hex");
}
function bytes(value) {
  if (typeof value === "string") {
    const result = Buffer.from(value, "utf8");
    need(result.toString("utf8") === value, "prepared input has invalid Unicode");
    need(result.length <= INPUT_LIMIT, "prepared input limit");
    return result;
  }
  need(Array.isArray(value) && value.length <= INPUT_LIMIT, "prepared input must be UTF-8 text or bytes");
  need(value.every(byte => typeof byte === "number" && Number.isInteger(byte) && byte >= 0 && byte <= 255), "invalid prepared byte");
  return Buffer.from(value);
}
function cleanTermination(value) {
  return value && value.exit_code === 0 && value.signal === null && value.timed_out === false;
}
function checkRegions(regions) {
  need(Array.isArray(regions) && regions.length > 0, "missing observation regions");
  const occurrences = new Map();
  for (const [index, region] of regions.entries()) {
    const id = integer(region.id, "region id"), parent = integer(region.parent_id, "region parent");
    need(id === BigInt(index + 1) && parent < id && region.complete === true, "invalid/incomplete region topology");
    need(typeof region.name === "string" && region.name.length > 0, "missing region name");
    let siblings = occurrences.get(parent);
    if (siblings === undefined) { siblings = new Map(); occurrences.set(parent, siblings); }
    const occurrence = (siblings.get(region.name) ?? 0) + 1;
    siblings.set(region.name, occurrence);
    need(integer(region.occurrence, "region occurrence") === BigInt(occurrence), "region occurrence mismatch");
    need(region.stats && isDeepStrictEqual(Object.keys(region.stats).sort(), [...STATS].sort()), "invalid allocation stats schema");
    const stats = Object.fromEntries(STATS.map(key => [key, integer(region.stats[key], key)]));
    need(stats.entry_live_allocs + stats.allocs === stats.exit_live_allocs + stats.deallocs, "allocation balance mismatch");
    need(stats.peak_live_bytes >= stats.entry_live_bytes && stats.peak_live_bytes >= stats.exit_live_bytes, "invalid allocation peak");
    if (index === 0) {
      need(parent === 0n && region.name === "$property" && occurrence === 1, "missing outer property region");
      need(stats.exit_live_allocs === 0n && stats.exit_live_bytes === 0n, "outer property leaked allocations or bytes");
    } else need(parent !== 0n, "multiple outer property regions");
  }
}
function checkTrace(trace, observations) {
  need(trace && trace.format === "roc-fuzz-trace/1" && trace.metric_version === "roc-fuzz-allocations/1", "missing/unsupported detailed trace");
  for (const flag of ["metric_valid", "trace_rules_valid", "trace_rules_passed", "capture_complete", "complete"]) need(trace[flag] === true, `trace ${flag} failed`);
  need(Array.isArray(trace.rules) && Array.isArray(trace.events), "missing detailed trace records");
  need(trace.gap === null && isDeepStrictEqual(trace.regions, observations), "trace gap or inconsistent observations");
}
function nativeHost() {
  if (process.platform === "darwin" && process.arch === "arm64") return "arm64mac";
  if (process.platform === "linux" && process.arch === "x64") return "x64musl";
  throw new Error("roc-fuzz 0.6.1 has no native platform for this host");
}

// Covered and plain profiles use exactly this validator. Expected names and
// bytes come from supervised preparation, never a second fixture registry.
export async function validateReport({ reportDir, target, profile, binary, exitCode, hostTarget = nativeHost() }) {
  need(exitCode === 0, `actual fixed check exited ${exitCode}`);
  const directory = fs.realpathSync(reportDir);
  const report = readJson(path.join(directory, "report.json"));
  need(report.format === "roc-fuzz-quality/1" && report.metric_version === "roc-fuzz-allocations/1", "unsupported quality report");
  need(report.target === target && report.host_target === hostTarget && report.profile === profile && report.command === "check", "report target/host/profile/command mismatch");
  need(report.outcome === "passed" && report.error_message === null && ["unbaselined", "matched"].includes(report.baseline_status), "quality check or baseline failed");
  const configuration = report.configuration;
  need(configuration?.invocation_deadline_ms === 1800000 && configuration.leak_detection === true, "fixed deadline/leak policy mismatch");
  need(configuration.campaign_deadline_ms === null && configuration.corpus === null && isDeepStrictEqual(configuration.exploration_options, []), "unexpected exploration configuration");
  const preparation = report.preparation;
  need(preparation?.status === "passed" && cleanTermination(preparation.termination) && preparation.finding_kind === null && preparation.error_message === null, "example preparation failed");
  need(report.exploration?.status === "not_requested" && ["attempted", "accepted", "rejected"].every(key => integer(report.exploration[key], key) === 0n) && report.exploration.termination === null && report.exploration.finding_kind === null, "unexpected exploration");
  const prepared = readJson(path.join(directory, "prepared-examples.json"));
  need(prepared.format === "roc-fuzz-examples/1" && Array.isArray(prepared.examples) && prepared.examples.length <= 4096, "invalid prepared inventory");
  need(Array.isArray(report.examples) && report.examples.length === prepared.examples.length, "fixed inventory count mismatch");
  const names = new Set(), inventory = [], semantics = [];
  for (const [index, declaration] of prepared.examples.entries()) {
    need(typeof declaration.name === "string" && declaration.name.length > 0 && !names.has(declaration.name), "missing/duplicate example name");
    need(typeof declaration.revision === "string" && declaration.revision.length > 0, "missing example revision");
    names.add(declaration.name);
    const input = bytes(declaration.bytes), inputHash = crypto.createHash("sha256").update(input).digest("hex");
    const example = report.examples[index];
    need(example.name === declaration.name && example.revision === declaration.revision && example.input_sha256 === inputHash, "fixed inventory identity/hash mismatch");
    need(example.outcome === "passed" && cleanTermination(example.termination) && example.finding_kind === null, `${declaration.name}: replay failed`);
    for (const flag of ["metric_valid", "trace_rules_passed", "capture_complete"]) need(example[flag] === true, `${declaration.name}: ${flag} failed`);
    need(typeof example.input_path === "string", "missing input artifact path");
    const inputFile = fs.realpathSync(example.input_path);
    need(path.dirname(inputFile) === directory && path.basename(inputFile) === `example-${index}.bin`, "input artifact escapes report or has wrong ordinal");
    need(fs.statSync(inputFile).size <= INPUT_LIMIT && fs.readFileSync(inputFile).equals(input), "saved input differs from prepared bytes");
    need(await hashFile(inputFile) === inputHash, "saved input SHA256 mismatch");
    checkRegions(example.observations);
    checkTrace(example.diagnostics, example.observations);
    const worker = readJson(path.join(directory, `example-${index}.json`));
    need(worker.format === "roc-fuzz-worker/1" && worker.metric_version === "roc-fuzz-allocations/1", "unsupported worker result");
    for (const flag of ["accepted", "metric_valid", "trace_rules_passed", "capture_complete"]) need(worker[flag] === true, `worker ${flag} failed`);
    need(isDeepStrictEqual(worker.observations, example.observations), "worker observations differ from quality report");
    if (worker.diagnostics !== null) need(isDeepStrictEqual(worker.diagnostics, example.diagnostics), "worker trace differs from quality report");
    const identity = { name: declaration.name, revision: declaration.revision, input_sha256: inputHash };
    inventory.push(identity);
    semantics.push({ identity, observations: example.observations, diagnostics: example.diagnostics });
  }
  return { passed: true, target, profile, host_target: hostTarget, fixed_examples: inventory.length, inventory, semantics, binary_sha256: await hashFile(binary), binary_bytes: fs.statSync(binary).size, report_sha256: await hashFile(path.join(directory, "report.json")), prepared_sha256: await hashFile(path.join(directory, "prepared-examples.json")) };
}

export function compareProfiles(covered, plain) {
  need(covered.passed === true && plain.passed === true && covered.target === plain.target && covered.host_target === plain.host_target, "both profile reports must independently pass");
  need(isDeepStrictEqual(covered.inventory, plain.inventory), "covered/plain fixed inventories differ");
  need(isDeepStrictEqual(covered.semantics, plain.semantics), "covered/plain observations or detailed traces differ");
  return { passed: true, target: plain.target, fixed_examples: plain.fixed_examples };
}

function argsOf(argv) {
  const known = new Set(["report-dir", "target", "profile", "binary", "check-exit", "build-exit", "build-log", "check-log", "compiler-version", "build-cwd", "build-batch-ns", "check-batch-ns"]), options = {};
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index].replace(/^--/, "");
    if (key === "build-command") {
      need(options.buildCommand === undefined && index + 1 < argv.length, "missing build command");
      options.buildCommand = argv.slice(index + 1); break;
    }
    need(argv[index].startsWith("--") && known.has(key) && options[key] === undefined && index + 1 < argv.length, `unknown/missing/duplicate argument ${argv[index]}`);
    options[key] = argv[index + 1];
  }
  for (const key of known) need(typeof options[key] === "string" && options[key].length > 0, `--${key} required`);
  need(options.buildCommand?.length > 0, "--build-command required");
  return options;
}
function stringify(value) { return JSON.stringify(value, (_key, item) => typeof item === "bigint" ? item.toString() : item, 2); }
async function main(argv) {
  let options;
  try {
    options = argsOf(argv);
    need(options.profile === "fixed-examples-plain", "the smoke facade requires the plain fixed profile");
    need(options["build-exit"] === "0", `compiler/linker exited ${options["build-exit"]}`);
    const binary = path.resolve(options.binary), cwd = path.resolve(options["build-cwd"]);
    const entry = options.buildCommand[4];
    const output = options.buildCommand[5];
    const expected = ["build", "--opt=speed", "--timings", entry, output];
    need(options.buildCommand.length === expected.length + 1 && isDeepStrictEqual(options.buildCommand.slice(1), expected), "unexpected smoke compiler flags");
    need(typeof output === "string" && output.startsWith("--output=") && path.resolve(cwd, output.slice(9)) === binary, "smoke output path mismatch");
    need(typeof entry === "string" && entry.endsWith(".roc") && !path.isAbsolute(entry) && path.resolve(cwd, entry).startsWith(cwd + path.sep), "missing relative target entry");
    const checkExit = Number(options["check-exit"]);
    need(Number.isInteger(checkExit), "invalid check exit status");
    const result = await validateReport({ reportDir: options["report-dir"], target: options.target, profile: options.profile, binary, exitCode: checkExit });
    const { semantics: _semantics, ...summary } = result;
    summary.build = { instrumentation: false, optimizer: "speed", command: options.buildCommand, cwd, compiler_version: options["compiler-version"], entry_sha256: await hashFile(path.join(cwd, entry)), log_sha256: await hashFile(options["build-log"]), check_log_sha256: await hashFile(options["check-log"]), build_batch_ns: integer(BigInt(options["build-batch-ns"]), "build batch duration").toString(), check_batch_ns: integer(BigInt(options["check-batch-ns"]), "check batch duration").toString() };
    // This records the known entry and command, not a discovered dependency
    // graph or executable cache. Final matched proofs supply frozen manifests.
    fs.writeFileSync(path.join(path.dirname(path.resolve(options["report-dir"])), "validation.json"), stringify(summary) + "\n");
    console.log(`${options.target}: ${result.fixed_examples} fixed examples passed (plain optimized)`);
  } catch (error) {
    const failure = { passed: false, error: String(error.message ?? error) };
    if (options?.["report-dir"]) fs.writeFileSync(path.join(path.dirname(path.resolve(options["report-dir"])), "validation.json"), stringify(failure) + "\n");
    console.error(`fixed report failed: ${failure.error}`); process.exitCode = 1;
  }
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) await main(process.argv.slice(2));
