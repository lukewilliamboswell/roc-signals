#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import { basename } from "node:path";

import { publicExampleTaskHandler } from "../../www/static/example_tasks.mjs";
import { serviceOpsBehaviors } from "../../www/static/service_ops_charts.mjs";
import { SignalsRuntime, instantiateSignalsBytes } from "../../www/static/signals.mjs";
import { findByText, fireEvent, installDomDouble } from "./dom_double.mjs";

const args = process.argv.slice(2);
const wasmPath = args.shift();
let expectError = "";
let printTelemetrySummary = false;
let exerciseServiceOpsRefresh = false;
let exerciseTeamCheckoutPlans = false;
let exerciseLocationSource = false;
let exerciseLocationNavigation = false;
let exerciseLocationCanonicalBranch = false;
let exerciseStorageCommands = false;
let exerciseLiveSearchOnline = false;
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
  } else if (arg === "--exercise-location-source") {
    exerciseLocationSource = true;
  } else if (arg === "--exercise-location-navigation") {
    exerciseLocationNavigation = true;
  } else if (arg === "--exercise-location-canonical-branch") {
    exerciseLocationCanonicalBranch = true;
  } else if (arg === "--exercise-storage-commands") {
    exerciseStorageCommands = true;
  } else if (arg === "--exercise-live-search-online") {
    exerciseLiveSearchOnline = true;
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
    "usage: mount_wasm_example.mjs <wasm-path> [name] [--expect-error <substring>] [--telemetry-summary] [--exercise-service-ops-refresh] [--exercise-team-checkout-plans] [--exercise-location-source] [--exercise-location-navigation] [--exercise-location-canonical-branch] [--exercise-storage-commands] [--exercise-live-search-online]",
  );
  process.exit(2);
}

const name = rawName ?? basename(wasmPath);
const settleMs = 50;
const teamCheckoutStorageSeed = {
  "team-checkout:step": "1",
  "team-checkout:email": "saved@example.com",
  "team-checkout:address": "Saved Signal Lane",
  "team-checkout:terms": "false",
  "team-checkout:plan": "team",
  "team-checkout:qty:3-seats": "1",
  "team-checkout:qty:priority-support": "3",
  "team-checkout:qty:audit-log-export": "4",
};
const teamCheckoutStorageKeys = Object.keys(teamCheckoutStorageSeed);

function createStorageDouble(initial = {}) {
  const values = new Map(Object.entries(initial));
  return {
    getItem(key) {
      const normalized = String(key);
      return values.has(normalized) ? values.get(normalized) : null;
    },
    setItem(key, value) {
      values.set(String(key), String(value));
    },
    removeItem(key) {
      values.delete(String(key));
    },
    dump() {
      return Object.fromEntries(values.entries());
    },
  };
}

function initialLocalStorage() {
  const initial = {};
  if (exerciseStorageCommands) {
    initial["checkout:draft"] = "seeded local";
  }
  if (exerciseTeamCheckoutPlans) {
    Object.assign(initial, teamCheckoutStorageSeed);
  }
  return initial;
}

function initialSessionStorage() {
  if (exerciseStorageCommands) {
    return { "checkout:flash": "seeded flash" };
  }
  return {};
}

