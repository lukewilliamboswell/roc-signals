#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import { basename } from "node:path";

import { publicExampleTaskHandler } from "../../www/static/example_tasks.mjs";
import { serviceOpsBehaviors } from "../../www/static/service_ops_charts.mjs";
import { SignalsRuntime } from "../../www/static/signals.mjs";
import { findByText, fireEvent, installDomDouble } from "./dom_double.mjs";

const args = process.argv.slice(2);
const wasmPath = args.shift();
let expectError = "";
let printTelemetrySummary = false;
let exerciseServiceOpsRefresh = false;
let exerciseTeamCheckoutPlans = false;
let rawName;

while (args.length > 0) {
  const arg = args.shift();
  if (arg === "--expect-error") {
    expectError = args.shift() ?? "";
  } else if (arg === "--telemetry-summary") {
    printTelemetrySummary = true;
  } else if (arg === "--exercise-service-ops-refresh") {
    exerciseServiceOpsRefresh = true;
  } else if (arg === "--exercise-team-checkout-plans") {
    exerciseTeamCheckoutPlans = true;
  } else if (arg.startsWith("--")) {
    console.error(`unknown argument: ${arg}`);
    process.exit(2);
  } else if (rawName === undefined) {
    rawName = arg;
  } else {
    console.error(`unexpected extra argument: ${arg}`);
    process.exit(2);
  }
}

if (!wasmPath) {
  console.error(
    "usage: mount_wasm_example.mjs <wasm-path> [name] [--expect-error <substring>] [--telemetry-summary] [--exercise-service-ops-refresh] [--exercise-team-checkout-plans]",
  );
  process.exit(2);
}

const name = rawName ?? basename(wasmPath);
const settleMs = 50;

function hostError(exports) {
  const ptr = exports.roc_ui_last_error_ptr?.() ?? 0;
  const len = exports.roc_ui_last_error_len?.() ?? 0;
  if (ptr === 0 || len === 0) {
    return "";
  }
  return new TextDecoder().decode(new Uint8Array(exports.memory.buffer, ptr, len));
}

function fail(message) {
  console.error(message);
  process.exit(1);
}

const bytes = await readFile(wasmPath);
const { instance } = await WebAssembly.instantiate(bytes, {});
const root = installDomDouble();
const errors = [];
const missingBehaviors = [];
const behaviorCounts = { attached: 0, cleaned: 0 };
const telemetryEntries = [];
const runtime = new SignalsRuntime(instance.exports, root, {
  taskHandler: publicExampleTaskHandler,
  behaviors: instrumentBehaviors(serviceOpsBehaviors, behaviorCounts),
  telemetry: (entry) => {
    telemetryEntries.push(entry);
    if (entry.kind === "behavior_missing") {
      missingBehaviors.push(entry);
    }
  },
  onError: (err) => errors.push(err),
});

try {
  runtime.mount();
} catch (err) {
  const detail = hostError(instance.exports);
  const suffix = detail === "" ? "" : `\nHost error: ${detail}`;
  const message = `${err?.stack ?? err}${suffix}`;
  if (expectError !== "" && message.includes(expectError)) {
    console.log(`mount failed as expected for ${name}`);
    process.exit(0);
  }
  fail(`failed to mount ${name}: ${err?.stack ?? err}${suffix}`);
}

if (expectError !== "") {
  fail(`mounted ${name}, but expected mount error containing: ${expectError}`);
}

await new Promise((resolve) => setTimeout(resolve, settleMs));

if (errors.length !== 0) {
  const details = errors.map((err) => err?.stack ?? err).join("\n");
  fail(`runtime reported errors while mounting ${name}:\n${details}`);
}

if (missingBehaviors.length !== 0) {
  const details = missingBehaviors
    .map((entry) => `${entry.behavior} on ${entry.elem?.tag ?? "unknown element"}`)
    .join("\n");
  fail(`mounted ${name}, but the runtime reported missing behaviors:\n${details}`);
}

if (root.textContent.trim() === "") {
  fail(`mounted ${name}, but no DOM text was rendered`);
}

if (exerciseServiceOpsRefresh) {
  await exerciseRefreshWorkflow(name, root, errors);
}

if (exerciseTeamCheckoutPlans) {
  await exerciseTeamCheckoutPlanWorkflow(name, root, errors);
}

try {
  runtime.unmount();
} catch (err) {
  const detail = hostError(instance.exports);
  const suffix = detail === "" ? "" : `\nHost error: ${detail}`;
  fail(`failed to unmount ${name}: ${err?.stack ?? err}${suffix}`);
}

const liveHostValues = runtime.liveHostValues();
if (liveHostValues !== 0) {
  fail(`mounted ${name}, but ${liveHostValues} host values are still live after unmount`);
}

if (behaviorCounts.attached !== behaviorCounts.cleaned) {
  fail(
    `mounted ${name}, but behavior cleanup count did not match attach count: ${behaviorCounts.attached} attached, ${behaviorCounts.cleaned} cleaned`,
  );
}

