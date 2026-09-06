#!/usr/bin/env node

import { readFile } from "node:fs/promises";
import { basename } from "node:path";

import { publicExampleTaskHandler } from "../../www/static/example_tasks.mjs";
import { serviceOpsBehaviors } from "../../www/static/service_ops_charts.mjs";
import { SignalsRuntime, instantiateSignalsBytes } from "../../www/static/signals.mjs";
import { findByText, findNode, fireEvent, installDomDouble } from "./dom_double.mjs";

const args = process.argv.slice(2);
const wasmPath = args.shift();
let expectError = "";
let printTelemetrySummary = false;
let exerciseClickFirstLink = false;
let exerciseLocationSource = false;
let exerciseLocationNavigation = false;
let exerciseLocationCanonicalBranch = false;
let exerciseStorageCommands = false;
let exerciseEventActions = false;
let exerciseCoordinatedWrites = false;
let exerciseSvg = false;
let rawName;

while (args.length > 0) {
  const arg = args.shift();
  if (arg === "--expect-error") {
    expectError = args.shift() ?? "";
  } else if (arg === "--telemetry-summary") {
    printTelemetrySummary = true;
  } else if (arg === "--exercise-click-first-link") {
    exerciseClickFirstLink = true;
  } else if (arg === "--exercise-location-source") {
    exerciseLocationSource = true;
  } else if (arg === "--exercise-location-navigation") {
    exerciseLocationNavigation = true;
  } else if (arg === "--exercise-location-canonical-branch") {
    exerciseLocationCanonicalBranch = true;
  } else if (arg === "--exercise-storage-commands") {
    exerciseStorageCommands = true;
  } else if (arg === "--exercise-event-actions") {
    exerciseEventActions = true;
  } else if (arg === "--exercise-coordinated-writes") {
    exerciseCoordinatedWrites = true;
  } else if (arg === "--exercise-svg") {
    exerciseSvg = true;
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
    "usage: mount_wasm_example.mjs <wasm-path> [name] [--expect-error <substring>] [--telemetry-summary] [--exercise-location-source] [--exercise-location-navigation] [--exercise-location-canonical-branch] [--exercise-storage-commands] [--exercise-event-actions] [--exercise-coordinated-writes] [--exercise-svg]",
  );
  process.exit(2);
}