function initialBrowserHref() {
  if (exerciseLocationCanonicalBranch) {
    return "http://signals.local/services/workers";
  }
  if (exerciseLocationSource) {
    return "http://signals.local/services/api?tab=logs#tail";
  }
  return "http://signals.local/";
}

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
const localStorageDouble = createStorageDouble(initialLocalStorage());
const sessionStorageDouble = createStorageDouble(initialSessionStorage());
const { instance } = await instantiateSignalsBytes(bytes, {
  localStorage: localStorageDouble,
  sessionStorage: sessionStorageDouble,
});
const root = installDomDouble();
const errors = [];
const missingBehaviors = [];
const behaviorCounts = { attached: 0, cleaned: 0 };
const telemetryEntries = [];
const browserEvents = createEventTargetDouble();
const browserDocument = createEventTargetDouble();
browserDocument.visibilityState = "visible";
const browserNavigator = { onLine: true };
const browserHistory = createBrowserHistory(initialBrowserHref(), browserEvents);
const locationDouble = {
  get href() {
    return browserHistory.href;
  },
};
const runtime = new SignalsRuntime(instance.exports, root, {
  taskHandler: publicExampleTaskHandler,
  behaviors: instrumentBehaviors(serviceOpsBehaviors, behaviorCounts),
  location: locationDouble,
  history: browserHistory,
  eventTarget: browserEvents,
  document: browserDocument,
  navigator: browserNavigator,
  networkEventTarget: browserEvents,
  localStorage: localStorageDouble,
  sessionStorage: sessionStorageDouble,
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
  await exerciseRefreshWorkflow(name, root, errors, browserHistory, browserEvents, browserDocument);
}

if (exerciseTeamCheckoutPlans) {
  await exerciseTeamCheckoutPlanWorkflow(name, root, errors, localStorageDouble);
}

if (exerciseLocationSource) {
  await exerciseLocationSourceWorkflow(name, root, errors, browserHistory, browserEvents);
}

if (exerciseLocationNavigation) {
  await exerciseLocationNavigationWorkflow(name, root, errors, browserHistory, browserEvents);
}

if (exerciseLocationCanonicalBranch) {
  await exerciseLocationCanonicalBranchWorkflow(name, root, errors, browserHistory, browserEvents);
}

if (exerciseStorageCommands) {
  await exerciseStorageCommandsWorkflow(name, root, errors, localStorageDouble, sessionStorageDouble);
}

if (exerciseLiveSearchOnline) {
  await exerciseLiveSearchOnlineWorkflow(name, root, errors, browserNavigator, browserEvents);
}

try {
  runtime.unmount();
} catch (err) {
  const detail = hostError(instance.exports);
  const suffix = detail === "" ? "" : `\nHost error: ${detail}`;
  fail(`failed to unmount ${name}: ${err?.stack ?? err}${suffix}`);
}

if (browserDocument.listenerCount("visibilitychange") !== 0) {
  fail(`mounted ${name}, but the visibilitychange listener was not removed on unmount`);
}

if (browserEvents.listenerCount("popstate") !== 0) {
  fail(`mounted ${name}, but the popstate listener was not removed on unmount`);
}

if (browserEvents.listenerCount("online") !== 0 || browserEvents.listenerCount("offline") !== 0) {
  fail(`mounted ${name}, but the online/offline listeners were not removed on unmount`);
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

async function exerciseRefreshWorkflow(name, root, errors, browserHistory, browserEvents, browserDocument) {
  if (browserEvents.listenerCount("popstate") !== 1) {
    fail(`mounted ${name}, but the popstate listener was not installed`);
  }
  if (browserDocument.listenerCount("visibilitychange") !== 1) {
    fail(`mounted ${name}, but the visibilitychange listener was not installed`);
  }
  expectBrowserPath(name, browserHistory, "/", "mounting the overview");
  if (!root.textContent.includes("Traffic")) {
    fail(`mounted ${name}, but the service overview was not rendered`);
  }
  if (!root.textContent.includes("Auto refresh active")) {
    fail(`mounted ${name}, but the auto-refresh active status was not rendered`);
  }

  const apiLink = findByText(root, "a", "Open api details");
  if (!apiLink) {
    fail(`mounted ${name}, but the API service route link was not rendered`);
  }

  const linkEvent = fireEvent(apiLink, "click", { bubbles: true });
  await new Promise((resolve) => setTimeout(resolve, settleMs));
  failOnRuntimeErrors(name, errors, "opening the API service route");

  if (!linkEvent.defaultPrevented) {
    fail(`opened ${name} API details, but the route link did not prevent default navigation`);
  }
  expectBrowserPath(name, browserHistory, "/services/api", "opening the API service route");
  if (!root.textContent.includes("api service detail")) {
    fail(`opened ${name} API service route, but the detail panel was not rendered`);
  }

  if (!browserHistory.back()) {
    fail(`opened ${name} API service route, but browser Back had no history entry`);
  }
  await new Promise((resolve) => setTimeout(resolve, settleMs));
  failOnRuntimeErrors(name, errors, "going back to the service overview");
  expectBrowserPath(name, browserHistory, "/", "going back to the service overview");
  if (!root.textContent.includes("Traffic")) {
    fail(`went back in ${name}, but the service overview was not restored`);
  }

  if (!browserHistory.forward()) {
    fail(`went back in ${name}, but browser Forward had no history entry`);
  }
  await new Promise((resolve) => setTimeout(resolve, settleMs));
  failOnRuntimeErrors(name, errors, "going forward to the API service route");
  expectBrowserPath(name, browserHistory, "/services/api", "going forward to the API service route");
  if (!root.textContent.includes("api service detail")) {
    fail(`went forward in ${name}, but the API detail panel was not restored`);
  }

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

  browserDocument.visibilityState = "hidden";
  browserDocument.dispatch("visibilitychange");
  await new Promise((resolve) => setTimeout(resolve, settleMs));
  failOnRuntimeErrors(name, errors, "hiding the service ops tab");
  if (!root.textContent.includes("Auto refresh paused while tab is hidden")) {
    fail(`hid ${name}, but the auto-refresh paused status was not rendered`);
  }

  browserDocument.visibilityState = "visible";
  browserDocument.dispatch("visibilitychange");
  await new Promise((resolve) => setTimeout(resolve, settleMs));
  failOnRuntimeErrors(name, errors, "showing the service ops tab");
  if (!root.textContent.includes("Auto refresh active")) {
    fail(`showed ${name}, but the auto-refresh active status was not restored`);
  }
}

async function exerciseLocationSourceWorkflow(name, root, errors, browserHistory, browserEvents) {
  if (browserEvents.listenerCount("popstate") !== 1) {
    fail(`mounted ${name}, but the popstate listener was not installed`);
  }
  failOnRuntimeErrors(name, errors, "checking location source listener setup");
  expectBrowserUrl(name, browserHistory, "/services/api", "tab=logs", "tail", "mounting the seeded location source");
  expectRenderedLocation(name, root, "/services/api", "tab=logs", "tail", "mounting the seeded location source");

  browserHistory.pushState(null, "", "/services/web?tab=deploys#events");
  browserEvents.dispatch("popstate");
  await new Promise((resolve) => setTimeout(resolve, settleMs));
  failOnRuntimeErrors(name, errors, "updating the location source");
  expectBrowserUrl(name, browserHistory, "/services/web", "tab=deploys", "events", "updating the location source");
  expectRenderedLocation(name, root, "/services/web", "tab=deploys", "events", "updating the location source");

  if (!browserHistory.back()) {
    fail(`updated ${name}, but browser Back had no history entry`);
  }
  await new Promise((resolve) => setTimeout(resolve, settleMs));
  failOnRuntimeErrors(name, errors, "going back through the location source");
  expectBrowserUrl(name, browserHistory, "/services/api", "tab=logs", "tail", "going back through the location source");
  expectRenderedLocation(name, root, "/services/api", "tab=logs", "tail", "going back through the location source");

  if (!browserHistory.forward()) {
    fail(`went back in ${name}, but browser Forward had no history entry`);
  }
  await new Promise((resolve) => setTimeout(resolve, settleMs));
  failOnRuntimeErrors(name, errors, "going forward through the location source");
  expectBrowserUrl(name, browserHistory, "/services/web", "tab=deploys", "events", "going forward through the location source");
  expectRenderedLocation(name, root, "/services/web", "tab=deploys", "events", "going forward through the location source");
}

async function exerciseLocationNavigationWorkflow(name, root, errors, browserHistory, browserEvents) {
  if (browserEvents.listenerCount("popstate") !== 1) {
    fail(`mounted ${name}, but the popstate listener was not installed`);
  }
  await new Promise((resolve) => setTimeout(resolve, settleMs));
  failOnRuntimeErrors(name, errors, "checking command-backed location replacement");
  expectBrowserUrl(name, browserHistory, "/services/web", "tab=deploys", "events", "applying command-backed location replacement");
  expectRenderedLocation(name, root, "/services/web", "tab=deploys", "events", "applying command-backed location replacement");
}

async function exerciseLocationCanonicalBranchWorkflow(name, root, errors, browserHistory, browserEvents) {
  if (!root.textContent.includes("Detail branch")) {
    fail(`mounted ${name}, but the initial detail branch was not rendered`);
  }

  browserHistory.pushState(null, "", "/services/missing");
  browserEvents.dispatch("popstate");
  await new Promise((resolve) => setTimeout(resolve, settleMs));
  failOnRuntimeErrors(name, errors, "canonicalizing a nested location update");
  expectBrowserPath(name, browserHistory, "/", "canonicalizing a nested location update");
  if (!root.textContent.includes("Path: /") || !root.textContent.includes("Overview branch")) {
    fail(`canonicalized ${name}, but the overview branch and final path were not rendered`);
  }
  if (root.textContent.includes("Detail branch")) {
    fail(`canonicalized ${name}, but the stale detail branch remained mounted`);
  }
}

async function exerciseLiveSearchOnlineWorkflow(name, root, errors, browserNavigator, browserEvents) {
  if (browserEvents.listenerCount("online") !== 1 || browserEvents.listenerCount("offline") !== 1) {
    fail(`mounted ${name}, but the online/offline listeners were not installed`);
  }
  failOnRuntimeErrors(name, errors, "checking live search online listener setup");

  if (!root.textContent.includes("Network: online")) {
    fail(`mounted ${name}, but the online status was not rendered`);
  }

  const input = root.querySelector('[aria-label="Search"]');
  if (!input) {
    fail(`mounted ${name}, but the Search input was not rendered`);
  }

  browserNavigator.onLine = false;
  browserEvents.dispatch("offline");
  await new Promise((resolve) => setTimeout(resolve, settleMs));
  failOnRuntimeErrors(name, errors, "switching live search offline");
  if (!root.textContent.includes("Network: offline - search paused")) {
    fail(`switched ${name} offline, but the offline search status was not rendered`);
  }

  input.value = "roc";
  fireEvent(input, "input", { bubbles: true });
  await new Promise((resolve) => setTimeout(resolve, settleMs * 3));
  failOnRuntimeErrors(name, errors, "typing a live search query while offline");
  if (root.textContent.includes('Top results for "roc"')) {
    fail(`typed in ${name} while offline, but a lookup result was rendered`);
  }

  browserNavigator.onLine = true;
  browserEvents.dispatch("online");
  await new Promise((resolve) => setTimeout(resolve, settleMs * 3));
  failOnRuntimeErrors(name, errors, "switching live search online");
  if (!root.textContent.includes("Network: online")) {
    fail(`switched ${name} online, but the online search status was not restored`);
  }
  if (!root.textContent.includes('Top results for "roc"')) {
    fail(`switched ${name} online, but the current query was not looked up`);
  }
}

async function exerciseTeamCheckoutPlanWorkflow(name, root, errors, localStorageDouble) {
  failOnRuntimeErrors(name, errors, "checking restored team checkout storage");

  if (!root.textContent.includes("Resume saved order")) {
    fail(`mounted ${name}, but the saved order resume panel was not rendered`);
  }
  if (!root.textContent.includes("Step 2 - Delivery")) {
    fail(`mounted ${name}, but the saved checkout step was not restored`);
  }

  const emailInput = root.querySelector('[aria-label="Email"]');
  const addressInput = root.querySelector('[aria-label="Address"]');
  const termsInput = root.querySelector('[aria-label="Accept terms"]');
  if (!emailInput || !addressInput || !termsInput) {
    fail(`mounted ${name}, but the delivery inputs were not rendered from saved state`);
  }
  if (emailInput.value !== "saved@example.com" || addressInput.value !== "Saved Signal Lane") {
    fail(`mounted ${name}, but delivery input values were not restored from storage`);
  }
  if (termsInput.checked !== false) {
    fail(`mounted ${name}, but the saved terms checkbox state was not restored`);
  }

  emailInput.value = "team@example.com";
  fireEvent(emailInput, "input", { bubbles: true });
  addressInput.value = "42 Signal Way";
  fireEvent(addressInput, "input", { bubbles: true });
  termsInput.checked = true;
  fireEvent(termsInput, "change", { bubbles: true });
  await new Promise((resolve) => setTimeout(resolve, settleMs));
  failOnRuntimeErrors(name, errors, "updating restored delivery fields");
  expectStorageValue(name, localStorageDouble, "team-checkout:email", "team@example.com");
  expectStorageValue(name, localStorageDouble, "team-checkout:address", "42 Signal Way");
  expectStorageValue(name, localStorageDouble, "team-checkout:terms", "true");

  const backButton = findByText(root, "button", "Back");
  if (!backButton) {
    fail(`mounted ${name}, but the checkout Back button was not rendered`);
  }
  fireEvent(backButton, "click", { bubbles: true });
  await new Promise((resolve) => setTimeout(resolve, settleMs));
  failOnRuntimeErrors(name, errors, "returning restored checkout to the cart");
  expectStorageValue(name, localStorageDouble, "team-checkout:step", "0");

  const basicButton = findByText(root, "button", "Use basic plan");
  const teamButton = findByText(root, "button", "Use team plan");
  if (!basicButton || !teamButton) {
    fail(`mounted ${name}, but the team checkout plan buttons were not rendered`);
  }

  if (!root.textContent.includes("Priority support") || !root.textContent.includes("Audit log export")) {
    fail(`mounted ${name}, but the team plan rows were not initially rendered`);
  }
  for (const text of [
    "3 seats quantity: 1",
    "Priority support quantity: 3",
    "Audit log export quantity: 4",
  ]) {
    if (!root.textContent.includes(text)) {
      fail(`mounted ${name}, but restored cart quantity text was missing: ${text}`);
    }
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
  expectStorageValue(name, localStorageDouble, "team-checkout:plan", "team");

  const increaseSeatsButton = findByText(root, "button", "Increase 3 seats");
  if (!increaseSeatsButton) {
    fail(`mounted ${name}, but the 3 seats increment button was not rendered`);
  }
  fireEvent(increaseSeatsButton, "click", { bubbles: true });
  await new Promise((resolve) => setTimeout(resolve, settleMs));
  failOnRuntimeErrors(name, errors, "increasing the restored cart quantity");
  if (!root.textContent.includes("3 seats quantity: 2")) {
    fail(`increased ${name} 3 seats quantity, but the cart text did not update`);
  }
  expectStorageValue(name, localStorageDouble, "team-checkout:qty:3-seats", "2");

  const clearButton = findByText(root, "button", "Clear saved order");
  if (!clearButton) {
    fail(`mounted ${name}, but the clear saved order button was not rendered`);
  }
  fireEvent(clearButton, "click", { bubbles: true });
  await new Promise((resolve) => setTimeout(resolve, settleMs));
  failOnRuntimeErrors(name, errors, "clearing the saved checkout");
  for (const key of teamCheckoutStorageKeys) {
    expectNoStorageValue(name, localStorageDouble, key);
  }
}

async function exerciseStorageCommandsWorkflow(name, root, errors, localStorageDouble, sessionStorageDouble) {
  failOnRuntimeErrors(name, errors, "checking browser storage commands");

  for (const text of [
    "Storage Commands",
    "Local draft: seeded local",
    "Session flash: seeded flash",
    "Missing draft: missing",
  ]) {
    if (!root.textContent.includes(text)) {
      fail(`mounted ${name}, but storage fixture text was missing: ${text}`);
    }
  }

  if (localStorageDouble.getItem("checkout:draft") !== "mount saved") {
    fail(`mounted ${name}, but localStorage checkout:draft was not updated`);
  }
  if (localStorageDouble.getItem("checkout:coalesced") !== "new") {
    fail(`mounted ${name}, but localStorage checkout:coalesced was not coalesced to the final value`);
  }
  if (sessionStorageDouble.getItem("checkout:flash") !== null) {
    fail(`mounted ${name}, but sessionStorage checkout:flash was not removed`);
  }
}

function failOnRuntimeErrors(name, errors, action) {
  if (errors.length === 0) {
    return;
  }
  const details = errors.map((err) => err?.stack ?? err).join("\n");
  fail(`runtime reported errors while ${action} in ${name}:\n${details}`);
}

function expectStorageValue(name, storage, key, expected) {
  const actual = storage.getItem(key);
  if (actual !== expected) {
    fail(`exercised ${name}, but localStorage ${key} was ${actual}, expected ${expected}`);
  }
}

function expectNoStorageValue(name, storage, key) {
  const actual = storage.getItem(key);
  if (actual !== null) {
    fail(`exercised ${name}, but localStorage ${key} was still present with value ${actual}`);
  }
}

function expectRenderedLocation(name, root, path, query, hash, action) {
  for (const text of [`Path: ${path}`, `Query: ${query}`, `Hash: ${hash}`]) {
    if (!root.textContent.includes(text)) {
      fail(`${action} in ${name} did not render ${text}`);
    }
  }
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

function createEventTargetDouble() {
  const listeners = new Map();
  return {
    addEventListener(type, listener) {
      const entries = listeners.get(type) ?? [];
      entries.push(listener);
      listeners.set(type, entries);
    },
    removeEventListener(type, listener) {
      const entries = listeners.get(type) ?? [];
      listeners.set(
        type,
        entries.filter((entry) => entry !== listener),
      );
    },
    dispatch(type) {
      for (const listener of [...(listeners.get(type) ?? [])]) {
        listener({ type });
      }
    },
    listenerCount(type) {
      return listeners.get(type)?.length ?? 0;
    },
  };
}

function createBrowserHistory(initialHref, eventTarget) {
  const state = {
    entries: [new URL(initialHref).href],
    index: 0,
  };

  function resolveHref(href) {
    if (href === undefined || href === null) {
      return state.entries[state.index];
    }
    return new URL(String(href), state.entries[state.index]).href;
  }

  return {
    get href() {
      return state.entries[state.index];
    },
    get path() {
      return new URL(state.entries[state.index]).pathname;
    },
    pushState(_state, _title, href) {
      const nextHref = resolveHref(href);
      state.entries = state.entries.slice(0, state.index + 1);
      state.entries.push(nextHref);
      state.index = state.entries.length - 1;
    },
    replaceState(_state, _title, href) {
      state.entries[state.index] = resolveHref(href);
    },
    back() {
      if (state.index === 0) {
        return false;
      }
      state.index -= 1;
      eventTarget.dispatch("popstate");
      return true;
    },
    forward() {
      if (state.index + 1 >= state.entries.length) {
        return false;
      }
      state.index += 1;
      eventTarget.dispatch("popstate");
      return true;
    },
  };
}

function expectBrowserPath(name, browserHistory, expectedPath, action) {
  if (browserHistory.path !== expectedPath) {
    fail(`${action} in ${name} left browser path ${browserHistory.path}, expected ${expectedPath}`);
  }
}

function expectBrowserUrl(name, browserHistory, expectedPath, expectedQuery, expectedHash, action) {
  const url = new URL(browserHistory.href);
  const actualQuery = url.search.startsWith("?") ? url.search.slice(1) : url.search;
  const actualHash = url.hash.startsWith("#") ? url.hash.slice(1) : url.hash;
  if (url.pathname !== expectedPath || actualQuery !== expectedQuery || actualHash !== expectedHash) {
    fail(
      `${action} in ${name} left browser URL ${url.pathname}${url.search}${url.hash}, expected ${expectedPath}?${expectedQuery}#${expectedHash}`,
    );
  }
}