if (printTelemetrySummary) {
  console.log(JSON.stringify(commandTelemetrySummary(name, telemetryEntries)));
} else {
  console.log(`mounted ${name}`);
}

function commandTelemetrySummary(name, entries) {
  const summary = {
    name,
    commandBatches: 0,
    commands: 0,
    fixedRecordBytes: 0,
    fixedStringBytes: 0,
    dynamicBytes: 0,
    opCounts: {},
    decode: {
      fixedStringDecodes: 0,
      fixedStringBytes: 0,
      dynamicRecordsDecoded: 0,
      dynamicRecordBytes: 0,
      dynamicStringDecodes: 0,
      dynamicStringBytes: 0,
      dynamicByteArrayDecodes: 0,
      dynamicByteArrayBytes: 0,
    },
  };

  for (const entry of entries) {
    if (entry.kind === "commands") {
      summary.commandBatches += 1;
      summary.commands += entry.count ?? 0;
      summary.fixedRecordBytes += entry.fixedRecordBytes ?? 0;
      summary.fixedStringBytes += entry.fixedStringBytes ?? 0;
      summary.dynamicBytes += entry.dynamicBytes ?? 0;
      for (const [op, count] of Object.entries(entry.opCounts ?? {})) {
        summary.opCounts[op] = (summary.opCounts[op] ?? 0) + count;
      }
    } else if (entry.kind === "commands_applied") {
      for (const [field, value] of Object.entries(entry.decode ?? {})) {
        summary.decode[field] = (summary.decode[field] ?? 0) + value;
      }
    }
  }

  return summary;
}

async function exerciseRefreshWorkflow(name, root, errors) {
  const button = findByText(root, "button", "Refresh now");
  if (!button) {
    fail(`mounted ${name}, but the Refresh now button was not rendered`);
  }

  fireEvent(button, "click", { bubbles: true });
  await new Promise((resolve) => setTimeout(resolve, settleMs));

  if (errors.length !== 0) {
    const details = errors.map((err) => err?.stack ?? err).join("\n");
    fail(`runtime reported errors while exercising ${name} refresh:\n${details}`);
  }

  if (!root.textContent.includes("Manual refreshes: 1")) {
    fail(`exercised ${name} refresh, but the manual refresh counter did not update`);
  }
}

async function exerciseTeamCheckoutPlanWorkflow(name, root, errors) {
  const basicButton = findByText(root, "button", "Use basic plan");
  const teamButton = findByText(root, "button", "Use team plan");
  if (!basicButton || !teamButton) {
    fail(`mounted ${name}, but the team checkout plan buttons were not rendered`);
  }

  if (!root.textContent.includes("Priority support") || !root.textContent.includes("Audit log export")) {
    fail(`mounted ${name}, but the team plan rows were not initially rendered`);
  }
  if (teamButton.getAttribute("aria-pressed") !== "true" || basicButton.getAttribute("aria-pressed") !== "false") {
    fail(`mounted ${name}, but the team plan button state was not initially selected`);
  }

  fireEvent(basicButton, "click", { bubbles: true });
  await new Promise((resolve) => setTimeout(resolve, settleMs));
  failOnRuntimeErrors(name, errors, "switching to the basic plan");

  if (!root.textContent.includes("3 seats")) {
    fail(`switched ${name} to the basic plan, but the base row was removed`);
  }
  if (root.textContent.includes("Priority support") || root.textContent.includes("Audit log export")) {
    fail(`switched ${name} to the basic plan, but team-only rows remained`);
  }
  if (teamButton.getAttribute("aria-pressed") !== "false" || basicButton.getAttribute("aria-pressed") !== "true") {
    fail(`switched ${name} to the basic plan, but button state did not update`);
  }

  fireEvent(teamButton, "click", { bubbles: true });
  await new Promise((resolve) => setTimeout(resolve, settleMs));
  failOnRuntimeErrors(name, errors, "switching back to the team plan");

  if (!root.textContent.includes("Priority support") || !root.textContent.includes("Audit log export")) {
    fail(`switched ${name} back to the team plan, but team rows were not restored`);
  }
  if (teamButton.getAttribute("aria-pressed") !== "true" || basicButton.getAttribute("aria-pressed") !== "false") {
    fail(`switched ${name} back to the team plan, but button state did not update`);
  }
}

function failOnRuntimeErrors(name, errors, action) {
  if (errors.length === 0) {
    return;
  }
  const details = errors.map((err) => err?.stack ?? err).join("\n");
  fail(`runtime reported errors while ${action} in ${name}:\n${details}`);
}

function instrumentBehaviors(behaviors, counts) {
  return Object.fromEntries(
    Object.entries(behaviors).map(([name, behavior]) => [
      name,
      {
        ...behavior,
        attach(el, ctx) {
          counts.attached += 1;
          const cleanup = behavior.attach?.(el, ctx);
          return () => {
            counts.cleaned += 1;
            if (typeof cleanup === "function") {
              cleanup();
            }
          };
        },
      },
    ]),
  );
}