const name = rawName ?? basename(wasmPath);
const settleMs = 50;

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
const actionRequests = [];
const runtime = new SignalsRuntime(instance.exports, root, {
  taskHandler: exerciseEventActions || exerciseCoordinatedWrites
    ? (request) => {
      const allowed = exerciseCoordinatedWrites ? ["write-observer", "partial-write"] : ["action-ping", "action-dispose"];
      if (!allowed.includes(request.name)) throw new Error(`unexpected action task: ${request.name}`);
      return new Promise((resolve) => actionRequests.push({ ...request, resolve }));
    }
    : publicExampleTaskHandler,
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

if (exerciseClickFirstLink) {
  const link = findNode(root, (node) => node.tagName === "A");
  if (!link) {
    fail(`mounted ${name}, but no <a> element was rendered to click`);
  }
  fireEvent(link, "click", { bubbles: true });
  await new Promise((resolve) => setTimeout(resolve, settleMs));
  if (errors.length !== 0) {
    const details = errors.map((err) => err?.stack ?? err).join("\n");
    fail(`clicking the first link in ${name} reported errors:\n${details}`);
  }
  console.log(`clicked first link in ${name}`);
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

if (exerciseEventActions) {
  await exerciseEventActionsWorkflow(name, root, errors, actionRequests);
}
if (exerciseCoordinatedWrites) {
  await exerciseCoordinatedWritesWorkflow(name, root, errors, actionRequests);
}
if (exerciseSvg) {
  const svgNamespace = "http://www.w3.org/2000/svg";
  const byId = (id) => findNode(root, (node) => node.getAttribute?.("data-testid") === id);
  const graph = byId("graph");
  const label = byId("graph-label");
  let switched = byId("namespace-switch");
  if (switched?.namespaceURI !== "http://www.w3.org/1999/xhtml") fail("initial namespace-switch anchor was not HTML");
  if (graph?.namespaceURI !== svgNamespace || graph.getAttribute("viewBox") !== "0 0 200 100" || graph.getAttribute("class") !== "diagram") fail("SVG viewport attributes or namespace were lost");
  if (label?.namespaceURI !== svgNamespace || label.localName !== "text" || label.textContent !== "Initial") fail("SVG text element was confused with a text node");
  if (byId("gradient")?.localName !== "linearGradient") fail("SVG local-name case was lost");
  for (const changed of [true, false, true, false]) {
    fireEvent(findByText(root, "button", "Change graph"), "click", { bubbles: true });
    await new Promise((resolve) => setTimeout(resolve, settleMs));
    failOnRuntimeErrors(name, errors, "updating SVG");
    const next = byId("namespace-switch");
    if (next === switched || next?.localName !== "a" || next?.namespaceURI !== (changed ? svgNamespace : "http://www.w3.org/1999/xhtml")) fail("same-name namespace change reused the wrong rendered node");
    switched = next;
    if (byId("graph-label") !== label || label.textContent !== (changed ? "Updated" : "Initial")) fail("SVG label update replaced its element or used a stale value");
    if (changed) {
      if (byId("foreign")?.namespaceURI !== svgNamespace || byId("foreign")?.localName !== "foreignObject") fail("dynamic SVG namespace or case was lost");
      if (byId("html-child")?.namespaceURI !== "http://www.w3.org/1999/xhtml") fail("foreignObject child did not preserve its explicit HTML namespace");
    } else if (byId("gradient")?.namespaceURI !== svgNamespace || byId("foreign")) fail("SVG scope replacement retained stale structure");
  }
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

const liveRocAllocations = instance.exports.roc_ui_debug_live_allocation_count?.();
const liveRocBytes = instance.exports.roc_ui_debug_live_allocation_bytes?.();
if (liveRocAllocations !== undefined && (liveRocAllocations !== 0 || liveRocBytes !== 0)) {
  fail(
    `mounted ${name}, but ${liveRocAllocations} Roc allocations / ${liveRocBytes} bytes are still live after unmount`,
  );
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

async function exerciseCoordinatedWritesWorkflow(name, root, errors, requests) {
  const read = (id) => findNode(root, (node) => node.getAttribute?.("data-testid") === id)?.textContent;
  const click = async (label, pair, count, branch) => {
    const button = findByText(root, "button", label);
    if (!button) fail(`missing coordinated write button: ${label}`);
    fireEvent(button, "click", { bubbles: true });
    await new Promise((resolve) => setTimeout(resolve, settleMs));
    failOnRuntimeErrors(name, errors, "coordinating state writes");
    if (read("pair") !== pair || read("branch-value") !== branch) {
      fail(`coordinated writes rendered an inconsistent snapshot after ${label}`);
    }
    if (requests.length !== count || requests.some((request) => request.name !== "write-observer")) {
      fail(`coordinated writes exposed a partial snapshot or repeated an unchanged effect after ${label}`);
    }
    if (count && (requests[count - 1].request !== pair || requests[count - 1].signal.aborted)) {
      fail(`coordinated write observer did not receive the final snapshot after ${label}`);
    }
    if (requests.slice(0, -1).some((request) => !request.signal.aborted)) {
      fail("coordinated write observer left an obsolete request active");
    }
  };
  await click("Cached single", "A:B", 0, undefined);
  await click("Cached single", "A:B", 0, undefined);
  await click("Swap", "B:A", 1, "A");
  await click("Swap reversed", "A:B", 2, undefined);
  await click("Swap", "B:A", 3, "A");
  await click("Cached reset", "A:B", 4, undefined);
  await click("Cached reset", "A:B", 4, undefined);
}

async function exerciseEventActionsWorkflow(name, root, errors, requests) {
  const settle = async () => {
    await new Promise((resolve) => setTimeout(resolve, settleMs));
    failOnRuntimeErrors(name, errors, "dispatching event actions");
  };
  const click = (text) => {
    const button = findByText(root, "button", text);
    if (!button) fail(`missing action button: ${text}`);
    fireEvent(button, "click", { bubbles: true });
  };
  const fill = async (value) => {
    const input = findNode(root, (node) => node.tagName === "INPUT");
    if (!input) fail("missing action source input");
    input.value = value;
    fireEvent(input, "input", { bubbles: true });
    await settle();
  };
  const expectResult = (text) => {
    const result = findNode(root, (node) => node.getAttribute?.("data-testid") === "result");
    if (result?.textContent !== text) fail(`action result was ${result?.textContent}, expected ${text}`);
  };

  await fill("beta");
  expectResult("waiting");
  if (requests.length !== 0) fail("changing action reads started a task");
  // Dispatch before yielding: lossless clicks must not coalesce in the browser queue.
  click("Append snapshot");
  click("Append snapshot");
  await settle();
  expectResult("waiting|beta|beta");
  click("Ping");
  click("Ping");
  await settle();
  if (requests.length !== 2 || requests.some((request) => request.request !== "beta")) {
    fail("identical action clicks did not start two identical requests");
  }
  if (!requests[0].signal.aborted || requests[1].signal.aborted) {
    fail("repeated action requests did not preserve latest-wins cancellation");
  }
  await fill("gamma");
  if (requests.length !== 2) fail("updating action reads repeated a request");
  click("Toggle actions");
  await settle();
  if (!requests[1].signal.aborted || findByText(root, "button", "Ping")) {
    fail("disposing an action scope did not remove its handler and cancel its task");
  }
  // Late completions from canceled requests must not revive disposed work.
  requests[0].resolve("stale first");
  requests[1].resolve("stale second");
  await settle();
  const status = findNode(root, (node) => node.getAttribute?.("data-testid") === "status");
  if (status?.textContent !== "idle") fail("canceled action completion changed task state");
  click("Toggle actions");
  await settle();
  click("Append snapshot");
  await settle();
  expectResult("waiting|beta|beta|gamma");
  click("Prime disposal");
  await settle();
  if (requests.length !== 3 || requests[2].name !== "action-dispose") fail("disposal primer did not start");
  requests[2].resolve("ready");
  await settle();
  click("Dispose on loading");
  await settle();
  if (requests.length !== 4 || !requests[3].signal.aborted) fail("Loading did not cancel its own action's request");
  if (findByText(root, "button", "Dispose on loading")) fail("Loading left its action scope rendered");
  requests[3].resolve("ready");
  await settle();
  const disposeStatus = findNode(root, (node) => node.getAttribute?.("data-testid") === "dispose-status");
  if (disposeStatus?.textContent !== "idle") fail("retired action completion resurrected its Loading scope");
  const target = (id) => {
    const node = findNode(root, (candidate) => candidate.getAttribute?.("data-testid") === id);
    if (!node) fail(`missing typed action target: ${id}`);
    return node;
  };
  const textInput = target("action-text");
  textInput.value = "hello 🌱";
  fireEvent(textInput, "input", { bubbles: true });
  fireEvent(textInput, "input", { bubbles: true });
  await settle();
  let expected = "waiting|beta|beta|gamma|text:gamma:hello 🌱|text:gamma:hello 🌱";
  expectResult(expected);
  const checkbox = target("action-check");
  checkbox.checked = true;
  fireEvent(checkbox, "change", { bubbles: true });
  await settle();
  expected += "|checked:True";
  expectResult(expected);
  checkbox.checked = false;
  fireEvent(checkbox, "change", { bubbles: true });
  await settle();
  expected += "|checked:False";
  expectResult(expected);
  fireEvent(target("action-key"), "keydown", { bubbles: true, key: "Enter", shiftKey: true });
  await settle();
  expected += "|key:Enter:True";
  expectResult(expected);
  fireEvent(target("action-detail"), "demo-detail", { bubbles: true, detail: "package ready" });
  fireEvent(target("action-detail"), "demo-detail", { bubbles: true, detail: "package ready" });
  await settle();
  expected += "|detail:package ready|detail:package ready";
  expectResult(expected);
  console.log(`exercised repeated actions, snapshots, and scoped cancellation in ${name}`);
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
