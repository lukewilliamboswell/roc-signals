import { createMemoryViewCache } from "./wasm_memory_views.mjs";
import {
  applySetValue,
  beginComposition,
  blurInput,
  createControlledInputState,
  endComposition,
  focusInput,
  userInput,
} from "./controlled_input_policy.mjs";

export const Op = Object.freeze({
  resetDom: 1,
  createElement: 2,
  createText: 3,
  appendChild: 4,
  removeNode: 5,
  moveBefore: 6,
  setText: 7,
  setValue: 8,
  setChecked: 9,
  setDisabled: 10,
  setRole: 11,
  setLabel: 12,
  setTestId: 13,
  bindClick: 14,
  bindInput: 15,
  bindCheck: 16,
  clearEvent: 17,
  startInterval: 18,
  cancelInterval: 19,
  startTask: 20,
  cancelTask: 21,
  setClass: 22,
  bindPointerDown: 23,
  bindPointerUp: 24,
  bindPointerEnter: 25,
  bindPointerLeave: 26,
  extended: 27,
});

export const Protocol = Object.freeze({
  version: 7,
});

export const ProtocolFeature = Object.freeze({
  dynamicAttrs: 1 << 0,
  dynamicEvents: 1 << 1,
});

const requiredProtocolFeatures =
  ProtocolFeature.dynamicAttrs | ProtocolFeature.dynamicEvents;

export const DynamicOp = Object.freeze({
  setAttrText: 1,
  removeAttr: 2,
  bindEvent: 3,
  clearEvent: 4,
});

// RenderEventKind enum (render_commands.zig) -> DOM event name. The host emits
// `clearEvent` with the kind in operand `b`; JS maps it back to the listener it
// bound so it can run the matching cleanup.
const EventKind = Object.freeze({
  click: 1,
  input: 2,
  check: 3,
  pointerDown: 4,
  pointerUp: 5,
  pointerEnter: 6,
  pointerLeave: 7,
});
const domEventForKind = Object.freeze({
  [EventKind.click]: "click",
  [EventKind.input]: "input",
  [EventKind.check]: "change",
  [EventKind.pointerDown]: "pointerdown",
  [EventKind.pointerUp]: "pointerup",
  [EventKind.pointerEnter]: "pointerenter",
  [EventKind.pointerLeave]: "pointerleave",
});

const opNames = Object.freeze({
  [Op.resetDom]: "reset_dom",
  [Op.createElement]: "create_element",
  [Op.createText]: "create_text",
  [Op.appendChild]: "append_child",
  [Op.removeNode]: "remove_node",
  [Op.moveBefore]: "move_before",
  [Op.setText]: "set_text",
  [Op.setValue]: "set_value",
  [Op.setChecked]: "set_checked",
  [Op.setDisabled]: "set_disabled",
  [Op.setRole]: "set_role",
  [Op.setLabel]: "set_label",
  [Op.setTestId]: "set_test_id",
  [Op.bindClick]: "bind_click",
  [Op.bindInput]: "bind_input",
  [Op.bindCheck]: "bind_check",
  [Op.clearEvent]: "clear_event",
  [Op.startInterval]: "start_interval",
  [Op.cancelInterval]: "cancel_interval",
  [Op.startTask]: "start_task",
  [Op.cancelTask]: "cancel_task",
  [Op.setClass]: "set_class",
  [Op.bindPointerDown]: "bind_pointer_down",
  [Op.bindPointerUp]: "bind_pointer_up",
  [Op.bindPointerEnter]: "bind_pointer_enter",
  [Op.bindPointerLeave]: "bind_pointer_leave",
  [Op.extended]: "extended",
});

const dynamicOpNames = Object.freeze({
  [DynamicOp.setAttrText]: "set_attr_text",
  [DynamicOp.removeAttr]: "remove_attr",
  [DynamicOp.bindEvent]: "bind_event",
  [DynamicOp.clearEvent]: "clear_event",
});

export const PayloadKind = Object.freeze({
  unit: 1,
  str: 2,
  bool: 3,
  bytes: 4,
});

const payloadKindNames = Object.freeze({
  [PayloadKind.unit]: "unit",
  [PayloadKind.str]: "str",
  [PayloadKind.bool]: "bool",
  [PayloadKind.bytes]: "bytes",
});

export const ListenerOptions = Object.freeze({
  preventDefault: 1 << 0,
  stopPropagation: 1 << 1,
  capture: 1 << 2,
  passive: 1 << 3,
  once: 1 << 4,
  stopImmediatePropagation: 1 << 5,
  self: 1 << 6,
  trusted: 1 << 7,
});

const knownListenerOptionMask =
  ListenerOptions.preventDefault |
  ListenerOptions.stopPropagation |
  ListenerOptions.capture |
  ListenerOptions.passive |
  ListenerOptions.once |
  ListenerOptions.stopImmediatePropagation |
  ListenerOptions.self |
  ListenerOptions.trusted;

const EventDelivery = Object.freeze({
  auto: "auto",
  native: "native",
  delegated: "delegated",
});

const EventDeliveryRequestWire = Object.freeze({
  auto: 1,
  native: 2,
});

const EventDeliveryEffectiveWire = Object.freeze({
  native: 1,
  delegated: 2,
});

const EventDeliveryReasonWire = Object.freeze({
  requestedNative: 1,
  capturePolicy: 2,
  stopImmediatePolicy: 3,
  stopPropagationPolicy: 4,
  pointerDrag: 5,
  preventDefaultPolicy: 6,
  oncePolicy: 7,
  passivePolicy: 8,
  selfFilter: 9,
  nativeRuntimeDefault: 10,
});

const eventDeliveryRequestNames = Object.freeze({
  [EventDeliveryRequestWire.auto]: EventDelivery.auto,
  [EventDeliveryRequestWire.native]: EventDelivery.native,
});

const eventDeliveryEffectiveNames = Object.freeze({
  [EventDeliveryEffectiveWire.native]: EventDelivery.native,
  [EventDeliveryEffectiveWire.delegated]: EventDelivery.delegated,
});

const eventDeliveryReasonNames = Object.freeze({
  [EventDeliveryReasonWire.requestedNative]: "requested-native",
  [EventDeliveryReasonWire.capturePolicy]: "capture-policy",
  [EventDeliveryReasonWire.stopImmediatePolicy]: "stop-immediate-policy",
  [EventDeliveryReasonWire.stopPropagationPolicy]: "stop-propagation-policy",
  [EventDeliveryReasonWire.pointerDrag]: "pointer-drag",
  [EventDeliveryReasonWire.preventDefaultPolicy]: "prevent-default-policy",
  [EventDeliveryReasonWire.oncePolicy]: "once-policy",
  [EventDeliveryReasonWire.passivePolicy]: "passive-policy",
  [EventDeliveryReasonWire.selfFilter]: "self-filter",
  [EventDeliveryReasonWire.nativeRuntimeDefault]: "native-runtime-default",
});

const BoundarySchemaTag = Object.freeze({
  unit: 1,
  text: 2,
  bool: 3,
  record: 4,
});

const EventExtractionSource = Object.freeze({
  event: 1,
  target: 2,
  currentTarget: 3,
});

const EventExtractionLeaf = Object.freeze({
  key: 1,
  value: 2,
  checked: 3,
  shiftKey: 4,
});

const fixedEventExtractionPlan = Object.freeze({
  unit: Object.freeze({ kind: "unit" }),
  targetValue: Object.freeze({
    kind: "text",
    source: EventExtractionSource.currentTarget,
    leaf: EventExtractionLeaf.value,
  }),
  targetChecked: Object.freeze({
    kind: "bool",
    source: EventExtractionSource.currentTarget,
    leaf: EventExtractionLeaf.checked,
  }),
});

const pointerProbeEvents = Object.freeze([
  "pointerdown",
  "pointermove",
  "pointerup",
  "pointercancel",
  "pointerover",
  "pointerout",
  "pointerenter",
  "pointerleave",
]);

export const HttpTask = Object.freeze({
  namePrefix: "http:send:",
  opsApiPaths: Object.freeze([
    "/api/ops/dashboard",
    "/api/ops/summary",
    "/api/ops/traffic",
    "/api/ops/jobs",
    "/api/ops/alerts",
    "/api/ops/health",
  ]),
});
export const HttpTextTask = HttpTask;

const textDecoder = new TextDecoder();
const dynamicTextDecoder = new TextDecoder("utf-8", { fatal: true });
const textEncoder = new TextEncoder();

const HttpPayloadVersion = Object.freeze({
  request: "roc-http-request-v1",
  response: "roc-http-response-v1",
  error: "roc-http-error-v1",
});

const opsDashboardBody = [
  "schema=1",
  "updated_version=1",
  "updated_hour=12",
  "updated_minute=0",
  "updated_second=0",
  "phase_code=0",
  "requests_per_minute=1480",
  "traffic_delta_percent=7",
  "error_permille=5",
  "burn_rate_x10=8",
  "budget_remaining_permille=987",
  "latency_ms=84",
  "latency_target_ms=120",
  "webhook_rpm=920",
  "webhook_bar_code=4",
  "db_write_rpm=680",
  "db_write_bar_code=3",
  "ingress_bar_code=5",
  "latency_bar_code=3",
  "error_bar_code=1",
  "budget_bar_code=1",
  "queue_depth=37",
  "queue_trend_code=1",
  "queue_capacity=120",
  "running_jobs=10",
  "blocked_jobs=0",
  "oldest_job_min=7",
  "job_a_id=101",
  "job_a_progress=72",
  "job_a_age_min=4",
  "job_a_state_code=0",
  "job_b_id=118",
  "job_b_progress=43",
  "job_b_age_min=9",
  "job_b_state_code=0",
  "job_c_id=132",
  "job_c_progress=58",
  "job_c_age_min=3",
  "job_c_state_code=0",
  "job_d_id=172",
  "job_d_progress=64",
  "job_d_age_min=6",
  "job_d_state_code=0",
  "alert_a_code=2",
  "alert_a_age_min=5",
  "alert_b_code=4",
  "alert_b_age_min=3",
  "alert_c_code=5",
  "alert_c_age_min=11",
  "edge_state_code=0",
  "edge_latency_ms=48",
  "api_state_code=0",
  "api_latency_ms=84",
  "worker_state_code=0",
  "worker_oldest_job_min=7",
  "database_state_code=0",
  "database_lag_sec=1",
  "billing_state_code=0",
  "billing_latency_ms=96",
  "search_state_code=0",
  "search_refresh_sec=14",
  "identity_state_code=0",
  "identity_latency_ms=42",
].join("\n");

const simulatedOpsApi = new Map([
  ["/api/ops/dashboard", opsDashboardBody],
  [
    "/api/ops/summary",
    [
      "Updated: 12:00:00 UTC  version 1",
      "Overall: Nominal  phase steady  incidents 0  tone good",
      "Traffic: 1,480 rpm  7% over 5m",
      "Errors: 0.5%  budget burn 0.8x",
      "Queue: 37 jobs  running 10  blocked 0",
      "Services: 7/7 healthy  primary region usw2",
    ].join("\n"),
  ],
  [
    "/api/ops/traffic",
    [
      "Ingress        1,480 rpm  ######------  +7% over 5m",
      "API p95        84 ms      ####--------  target 120 ms",
      "Error rate     0.5%       ##----------  budget burn 0.8x",
      "Webhook fanout 920 rpm    #####-------  steady",
      "DB writes      680 rpm    ####--------  replica lag 1s",
    ].join("\n"),
  ],
  [
    "/api/ops/jobs",
    [
      "job-101  running   72%  workers/search  4m  Rebuild search index",
      "job-118  running   43%  billing         9m  Backfill billing events",
      "job-132  running   58%  compliance      3m  Export audit archive",
      "job-172  running   64%  identity        6m  Prune stale sessions",
    ].join("\n"),
  ],
  [
    "/api/ops/alerts",
    [
      "WARNING workers      monitoring 5m   Retry queue elevated",
      "INFO    payments-api recovering 3m   Error budget burn below 1x",
      "INFO    edge         steady     11m  Canary pool normal",
    ].join("\n"),
  ],
  [
    "/api/ops/health",
    [
      "edge      ok       p95 48 ms   8 pods    all regions serving",
      "api       ok       p95 84 ms   12 pods   primary deploy api-01",
      "workers   ok       oldest 7m   24 slots  37 queued jobs",
      "database  ok       lag 1s      2 writers failover warm",
      "billing   ok       p95 96 ms   6 pods    webhooks draining",
      "search    ok       refresh 14s 5 shards  index green",
      "identity  ok       p95 42 ms   4 pods    session cache hot",
    ].join("\n"),
  ],
]);

export function encodeHttpRequestPayload({ method = "GET", uri = "", timeoutMs = null, headers = [], body = [] } = {}) {
  const fields = [
    HttpPayloadVersion.request,
    encodeHttpString(method),
    encodeHttpString(uri),
    timeoutMs === null || timeoutMs === undefined ? "-" : String(timeoutMs),
    String(headers.length),
  ];
  for (const [headerName, headerValue] of headers) {
    fields.push(encodeHttpString(String(headerName)));
    fields.push(encodeHttpString(String(headerValue)));
  }
  fields.push(encodeHttpBytes(bytesFrom(body)));
  return fields.join("\n");
}

export function decodeHttpRequestPayload(payload) {
  const lines = String(payload).split("\n");
  const reader = createHttpPayloadReader(lines, HttpPayloadVersion.request, "request");
  const method = decodeHttpString(reader.read("method"), "method");
  const uri = decodeHttpString(reader.read("uri"), "uri");
  const timeoutField = reader.read("timeout");
  const timeoutMs = timeoutField === "-" ? null : parseHttpInteger(timeoutField, "timeout");
  const headerCount = parseHttpInteger(reader.read("header count"), "header count");
  const headers = [];
  for (let index = 0; index < headerCount; index += 1) {
    headers.push([
      decodeHttpString(reader.read("header name"), "header name"),
      decodeHttpString(reader.read("header value"), "header value"),
    ]);
  }
  const body = decodeHttpBytes(reader.read("body"), "body");
  reader.done();
  return { method, uri, timeoutMs, headers, body };
}

export function encodeHttpResponsePayload({ status = 200, headers = [], body = [] } = {}) {
  const fields = [HttpPayloadVersion.response, String(status), String(headers.length)];
  for (const [headerName, headerValue] of headers) {
    fields.push(encodeHttpString(String(headerName)));
    fields.push(encodeHttpString(String(headerValue)));
  }
  fields.push(encodeHttpBytes(bytesFrom(body)));
  return fields.join("\n");
}

export function decodeHttpResponsePayload(payload) {
  const lines = String(payload).split("\n");
  const reader = createHttpPayloadReader(lines, HttpPayloadVersion.response, "response");
  const status = parseHttpInteger(reader.read("status"), "status");
  const headerCount = parseHttpInteger(reader.read("header count"), "header count");
  const headers = [];
  for (let index = 0; index < headerCount; index += 1) {
    headers.push([
      decodeHttpString(reader.read("header name"), "header name"),
      decodeHttpString(reader.read("header value"), "header value"),
    ]);
  }
  const body = decodeHttpBytes(reader.read("body"), "body");
  reader.done();
  return { status, headers, body };
}

export function encodeHttpErrorPayload(code, message = "") {
  return [HttpPayloadVersion.error, code, encodeHttpString(String(message))].join("\n");
}

export async function httpFetchTaskHandler({ name, request, signal, fetchImpl = globalThis.fetch }) {
  if (!name.startsWith(HttpTask.namePrefix)) {
    return null;
  }
  if (typeof fetchImpl !== "function") {
    throw new Error(encodeHttpErrorPayload("unsupported", "fetch is not available"));
  }

  let decoded;
  try {
    decoded = decodeHttpRequestPayload(request);
  } catch (err) {
    throw new Error(encodeHttpErrorPayload("unsupported", err?.message ?? err));
  }

  let timedOut = false;
  const controller = new AbortController();
  const relayAbort = () => controller.abort();
  if (signal?.aborted) {
    relayAbort();
  } else {
    signal?.addEventListener?.("abort", relayAbort, { once: true });
  }

  const timeoutId =
    decoded.timeoutMs === null
      ? null
      : setTimeout(() => {
          timedOut = true;
          controller.abort();
        }, decoded.timeoutMs);

  try {
    const response = await fetchImpl(decoded.uri, {
      method: decoded.method,
      headers: decoded.headers,
      body: decoded.body.length === 0 ? undefined : decoded.body,
      signal: controller.signal,
    });
    const body = new Uint8Array(await response.arrayBuffer());
    const headers = [...response.headers.entries()];
    return encodeHttpResponsePayload({ status: response.status, headers, body });
  } catch (err) {
    if (timedOut) {
      throw new Error(encodeHttpErrorPayload("timeout", ""));
    }
    if (controller.signal.aborted || err?.name === "AbortError") {
      throw new Error(encodeHttpErrorPayload("canceled", ""));
    }
    throw new Error(encodeHttpErrorPayload("network", err?.message ?? err));
  } finally {
    if (timeoutId !== null) {
      clearTimeout(timeoutId);
    }
    signal?.removeEventListener?.("abort", relayAbort);
  }
}

export function opsApiTextTaskHandler({ name, request }) {
  if (!name.startsWith(HttpTask.namePrefix)) {
    return null;
  }
  const decoded = decodeHttpRequestPayload(request);
  if (decoded.method !== "GET") {
    throw new Error(encodeHttpErrorPayload("unsupported", `unsupported ops API method: ${decoded.method}`));
  }
  const body = simulatedOpsApi.get(decoded.uri);
  if (body === undefined) {
    throw new Error(encodeHttpErrorPayload("unsupported", `unsupported ops API text endpoint: ${decoded.uri}`));
  }
  return Promise.resolve(
    encodeHttpResponsePayload({
      status: 200,
      headers: [["content-type", "text/plain; charset=utf-8"]],
      body: textEncoder.encode(body),
    }),
  );
}

export function apiRequestConsoleTaskHandler({ name, request }) {
  if (!name.startsWith(HttpTask.namePrefix)) {
    return null;
  }
  const decoded = decodeHttpRequestPayload(request);
  if (decoded.uri !== "/api/api-request-console") {
    return null;
  }
  if (decoded.method !== "POST") {
    throw new Error(encodeHttpErrorPayload("unsupported", `unsupported API console method: ${decoded.method}`));
  }

  const scenario = httpHeaderValue(decoded.headers, "x-scenario") || "success";
  if (scenario === "failure") {
    throw new Error(encodeHttpErrorPayload("network", "offline"));
  }

  const missing = scenario === "missing";
  return Promise.resolve(
    encodeHttpResponsePayload({
      status: missing ? 404 : 201,
      headers: [
        ["content-type", "application/json; charset=utf-8"],
        ["x-result", missing ? "missing" : "ok"],
      ],
      body: textEncoder.encode(
        missing
          ? '{"status":"missing","message":"customer record was not found"}'
          : '{"status":"created","message":"customer-42 is ready"}',
      ),
    }),
  );
}

export function lookupTaskHandler({ name, request, signal }) {
  if (name !== "lookup") {
    return null;
  }

  const query = String(request).trim();
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(new Error("canceled"));
      return;
    }

    const timer = setTimeout(() => {
      if (query.toLowerCase().includes("fail") || query.toLowerCase().includes("offline")) {
        reject(new Error("offline search index"));
      } else if (query === "") {
        resolve("Type a search term to see matching actions");
      } else {
        resolve(`Top results for "${query}": docs, examples, and release notes`);
      }
    }, 80);

    signal?.addEventListener?.(
      "abort",
      () => {
        clearTimeout(timer);
        reject(new Error("canceled"));
      },
      { once: true },
    );
  });
}

export function publicExampleTaskHandler(args) {
  const lookup = lookupTaskHandler(args);
  if (lookup !== null && lookup !== undefined) {
    return lookup;
  }

  const apiConsole = apiRequestConsoleTaskHandler(args);
  if (apiConsole !== null && apiConsole !== undefined) {
    return apiConsole;
  }

  return opsApiTextTaskHandler(args);
}

function httpHeaderValue(headers, targetName) {
  const target = targetName.toLowerCase();
  for (const [name, value] of headers) {
    if (String(name).toLowerCase() === target) {
      return String(value);
    }
  }
  return "";
}

function bytesFrom(value) {
  if (value instanceof Uint8Array) {
    return value;
  }
  if (typeof value === "string") {
    return textEncoder.encode(value);
  }
  return Uint8Array.from(value);
}

function encodeHttpString(value) {
  return encodeHttpBytes(textEncoder.encode(value));
}

function decodeHttpString(field, label) {
  try {
    return dynamicTextDecoder.decode(decodeHttpBytes(field, label));
  } catch (err) {
    throw new Error(`malformed HTTP payload ${label}: invalid UTF-8`);
  }
}

function encodeHttpBytes(bytes) {
  return [...bytes].map((byte) => String(byte)).join(",");
}

function decodeHttpBytes(field, label) {
  if (field === "") {
    return new Uint8Array();
  }
  return Uint8Array.from(
    field.split(",").map((part) => {
      const byte = Number(part);
      if (!Number.isInteger(byte) || byte < 0 || byte > 255) {
        throw new Error(`malformed HTTP payload ${label}: invalid byte`);
      }
      return byte;
    }),
  );
}

function parseHttpInteger(field, label) {
  const value = Number(field);
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new Error(`malformed HTTP payload ${label}: invalid integer`);
  }
  return value;
}

function createHttpPayloadReader(lines, expectedVersion, label) {
  let index = 0;
  const read = (fieldLabel) => {
    if (index >= lines.length) {
      throw new Error(`malformed HTTP ${label} payload: missing ${fieldLabel}`);
    }
    const value = lines[index];
    index += 1;
    return value;
  };
  const version = read("version");
  if (version !== expectedVersion) {
    throw new Error(`malformed HTTP ${label} payload: wrong version`);
  }
  return {
    read,
    done() {
      if (index !== lines.length) {
        throw new Error(`malformed HTTP ${label} payload: trailing fields`);
      }
    },
  };
}

export async function instantiateSignalsWasm(url) {
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`failed to fetch ${url}: ${response.status}`);
  }

  const bytes = await response.arrayBuffer();
  const { instance } = await WebAssembly.instantiate(bytes, {});
  return instance;
}

export async function mountSignalsApp({ wasmUrl, root, taskHandler, onError, telemetry }) {
  const instance = await instantiateSignalsWasm(wasmUrl);
  const runtime = new SignalsRuntime(instance.exports, root, { taskHandler, onError, telemetry });
  runtime.mount();
  return runtime;
}

export class SignalsRuntime {
  constructor(exports, root, options = {}) {
    this.exports = exports;
    this.root = root;
    this.checkProtocol();
    this.views = createMemoryViewCache(exports.memory);
    this.nodes = new Map([[0, root]]);
    this.eventCleanups = new Map();
    this.controlledInputs = new Map();
    this.intervals = new Map();
    this.tasks = new Map();
    this.taskHandler = options.taskHandler ?? null;
    this.telemetryLog = normalizeTelemetry(options.telemetry);
    this.telemetrySeq = 0;
    this.pointerProbeCleanups = [];
    this.lastEventResponseBits = 0;
    this.onError = options.onError ?? ((err) => {
      setTimeout(() => {
        throw err;
      }, 0);
    });
    // The patch stream is inspectable: `lastCommands` holds the records drained
    // by the most recent host call so guards can assert the per-event patch
    // budget (mirrors the native host's `patches_emitted` discipline).
    this.lastCommands = [];
    if (this.telemetryLog) {
      this.installPointerProbe();
    }
  }

  checkProtocol() {
    if (typeof this.exports.roc_ui_protocol_version !== "function") {
      throw new Error("Signals wasm export roc_ui_protocol_version is missing");
    }
    if (typeof this.exports.roc_ui_protocol_features !== "function") {
      throw new Error("Signals wasm export roc_ui_protocol_features is missing");
    }
    if (typeof this.exports.roc_ui_dynamic_buffer_ptr !== "function") {
      throw new Error("Signals wasm export roc_ui_dynamic_buffer_ptr is missing");
    }
    if (typeof this.exports.roc_ui_dynamic_buffer_len !== "function") {
      throw new Error("Signals wasm export roc_ui_dynamic_buffer_len is missing");
    }
    const version = this.exports.roc_ui_protocol_version();
    if (version !== Protocol.version) {
      throw new Error(
        `Signals wire protocol version mismatch: runtime expects ${Protocol.version}, wasm exports ${version}`,
      );
    }
    const features = this.exports.roc_ui_protocol_features();
    if ((features & requiredProtocolFeatures) !== requiredProtocolFeatures) {
      throw new Error(
        `Signals wire protocol feature mismatch: runtime requires 0x${requiredProtocolFeatures.toString(16)}, wasm exports 0x${features.toString(16)}`,
      );
    }
  }

  liveHostValues() {
    return this.exports.roc_ui_live_host_values?.() ?? 0;
  }

  mount() {
    this.emitTelemetry("host_call", { call: "mount" });
    this.views.callHost(this.exports.roc_ui_mount);
    this.applyPendingCommands("mount");
  }

  unmount() {
    this.emitTelemetry("host_call", { call: "unmount" });
    this.views.callHost(this.exports.roc_ui_unmount);
    this.applyPendingCommands("unmount");
    this.clearPointerProbe();
    this.clearDom();
  }

  dispatchUnit(eventId) {
    this.dispatch(eventId, PayloadKind.unit, 0, 0, 0);
  }

  dispatchBool(eventId, value) {
    this.dispatch(eventId, PayloadKind.bool, 0, 0, value ? 1 : 0);
  }

  dispatchString(eventId, value) {
    const bytes = textEncoder.encode(value);
    const ptr = this.views.callHost(this.exports.roc_alloc, bytes.length, 1).result;
    let primaryError;
    try {
      this.views.u8.set(bytes, ptr);
      return this.dispatch(eventId, PayloadKind.str, ptr, bytes.length, 0);
    } catch (err) {
      primaryError = err;
      throw err;
    } finally {
      this.deallocEventPayload(ptr, primaryError);
    }
  }

  dispatchBytes(eventId, bytes) {
    const ptr = this.views.callHost(this.exports.roc_alloc, bytes.length, 1).result;
    let primaryError;
    try {
      this.views.u8.set(bytes, ptr);
      return this.dispatch(eventId, PayloadKind.bytes, ptr, bytes.length, 0);
    } catch (err) {
      primaryError = err;
      throw err;
    } finally {
      this.deallocEventPayload(ptr, primaryError);
    }
  }

  deallocEventPayload(ptr, primaryError) {
    try {
      this.views.callHost(this.exports.roc_dealloc, ptr, 1);
    } catch (err) {
      if (primaryError !== undefined) {
        return;
      }
      throw this.runtimeError(err);
    }
  }

  dispatch(eventId, payloadKind, payloadPtr, payloadLen, boolValue) {
    this.emitTelemetry("host_call", {
      call: "event",
      eventId,
      payloadKind: payloadKindName(payloadKind),
      payloadLen,
      boolValue: boolValue !== 0,
    });
    try {
      const eventCall = this.views.callHost(
        this.exports.roc_ui_event,
        eventId,
        payloadKind,
        payloadPtr,
        payloadLen,
        boolValue,
      );
      const responseBits = eventCall.result ?? 0;
      this.lastEventResponseBits = responseBits;
      this.applyPendingCommands(`event:${eventId}`);
      return responseBits;
    } catch (err) {
      throw this.runtimeError(err);
    }
  }

  tickTimer(token) {
    if (!this.intervals.has(token)) {
      this.emitTelemetry("ignored_timer_tick", { token });
      return;
    }
    this.emitTelemetry("host_call", { call: "timer", token });
    this.views.callHost(this.exports.roc_ui_timer, token);
    this.applyPendingCommands(`timer:${token}`);
  }

  resolveTask(requestId, value, failed = false) {
    const bytes = textEncoder.encode(value);
    const ptr = this.views.callHost(this.exports.roc_alloc, bytes.length, 1).result;
    try {
        this.views.u8.set(bytes, ptr);
        this.emitTelemetry("host_call", {
          call: "resolve_task",
          requestId,
          failed: failed !== false,
          payloadLen: bytes.length,
        });
        this.views.callHost(this.exports.roc_ui_resolve, requestId, ptr, bytes.length, failed ? 1 : 0);
    } catch (err) {
      throw this.runtimeError(err);
    } finally {
      this.views.callHost(this.exports.roc_dealloc, ptr, 1);
    }
    this.tasks.delete(requestId);
    this.applyPendingCommands(`resolve:${requestId}`);
  }

  runtimeError(err) {
    const hostMessage = this.lastHostError();
    if (hostMessage === "") {
      return err;
    }
    const message = err?.message ? `${hostMessage}: ${err.message}` : hostMessage;
    const wrapped = new Error(message);
    wrapped.cause = err;
    return wrapped;
  }

  lastHostError() {
    const ptr = this.exports.roc_ui_last_error_ptr?.() ?? 0;
    const len = this.exports.roc_ui_last_error_len?.() ?? 0;
    if (ptr === 0 || len === 0) {
      return "";
    }
    this.views.afterHostCall();
    return textDecoder.decode(this.views.u8.subarray(ptr, ptr + len));
  }

  reportError(err) {
    this.onError(err);
  }

  readPendingCommands() {
    this.views.afterHostCall();
    const words = this.exports.roc_ui_command_record_words();
    const ptr = this.exports.roc_ui_command_buffer_ptr();
    const len = this.exports.roc_ui_command_buffer_len();
    if (ptr === 0 || len === 0) {
      return [];
    }

    const raw = new Uint32Array(this.exports.memory.buffer, ptr, len * words);
    const records = [];
    for (let index = 0; index < len; index += 1) {
      const offset = index * words;
      records.push({
        op: raw[offset],
        a: raw[offset + 1],
        b: raw[offset + 2],
        c: raw[offset + 3],
        d: raw[offset + 4],
        e: raw[offset + 5],
      });
    }
    return records;
  }

  readString(offset, length) {
    if (length === 0) {
      return "";
    }

    this.views.afterHostCall();
    const base = this.exports.roc_ui_string_buffer_ptr();
    const bytes = this.views.u8.subarray(base + offset, base + offset + length);
    return textDecoder.decode(bytes);
  }

  readDynamicBytes(offset, length) {
    this.views.afterHostCall();
    const base = this.exports.roc_ui_dynamic_buffer_ptr();
    const available = this.exports.roc_ui_dynamic_buffer_len();
    if (length === 0) {
      return new Uint8Array(0);
    }
    if (base === 0) {
      throw new Error("dynamic render command referenced an empty dynamic buffer");
    }
    if (offset + length > available) {
      throw new Error(
        `dynamic render command slice ${offset}:${offset + length} exceeds dynamic buffer length ${available}`,
      );
    }
    return this.views.u8.subarray(base + offset, base + offset + length);
  }

  applyPendingCommands(phase = "host-call") {
    const records = this.readPendingCommands();
    this.lastCommands = records;
    this.emitCommandTelemetry(phase, records);
    for (const record of records) {
      this.applyCommand(record);
    }
    this.emitTelemetry("commands_applied", {
      phase,
      count: records.length,
      domNodes: this.nodes.size,
      eventListeners: this.eventCleanups.size,
      liveHostValues: this.liveHostValues(),
    });
    return records;
  }

  applyCommand(record) {
    switch (record.op) {
      case Op.resetDom:
        this.clearDom();
        return;

      case Op.createElement: {
        const elem = document.createElement(this.readString(record.b, record.c));
        this.nodes.set(record.a, elem);
        return;
      }

      case Op.createText: {
        const node = document.createTextNode(this.readString(record.b, record.c));
        this.nodes.set(record.a, node);
        return;
      }

      case Op.appendChild:
        this.node(record.a).appendChild(this.node(record.b));
        return;

      case Op.removeNode: {
        const node = this.node(record.a);
        node.parentNode?.removeChild(node);
        this.clearElemListeners(record.a);
        this.clearControlledInput(record.a);
        this.nodes.delete(record.a);
        return;
      }

      case Op.moveBefore: {
        const parent = this.node(record.a);
        const child = this.node(record.b);
        const before = record.c === 0 ? null : this.node(record.c);
        parent.insertBefore(child, before);
        return;
      }

      case Op.setText:
        setNodeText(this.node(record.a), this.readString(record.b, record.c));
        return;

      case Op.setValue:
        this.applyControlledSetValue(record.a, this.readString(record.b, record.c));
        return;

      case Op.setChecked:
        this.node(record.a).checked = record.b !== 0;
        return;

      case Op.setDisabled:
        this.node(record.a).disabled = record.b !== 0;
        return;

      case Op.setRole:
        setRole(this.node(record.a), this.readString(record.b, record.c));
        return;

      case Op.setLabel:
        this.node(record.a).setAttribute("aria-label", this.readString(record.b, record.c));
        return;

      case Op.setTestId:
        this.node(record.a).setAttribute("data-testid", this.readString(record.b, record.c));
        return;

      case Op.setClass:
        setClass(this.node(record.a), this.readString(record.b, record.c));
        return;

      case Op.bindClick:
        this.applyEventBindCommand(fixedEventCommand(record, "click"));
        return;

      case Op.bindInput:
        this.applyEventBindCommand(fixedEventCommand(record, "input"));
        return;

      case Op.bindCheck:
        this.applyEventBindCommand(fixedEventCommand(record, "change"));
        return;

      case Op.bindPointerDown:
        this.applyEventBindCommand(fixedEventCommand(record, "pointerdown"));
        return;

      case Op.bindPointerUp:
        this.applyEventBindCommand(fixedEventCommand(record, "pointerup"));
        return;

      case Op.bindPointerEnter:
        this.applyEventBindCommand(fixedEventCommand(record, "pointerenter"));
        return;

      case Op.bindPointerLeave:
        this.applyEventBindCommand(fixedEventCommand(record, "pointerleave"));
        return;

      case Op.clearEvent: {
        const domEvent = domEventForKind[record.b];
        if (domEvent === undefined) {
          throw new Error(`unknown clear_event kind ${record.b}`);
        }
        this.clearEvent(record.a, domEvent);
        return;
      }

      case Op.startInterval:
        this.startInterval(record.a, record.b);
        return;

      case Op.cancelInterval:
        this.cancelInterval(record.a);
        return;

      case Op.startTask:
        this.startTask(
          record.a,
          this.readString(record.b, record.c),
          this.readString(record.d, record.e),
        );
        return;

      case Op.cancelTask:
        this.cancelTask(record.a);
        return;

      case Op.extended:
        this.applyDynamicCommand(record.a, record.b);
        return;

      default:
        throw new Error(`unknown render op ${record.op}`);
    }
  }

  applyDynamicCommand(offset, length) {
    const command = this.decodeDynamicCommand(offset, length);
    switch (command.op) {
      case DynamicOp.setAttrText:
        setDynamicTextAttribute(this.node(command.elemId), command.name, command.value);
        return;

      case DynamicOp.removeAttr:
        removeDynamicAttribute(this.node(command.elemId), command.name);
        return;

      case DynamicOp.bindEvent:
        this.applyEventBindCommand(command);
        return;

      case DynamicOp.clearEvent:
        this.clearEvent(command.elemId, command.domEvent);
        return;

      default:
        throw new Error(`unknown dynamic render op ${command.op}`);
    }
  }

  decodeDynamicCommand(offset, length) {
    const bytes = this.readDynamicBytes(offset, length);
    if (bytes.byteLength < 8) {
      throw new Error(
        `malformed dynamic render record at byte ${offset}: header needs 8 bytes, got ${bytes.byteLength}`,
      );
    }

    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const op = view.getUint16(0, true);
    const flags = view.getUint16(2, true);
    const payloadLen = view.getUint32(4, true);
    const totalLen = 8 + align4(payloadLen);
    const opName = dynamicOpName(op);

    if (flags !== 0) {
      throw new Error(
        `malformed dynamic render record at byte ${offset}: ${opName} used unsupported flags 0x${flags.toString(16)}`,
      );
    }
    if (totalLen > bytes.byteLength) {
      throw new Error(
        `malformed dynamic render record at byte ${offset}: ${opName} payload_len ${payloadLen} extends beyond ${bytes.byteLength} bytes`,
      );
    }
    if (totalLen !== bytes.byteLength) {
      throw new Error(
        `malformed dynamic render record at byte ${offset}: ${opName} outer length ${bytes.byteLength} did not match payload_len ${payloadLen}`,
      );
    }

    const cursor = { offset: 8, limit: 8 + payloadLen, recordOffset: offset, opName };
    switch (op) {
      case DynamicOp.setAttrText: {
        const elemId = readDynamicU32(view, cursor, "elem_id");
        const name = readDynamicString(view, cursor, "name");
        const value = readDynamicString(view, cursor, "value");
        assertDynamicPayloadConsumed(cursor);
        return { op, elemId, name, value };
      }

      case DynamicOp.removeAttr: {
        const elemId = readDynamicU32(view, cursor, "elem_id");
        const name = readDynamicString(view, cursor, "name");
        assertDynamicPayloadConsumed(cursor);
        return { op, elemId, name };
      }

      case DynamicOp.bindEvent: {
        const elemId = readDynamicU32(view, cursor, "elem_id");
        const eventId = readDynamicU32(view, cursor, "event_id");
        const eventName = readDynamicString(view, cursor, "event_name");
        const options = readDynamicU32(view, cursor, "options");
        const delivery = readEventDelivery(view, cursor);
        const eventExtractionPlanBytes = readDynamicByteArray(view, cursor, "event_extraction_plan");
        assertDynamicPayloadConsumed(cursor);
        validateListenerOptions(options, cursor);
        const eventExtractionPlan = parseEventExtractionPlan(
          eventExtractionPlanBytes,
          cursor.recordOffset,
          cursor.opName,
        );
        const payloadDescriptor = payloadDescriptorFromEventExtractionPlan(eventExtractionPlan);
        return {
          op,
          binding: dynamicEventBinding(elemId, eventName, eventId, options, delivery, payloadDescriptor),
        };
      }

      case DynamicOp.clearEvent: {
        const elemId = readDynamicU32(view, cursor, "elem_id");
        const eventName = readDynamicString(view, cursor, "event_name");
        assertDynamicPayloadConsumed(cursor);
        return { op, elemId, domEvent: eventName };
      }

      default:
        throw new Error(`unknown dynamic render op ${op} at byte ${offset}`);
    }
  }

  bindEvent(binding) {
    const {
      elemId,
      domEvent,
      eventId,
      options = 0,
      payloadDescriptor,
      preventDefaultForPointerEvents = false,
      installPointerDrag = false,
      useListenerOptions = false,
      includeStaticPolicyTelemetry = false,
    } = binding;
    const delivery = eventDeliveryForBinding(binding);
    const key = `${elemId}:${domEvent}`;
    this.eventCleanups.get(key)?.();
    const elem = this.node(elemId);
    if (domEvent === "input") {
      this.controlledInput(elemId);
    }
    const manualOnce = listenerUsesManualOnce(options);
    const listenerOptions = useListenerOptions
      ? listenerOptionsForAddEventListener(options, { manualOnce })
      : undefined;
    let cleanup = () => {};
    const listener = (event) => {
      const payloadTelemetry = this.telemetryLog
        ? payloadDescriptorTelemetry(payloadDescriptor)
        : null;
      const filter = eventPolicyFilterResult(options, event);
      if (!filter.accepted) {
        if (payloadTelemetry) {
          this.emitTelemetry("dom_event_filtered", {
            domEvent,
            eventId,
            filter: filter.reason,
            listenerOptions: describeListenerOptions(options),
            requestedDelivery: delivery.requested,
            effectiveDelivery: delivery.effective,
            deliveryReason: delivery.reason,
            ...payloadTelemetry,
            currentTarget: describeDomNode(event.currentTarget, elemId),
            target: describeDomNode(event.target),
          });
        }
        return;
      }
      if (manualOnce) {
        cleanup();
      }
      const policy = applyEventListenerPolicy(options, domEvent, event, {
        preventDefaultForPointerEvents,
      });
      if (payloadTelemetry) {
        this.emitTelemetry("dom_event", {
          domEvent,
          eventId,
          requestedDelivery: delivery.requested,
          effectiveDelivery: delivery.effective,
          deliveryReason: delivery.reason,
          ...listenerPolicyTelemetry(options, policy, includeStaticPolicyTelemetry),
          ...payloadTelemetry,
          currentTarget: describeDomNode(event.currentTarget, elemId),
          target: describeDomNode(event.target),
          pointer: describePointerEvent(event),
        });
      }
      this.dispatchEventPayload(eventId, payloadDescriptor, event, payloadTelemetry);
    };
    cleanup = () => elem.removeEventListener(domEvent, listener, listenerOptions);
    if (listenerOptions === undefined) {
      elem.addEventListener(domEvent, listener);
    } else {
      elem.addEventListener(domEvent, listener, listenerOptions);
    }
    this.eventCleanups.set(key, cleanup);
    elem.dataset.rocEventId = String(eventId);
    if (installPointerDrag) {
      elem.dataset.rocPointerDrag = "true";
      elem.draggable = false;
      if (elem.style) {
        elem.style.userSelect = "none";
        elem.style.webkitUserSelect = "none";
        elem.style.touchAction = "none";
      }
    }
    if (this.telemetryLog) {
      this.emitTelemetry("bind_event", {
        elemId,
        domEvent,
        eventId,
        requestedDelivery: delivery.requested,
        effectiveDelivery: delivery.effective,
        deliveryReason: delivery.reason,
        ...(includeStaticPolicyTelemetry
          ? { listenerOptions: describeListenerOptions(options) }
          : {}),
        ...payloadDescriptorTelemetry(payloadDescriptor),
        elem: describeDomNode(elem, elemId),
      });
    }
  }

  applyEventBindCommand(command) {
    this.bindEvent(command.binding);
  }

  dispatchEventPayload(eventId, payloadDescriptor, event, payloadTelemetry = null) {
    const { payloadKind, eventExtractionPlan } = payloadDescriptor;
    switch (payloadKind) {
      case PayloadKind.unit:
        try {
          extractBoundaryPayloadValue(eventExtractionPlan, event);
        } catch (err) {
          this.emitEventPayloadError(eventId, payloadDescriptor, event, err);
          throw err;
        }
        this.emitEventPayloadTelemetry(eventId, payloadDescriptor, payloadTelemetry, {});
        this.dispatchUnit(eventId);
        return;

      case PayloadKind.str: {
        let value;
        try {
          value = extractBoundaryPayloadValue(eventExtractionPlan, event);
          if (typeof value !== "string") {
            throw new Error("event extraction plan produced a non-text value for str payload");
          }
        } catch (err) {
          this.emitEventPayloadError(eventId, payloadDescriptor, event, err);
          throw err;
        }
        this.emitEventPayloadTelemetry(eventId, payloadDescriptor, payloadTelemetry, { value });
        this.dispatchString(eventId, value);
        return;
      }

      case PayloadKind.bool: {
        let value;
        try {
          value = extractBoundaryPayloadValue(eventExtractionPlan, event);
          if (typeof value !== "boolean") {
            throw new Error("event extraction plan produced a non-bool value for bool payload");
          }
        } catch (err) {
          this.emitEventPayloadError(eventId, payloadDescriptor, event, err);
          throw err;
        }
        this.emitEventPayloadTelemetry(eventId, payloadDescriptor, payloadTelemetry, { value });
        this.dispatchBool(eventId, value);
        return;
      }

      case PayloadKind.bytes: {
        let bytes;
        try {
          bytes = encodeBoundaryPayloadBytes(eventExtractionPlan, event);
        } catch (err) {
          this.emitEventPayloadError(eventId, payloadDescriptor, event, err);
          throw err;
        }
        this.emitEventPayloadTelemetry(eventId, payloadDescriptor, payloadTelemetry, {
          byteLength: bytes.length,
        });
        this.dispatchBytes(eventId, bytes);
        return;
      }

      default:
        throw new Error(`unknown event payload kind ${payloadKind}`);
    }
  }

  emitEventPayloadTelemetry(eventId, payloadDescriptor, payloadTelemetry, detail) {
    if (!this.telemetryLog) {
      return;
    }
    this.emitTelemetry("event_payload", {
      eventId,
      ...(payloadTelemetry ?? payloadDescriptorTelemetry(payloadDescriptor)),
      ...detail,
    });
  }

  emitEventPayloadError(eventId, payloadDescriptor, event, err) {
    if (!this.telemetryLog) {
      return;
    }
    this.emitTelemetry("event_payload_error", {
      eventId,
      ...payloadDescriptorTelemetry(payloadDescriptor),
      message: err?.message ?? String(err),
      currentTarget: describeDomNode(event.currentTarget),
      target: describeDomNode(event.target),
    });
  }

  clearEvent(elemId, domEvent) {
    const key = `${elemId}:${domEvent}`;
    const cleanup = this.eventCleanups.get(key);
    if (!cleanup) {
      return;
    }
    cleanup();
    this.eventCleanups.delete(key);
    const elem = this.nodes.get(elemId);
    if (elem && elem.dataset) {
      delete elem.dataset.rocEventId;
      if (domEvent === "pointerdown") {
        delete elem.dataset.rocPointerDrag;
      }
    }
    if (elem && domEvent === "pointerdown" && elem.style) {
      elem.style.userSelect = "";
      elem.style.webkitUserSelect = "";
      elem.style.touchAction = "";
    }
    this.emitTelemetry("clear_event", {
      elemId,
      domEvent,
      elem: describeDomNode(elem, elemId),
    });
  }

  clearElemListeners(elemId) {
    const prefix = `${elemId}:`;
    for (const key of this.eventCleanups.keys()) {
      if (key.startsWith(prefix)) {
        this.eventCleanups.get(key)();
        this.eventCleanups.delete(key);
      }
    }
  }

  controlledInput(elemId) {
    const existing = this.controlledInputs.get(elemId);
    if (existing) {
      return existing;
    }

    const elem = this.node(elemId);
    const state = createControlledInputState(elem.value ?? "");
    const syncFromDom = () => {
      userInput(
        state,
        elem.value ?? "",
        elem.selectionStart ?? String(elem.value ?? "").length,
        elem.selectionEnd ?? elem.selectionStart ?? String(elem.value ?? "").length,
      );
    };
    const writeToDom = (op) => {
      if (op.status === "wrote") {
        elem.value = state.value;
      }
      this.emitTelemetry("controlled_input", {
        elemId,
        status: op.status,
        reason: op.reason,
        pendingValue: op.pendingValue,
        focused: op.focused,
        composing: op.composing,
      });
    };
    const listeners = [
      [
        "focus",
        () => {
          focusInput(
            state,
            elem.selectionStart ?? String(elem.value ?? "").length,
            elem.selectionEnd ?? elem.selectionStart ?? String(elem.value ?? "").length,
          );
        },
      ],
      [
        "blur",
        () => {
          writeToDom(blurInput(state));
        },
      ],
      [
        "compositionstart",
        () => {
          syncFromDom();
          beginComposition(state);
        },
      ],
      [
        "compositionend",
        () => {
          syncFromDom();
          writeToDom(endComposition(state));
        },
      ],
      [
        "input",
        () => {
          syncFromDom();
        },
      ],
    ];

    for (const [type, listener] of listeners) {
      elem.addEventListener(type, listener);
    }

    const entry = {
      state,
      writeToDom,
      cleanup() {
        for (const [type, listener] of listeners) {
          elem.removeEventListener(type, listener);
        }
      },
    };
    this.controlledInputs.set(elemId, entry);
    return entry;
  }

  applyControlledSetValue(elemId, value) {
    const entry = this.controlledInput(elemId);
    entry.writeToDom(applySetValue(entry.state, value));
  }

  clearControlledInput(elemId) {
    const entry = this.controlledInputs.get(elemId);
    if (!entry) {
      return;
    }
    entry.cleanup();
    this.controlledInputs.delete(elemId);
  }

  clearControlledInputs() {
    for (const entry of this.controlledInputs.values()) {
      entry.cleanup();
    }
    this.controlledInputs.clear();
  }

  startInterval(token, periodMs) {
    this.cancelInterval(token);
    const id = setInterval(() => this.tickTimer(token), periodMs);
    this.intervals.set(token, id);
  }

  cancelInterval(token) {
    const id = this.intervals.get(token);
    if (id === undefined) {
      return;
    }
    clearInterval(id);
    this.intervals.delete(token);
  }

  startTask(requestId, name, request) {
    this.cancelTask(requestId);
    const controller = new AbortController();
    this.tasks.set(requestId, { name, request, controller });
    this.emitTelemetry("start_task", { requestId, name, request });
    if (!this.taskHandler) {
      return;
    }

    let handled;
    try {
      handled = this.taskHandler({ requestId, name, request, signal: controller.signal });
    } catch (err) {
      handled = Promise.reject(err);
    }
    if (handled === null || handled === undefined) {
      return;
    }

    Promise.resolve(handled).then(
      (value) => {
        if (!controller.signal.aborted && this.tasks.has(requestId)) {
          try {
            this.resolveTask(requestId, String(value), false);
          } catch (err) {
            this.reportError(err);
          }
        }
      },
      (err) => {
        if (!controller.signal.aborted && this.tasks.has(requestId)) {
          try {
            this.resolveTask(requestId, String(err?.message ?? err), true);
          } catch (resolveErr) {
            this.reportError(resolveErr);
          }
        }
      },
    );
  }

  cancelTask(requestId) {
    const task = this.tasks.get(requestId);
    if (!task) {
      return;
    }
    task.controller.abort();
    this.tasks.delete(requestId);
    this.emitTelemetry("cancel_task", {
      requestId,
      name: task.name,
      request: task.request,
    });
  }

  clearAsyncResources() {
    for (const token of [...this.intervals.keys()]) {
      this.cancelInterval(token);
    }
    for (const requestId of [...this.tasks.keys()]) {
      this.cancelTask(requestId);
    }
  }

  node(id) {
    const node = this.nodes.get(id);
    if (!node) {
      throw new Error(`unknown DOM node id ${id}`);
    }
    return node;
  }

  clearDom() {
    this.emitTelemetry("clear_dom", {
      domNodes: this.nodes.size,
      eventListeners: this.eventCleanups.size,
      intervals: this.intervals.size,
      tasks: this.tasks.size,
    });
    this.clearAsyncResources();
    for (const cleanup of this.eventCleanups.values()) {
      cleanup();
    }
    this.eventCleanups.clear();
    this.clearControlledInputs();
    this.nodes.clear();
    this.nodes.set(0, this.root);
    this.root.replaceChildren();
  }

  emitTelemetry(kind, detail = {}) {
    if (!this.telemetryLog) {
      return;
    }
    this.telemetryLog({
      source: "signals-runtime",
      seq: ++this.telemetrySeq,
      timeMs: Date.now(),
      kind,
      ...detail,
    });
  }

  emitCommandTelemetry(phase, records) {
    if (!this.telemetryLog) {
      return;
    }
    const commands = records.map((record) => this.describeCommand(record));
    const opCounts = {};
    for (const command of commands) {
      opCounts[command.op] = (opCounts[command.op] ?? 0) + 1;
    }
    this.emitTelemetry("commands", {
      phase,
      count: records.length,
      fixedRecordBytes: records.length * this.exports.roc_ui_command_record_words() * 4,
      fixedStringBytes: this.exports.roc_ui_string_buffer_len(),
      dynamicBytes: this.exports.roc_ui_dynamic_buffer_len(),
      opCounts,
      commands,
    });
  }

  describeCommand(record) {
    const op = opName(record.op);
    switch (record.op) {
      case Op.resetDom:
        return { op };

      case Op.createElement:
        return { op, elemId: record.a, tag: this.readString(record.b, record.c) };

      case Op.createText:
        return { op, nodeId: record.a, text: this.readString(record.b, record.c) };

      case Op.appendChild:
        return { op, parentId: record.a, childId: record.b };

      case Op.removeNode:
        return { op, nodeId: record.a, node: describeDomNode(this.nodes.get(record.a), record.a) };

      case Op.moveBefore:
        return { op, parentId: record.a, childId: record.b, beforeId: record.c };

      case Op.setText:
        return { op, nodeId: record.a, text: this.readString(record.b, record.c) };

      case Op.setValue:
        return { op, elemId: record.a, value: this.readString(record.b, record.c) };

      case Op.setChecked:
        return { op, elemId: record.a, checked: record.b !== 0 };

      case Op.setDisabled:
        return { op, elemId: record.a, disabled: record.b !== 0 };

      case Op.setRole:
        return { op, elemId: record.a, role: this.readString(record.b, record.c) };

      case Op.setLabel:
        return { op, elemId: record.a, label: this.readString(record.b, record.c) };

      case Op.setTestId:
        return { op, elemId: record.a, testId: this.readString(record.b, record.c) };

      case Op.setClass:
        return { op, elemId: record.a, className: this.readString(record.b, record.c) };

      case Op.bindClick:
        return this.describeEventBindCommand(op, fixedEventCommand(record, "click").binding);

      case Op.bindInput:
        return this.describeEventBindCommand(op, fixedEventCommand(record, "input").binding);

      case Op.bindCheck:
        return this.describeEventBindCommand(op, fixedEventCommand(record, "change").binding);

      case Op.bindPointerDown:
        return this.describeEventBindCommand(op, fixedEventCommand(record, "pointerdown").binding);

      case Op.bindPointerUp:
        return this.describeEventBindCommand(op, fixedEventCommand(record, "pointerup").binding);

      case Op.bindPointerEnter:
        return this.describeEventBindCommand(op, fixedEventCommand(record, "pointerenter").binding);

      case Op.bindPointerLeave:
        return this.describeEventBindCommand(op, fixedEventCommand(record, "pointerleave").binding);

      case Op.clearEvent:
        return {
          op,
          elemId: record.a,
          domEvent: domEventForKind[record.b],
          eventKind: record.b,
        };

      case Op.startInterval:
        return { op, token: record.a, periodMs: record.b };

      case Op.cancelInterval:
        return { op, token: record.a };

      case Op.startTask:
        return {
          op,
          requestId: record.a,
          name: this.readString(record.b, record.c),
          request: this.readString(record.d, record.e),
        };

      case Op.cancelTask:
        return { op, requestId: record.a };

      case Op.extended:
        return this.describeDynamicCommand(record.a, record.b);

      default:
        return { op, raw: { ...record } };
    }
  }

  describeDynamicCommand(offset, length) {
    const command = this.decodeDynamicCommand(offset, length);
    switch (command.op) {
      case DynamicOp.setAttrText:
        return {
          op: dynamicOpName(command.op),
          elemId: command.elemId,
          name: command.name,
          value: command.value,
        };

      case DynamicOp.removeAttr:
        return {
          op: dynamicOpName(command.op),
          elemId: command.elemId,
          name: command.name,
        };

      case DynamicOp.bindEvent:
        return this.describeEventBindCommand(dynamicOpName(command.op), command.binding);

      case DynamicOp.clearEvent:
        return {
          op: dynamicOpName(command.op),
          elemId: command.elemId,
          domEvent: command.domEvent,
        };

      default:
        return { op: dynamicOpName(command.op), offset, length };
    }
  }

  describeEventBindCommand(op, binding) {
    return compactObject({
      op,
      elemId: binding.elemId,
      domEvent: binding.domEvent,
      eventId: binding.eventId,
      options: binding.includeStaticPolicyTelemetry
        ? describeListenerOptions(binding.options)
        : undefined,
      payloadKind: payloadKindName(binding.payloadDescriptor.payloadKind),
      eventExtractionPlan: describeEventExtractionPlan(binding.payloadDescriptor.eventExtractionPlan),
    });
  }

  installPointerProbe() {
    if (typeof globalThis.document?.addEventListener !== "function") {
      return;
    }
    for (const domEvent of pointerProbeEvents) {
      const listener = (event) => {
        this.emitTelemetry("pointer_probe", {
          domEvent,
          target: describeDomNode(event.target),
          currentTarget: describeDomNode(event.currentTarget),
          pointer: describePointerEvent(event),
        });
      };
      globalThis.document.addEventListener(domEvent, listener, true);
      this.pointerProbeCleanups.push(() =>
        globalThis.document.removeEventListener(domEvent, listener, true),
      );
    }
    this.emitTelemetry("pointer_probe_installed", { events: [...pointerProbeEvents] });
  }

  clearPointerProbe() {
    for (const cleanup of this.pointerProbeCleanups) {
      cleanup();
    }
    this.pointerProbeCleanups = [];
  }
}

function normalizeTelemetry(telemetry) {
  if (telemetry === undefined || telemetry === null || telemetry === false) {
    return null;
  }
  if (telemetry === true) {
    return consoleTelemetry;
  }
  if (typeof telemetry === "function") {
    return telemetry;
  }
  if (typeof telemetry.log === "function") {
    return (entry) => telemetry.log(entry);
  }
  throw new TypeError("SignalsRuntime telemetry must be true, a function, or an object with log(entry)");
}

function consoleTelemetry(entry) {
  console.log(`[signals] ${JSON.stringify(entry)}`);
}

function opName(op) {
  return opNames[op] ?? `unknown:${op}`;
}

function dynamicOpName(op) {
  return dynamicOpNames[op] ?? `unknown:${op}`;
}

function payloadKindName(kind) {
  return payloadKindNames[kind] ?? `unknown:${kind}`;
}

function payloadDescriptorFromEventExtractionPlan(eventExtractionPlan) {
  const boundarySchema = boundarySchemaFromEventExtractionPlan(eventExtractionPlan);
  return {
    boundarySchema,
    payloadKind: payloadKindForBoundarySchema(boundarySchema),
    eventExtractionPlan,
  };
}

function fixedEventCommand(record, domEvent) {
  return {
    op: record.op,
    binding: fixedEventBinding(record.a, domEvent, record.b, record.op),
  };
}

function fixedEventBinding(elemId, domEvent, eventId, op) {
  return {
    elemId,
    domEvent,
    eventId,
    options: 0,
    payloadDescriptor: fixedEventPayloadDescriptorForOp(op),
    preventDefaultForPointerEvents: fixedEventPreventsPointerDefault(op),
    installPointerDrag: op === Op.bindPointerDown,
  };
}

function dynamicEventBinding(elemId, domEvent, eventId, options, delivery, payloadDescriptor) {
  return {
    elemId,
    domEvent,
    eventId,
    options,
    delivery,
    payloadDescriptor,
    useListenerOptions: true,
    includeStaticPolicyTelemetry: true,
  };
}

function eventDeliveryForBinding(binding) {
  if (binding.delivery !== undefined) {
    return binding.delivery;
  }
  const requested = EventDelivery.auto;
  if (requested === EventDelivery.native) {
    return { requested, effective: EventDelivery.native, reason: "requested-native" };
  }
  if (requested !== EventDelivery.auto) {
    throw new Error(`unsupported event delivery request ${String(requested)}`);
  }
  return {
    requested,
    effective: EventDelivery.native,
    reason: nativeDeliveryReasonForBinding(binding),
  };
}

function nativeDeliveryReasonForBinding(binding) {
  const options = binding.options ?? 0;
  if ((options & ListenerOptions.capture) !== 0) {
    return "capture-policy";
  }
  if ((options & ListenerOptions.stopImmediatePropagation) !== 0) {
    return "stop-immediate-policy";
  }
  if ((options & ListenerOptions.stopPropagation) !== 0) {
    return "stop-propagation-policy";
  }
  if (binding.installPointerDrag) {
    return "pointer-drag";
  }
  if ((options & ListenerOptions.preventDefault) !== 0 || binding.preventDefaultForPointerEvents) {
    return "prevent-default-policy";
  }
  if ((options & ListenerOptions.once) !== 0) {
    return "once-policy";
  }
  if ((options & ListenerOptions.passive) !== 0) {
    return "passive-policy";
  }
  if ((options & ListenerOptions.self) !== 0) {
    return "self-filter";
  }
  return "native-runtime-default";
}

function fixedEventPayloadDescriptorForOp(op) {
  switch (op) {
    case Op.bindClick:
    case Op.bindPointerDown:
    case Op.bindPointerUp:
    case Op.bindPointerEnter:
    case Op.bindPointerLeave:
      return payloadDescriptorFromEventExtractionPlan(fixedEventExtractionPlan.unit);

    case Op.bindInput:
      return payloadDescriptorFromEventExtractionPlan(fixedEventExtractionPlan.targetValue);

    case Op.bindCheck:
      return payloadDescriptorFromEventExtractionPlan(fixedEventExtractionPlan.targetChecked);

    default:
      throw new Error(`render op ${opName(op)} is not a fixed event bind`);
  }
}

function fixedEventPreventsPointerDefault(op) {
  switch (op) {
    case Op.bindPointerDown:
    case Op.bindPointerUp:
    case Op.bindPointerEnter:
    case Op.bindPointerLeave:
      return true;

    default:
      return false;
  }
}

function payloadDescriptorTelemetry(payloadDescriptor) {
  return {
    payloadKind: payloadKindName(payloadDescriptor.payloadKind),
    boundarySchema: describeBoundarySchema(payloadDescriptor.boundarySchema),
    eventExtractionPlan: describeEventExtractionPlan(payloadDescriptor.eventExtractionPlan),
  };
}

function validateListenerOptions(options, cursor) {
  const unknown = options & ~knownListenerOptionMask;
  if (unknown === 0) {
    return;
  }
  throw new Error(
    `malformed dynamic render record at byte ${cursor.recordOffset}: ${cursor.opName} used unsupported listener option bits 0x${unknown.toString(16)}`,
  );
}

function readEventDelivery(view, cursor) {
  return {
    requested: readEventDeliveryName(
      eventDeliveryRequestNames,
      readDynamicU32(view, cursor, "delivery_requested"),
      "delivery_requested",
      cursor,
    ),
    effective: readEventDeliveryName(
      eventDeliveryEffectiveNames,
      readDynamicU32(view, cursor, "delivery_effective"),
      "delivery_effective",
      cursor,
    ),
    reason: readEventDeliveryName(
      eventDeliveryReasonNames,
      readDynamicU32(view, cursor, "delivery_reason"),
      "delivery_reason",
      cursor,
    ),
  };
}

function readEventDeliveryName(names, id, field, cursor) {
  const name = names[id];
  if (name !== undefined) {
    return name;
  }
  throw new Error(
    `malformed dynamic render record at byte ${cursor.recordOffset}: ${cursor.opName} used unknown ${field} id ${id}`,
  );
}

function listenerOptionsForAddEventListener(options, { manualOnce = false } = {}) {
  return {
    capture: (options & ListenerOptions.capture) !== 0,
    passive: (options & ListenerOptions.passive) !== 0,
    once: (options & ListenerOptions.once) !== 0 && !manualOnce,
  };
}

function listenerUsesManualOnce(options) {
  return (
    (options & ListenerOptions.once) !== 0 &&
    (options & (ListenerOptions.self | ListenerOptions.trusted)) !== 0
  );
}

function applyStaticListenerPolicy(options, event) {
  let preventedDefault = false;
  let stoppedPropagation = false;
  let stoppedImmediatePropagation = false;
  if ((options & ListenerOptions.preventDefault) !== 0) {
    if (typeof event?.preventDefault !== "function") {
      throw new Error("event listener requested preventDefault but event has no preventDefault method");
    }
    event.preventDefault();
    preventedDefault = true;
  }
  if ((options & ListenerOptions.stopPropagation) !== 0) {
    if (typeof event?.stopPropagation !== "function") {
      throw new Error("event listener requested stopPropagation but event has no stopPropagation method");
    }
    event.stopPropagation();
    stoppedPropagation = true;
  }
  if ((options & ListenerOptions.stopImmediatePropagation) !== 0) {
    if (typeof event?.stopImmediatePropagation !== "function") {
      throw new Error("event listener requested stopImmediatePropagation but event has no stopImmediatePropagation method");
    }
    event.stopImmediatePropagation();
    stoppedPropagation = true;
    stoppedImmediatePropagation = true;
  }
  return { preventedDefault, stoppedPropagation, stoppedImmediatePropagation };
}

function eventPolicyFilterResult(options, event) {
  if ((options & ListenerOptions.self) !== 0 && event?.target !== event?.currentTarget) {
    return { accepted: false, reason: "self" };
  }
  if ((options & ListenerOptions.trusted) !== 0 && event?.isTrusted !== true) {
    return { accepted: false, reason: "trusted" };
  }
  return { accepted: true };
}

function applyEventListenerPolicy(options, domEvent, event, policy) {
  const result = applyStaticListenerPolicy(options, event);
  if (policy.preventDefaultForPointerEvents && !result.preventedDefault) {
    result.preventedDefault = preventDefaultForRocEvent(domEvent, event);
  }
  return result;
}

function listenerPolicyTelemetry(options, policy, includeStaticPolicyTelemetry) {
  if (includeStaticPolicyTelemetry) {
    return {
      listenerOptions: describeListenerOptions(options),
      preventedDefault: policy.preventedDefault,
      stoppedPropagation: policy.stoppedPropagation,
      stoppedImmediatePropagation: policy.stoppedImmediatePropagation,
    };
  }
  return {
    preventedDefault: policy.preventedDefault,
  };
}

function describeListenerOptions(options) {
  return compactObject({
    preventDefault: (options & ListenerOptions.preventDefault) !== 0,
    stopPropagation: (options & ListenerOptions.stopPropagation) !== 0,
    stopImmediatePropagation: (options & ListenerOptions.stopImmediatePropagation) !== 0,
    capture: (options & ListenerOptions.capture) !== 0,
    passive: (options & ListenerOptions.passive) !== 0,
    once: (options & ListenerOptions.once) !== 0,
    self: (options & ListenerOptions.self) !== 0,
    trusted: (options & ListenerOptions.trusted) !== 0,
  });
}

function parseEventExtractionPlan(bytes, recordOffset, opName) {
  const cursor = { offset: 0, limit: bytes.length, recordOffset, opName };
  const plan = parseEventExtractionPlanNode(bytes, cursor);
  if (cursor.offset !== cursor.limit) {
    throw malformedEventExtractionPlan(
      cursor,
      `left ${cursor.limit - cursor.offset} trailing byte(s)`,
    );
  }
  return plan;
}

function parseEventExtractionPlanNode(bytes, cursor) {
  const tag = readEventExtractionPlanU8(bytes, cursor, "tag");
  switch (tag) {
    case BoundarySchemaTag.unit:
      return { kind: "unit" };

    case BoundarySchemaTag.text:
      return parseEventScalarExtraction(bytes, cursor, "text");

    case BoundarySchemaTag.bool:
      return parseEventScalarExtraction(bytes, cursor, "bool");

    case BoundarySchemaTag.record:
      return parseBoundaryRecordNode(bytes, cursor, parseEventExtractionPlanNode);

    default:
      throw malformedEventExtractionPlan(cursor, `unknown shape tag ${tag}`);
  }
}

function parseBoundaryRecordNode(bytes, cursor, parseNode) {
  const fieldCount = readEventExtractionPlanU8(bytes, cursor, "record_field_count");
  if (fieldCount === 0) {
    throw malformedEventExtractionPlan(cursor, "record field count was zero");
  }
  const fields = [];
  const names = new Set();
  for (let i = 0; i < fieldCount; i += 1) {
    const nameLen = readEventExtractionPlanU8(bytes, cursor, "record_field_name_len");
    if (nameLen === 0) {
      throw malformedEventExtractionPlan(cursor, "record field name was empty");
    }
    ensureEventExtractionPlanAvailable(cursor, nameLen, "record_field_name");
    const nameBytes = bytes.subarray(cursor.offset, cursor.offset + nameLen);
    cursor.offset += nameLen;
    let name;
    try {
      name = dynamicTextDecoder.decode(nameBytes);
    } catch (err) {
      throw malformedEventExtractionPlan(cursor, "record field name was not valid UTF-8", err);
    }
    if (names.has(name)) {
      throw malformedEventExtractionPlan(cursor, `record field "${name}" was duplicated`);
    }
    names.add(name);
    const spec = parseNode(bytes, cursor);
    if (spec.kind === "record") {
      throw malformedEventExtractionPlan(cursor, `record field "${name}" used a nested record shape`);
    }
    fields.push({ name, spec });
  }
  return { kind: "record", fields };
}

function parseEventScalarExtraction(bytes, cursor, kind) {
  const source = readEventExtractionPlanU8(bytes, cursor, `${kind}_source`);
  const leaf = readEventExtractionPlanU8(bytes, cursor, `${kind}_leaf`);
  validateEventExtractionSource(source, cursor);
  validateEventExtractionLeaf(kind, leaf, cursor);
  validateEventExtractionSourceLeaf(source, leaf, cursor);
  return { kind, source, leaf };
}

function ensureEventExtractionPlanAvailable(cursor, byteCount, field) {
  if (cursor.offset + byteCount <= cursor.limit) {
    return;
  }
  throw malformedEventExtractionPlan(cursor, `${field} extends beyond extraction plan length`);
}

function readEventExtractionPlanU8(bytes, cursor, field) {
  ensureEventExtractionPlanAvailable(cursor, 1, field);
  const value = bytes[cursor.offset];
  cursor.offset += 1;
  return value;
}

function validateEventExtractionSource(source, cursor) {
  if (
    source === EventExtractionSource.event ||
    source === EventExtractionSource.target ||
    source === EventExtractionSource.currentTarget
  ) {
    return;
  }
  throw malformedEventExtractionPlan(cursor, `unknown event extraction source tag ${source}`);
}

function validateEventExtractionLeaf(kind, leaf, cursor) {
  if (kind === "text" && (leaf === EventExtractionLeaf.key || leaf === EventExtractionLeaf.value)) {
    return;
  }
  if (kind === "bool" && (leaf === EventExtractionLeaf.checked || leaf === EventExtractionLeaf.shiftKey)) {
    return;
  }
  throw malformedEventExtractionPlan(cursor, `${kind} event extraction used incompatible leaf tag ${leaf}`);
}

function validateEventExtractionSourceLeaf(source, leaf, cursor) {
  if (
    (leaf === EventExtractionLeaf.key || leaf === EventExtractionLeaf.shiftKey) &&
    source === EventExtractionSource.event
  ) {
    return;
  }
  if (
    (leaf === EventExtractionLeaf.value || leaf === EventExtractionLeaf.checked) &&
    (source === EventExtractionSource.target || source === EventExtractionSource.currentTarget)
  ) {
    return;
  }
  throw malformedEventExtractionPlan(cursor, `event extraction source tag ${source} cannot produce leaf tag ${leaf}`);
}

function malformedEventExtractionPlan(cursor, message, cause = undefined) {
  return new Error(
    `malformed event extraction plan at byte ${cursor.recordOffset}: ${cursor.opName} ${message}`,
    cause === undefined ? undefined : { cause },
  );
}

function boundarySchemaFromEventExtractionPlan(spec) {
  switch (spec.kind) {
    case "unit":
    case "text":
    case "bool":
      return { kind: spec.kind };
    case "record":
      return {
        kind: "record",
        fields: spec.fields.map((field) => ({
          name: field.name,
          spec: boundarySchemaFromEventExtractionPlan(field.spec),
        })),
      };
    default:
      throw new Error(`unknown event extraction plan kind ${spec.kind}`);
  }
}

function payloadKindForBoundarySchema(spec) {
  switch (spec.kind) {
    case "unit":
      return PayloadKind.unit;
    case "text":
      return PayloadKind.str;
    case "bool":
      return PayloadKind.bool;
    case "record":
      return PayloadKind.bytes;
    default:
      throw new Error(`unknown boundary schema kind ${spec.kind}`);
  }
}

function extractBoundaryPayloadValue(spec, event) {
  switch (spec.kind) {
    case "unit":
      return undefined;
    case "text": {
      const value = readEventExtractionLeaf(spec, event);
      if (typeof value !== "string") {
        throw new Error("event extraction text leaf did not yield a string");
      }
      return value;
    }
    case "bool": {
      const value = readEventExtractionLeaf(spec, event);
      if (typeof value !== "boolean") {
        throw new Error("event extraction bool leaf did not yield a boolean");
      }
      return value;
    }
    case "record":
      return spec.fields.map((field) => [field.name, extractBoundaryPayloadValue(field.spec, event)]);
    default:
      throw new Error(`unknown boundary schema kind ${spec.kind}`);
  }
}

function encodeBoundaryPayloadBytes(spec, event) {
  const chunks = [];
  let totalLen = 0;
  const push = (bytes) => {
    chunks.push(bytes);
    totalLen += bytes.length;
  };
  writeBoundaryPayloadBytes(spec, event, push);
  const out = new Uint8Array(totalLen);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.length;
  }
  return out;
}

function writeBoundaryPayloadBytes(spec, event, push) {
  switch (spec.kind) {
    case "unit":
      return;
    case "text": {
      const bytes = textEncoder.encode(extractBoundaryPayloadValue(spec, event));
      const len = new Uint8Array(4);
      new DataView(len.buffer).setUint32(0, bytes.length, true);
      push(len);
      push(bytes);
      return;
    }
    case "bool":
      push(new Uint8Array([extractBoundaryPayloadValue(spec, event) ? 1 : 0]));
      return;
    case "record":
      for (const field of spec.fields) {
        writeBoundaryPayloadBytes(field.spec, event, push);
      }
      return;
    default:
      throw new Error(`unknown boundary schema kind ${spec.kind}`);
  }
}

function describeBoundarySchema(spec) {
  switch (spec.kind) {
    case "unit":
    case "text":
    case "bool":
      return spec.kind;
    case "record":
      return `{ ${spec.fields
        .map((field) => `${field.name}: ${describeBoundarySchema(field.spec)}`)
        .join(", ")} }`;
    default:
      return `unknown:${spec.kind}`;
  }
}

function readEventExtractionLeaf(spec, event) {
  const source = eventExtractionSourceObject(spec.source, event);
  const property = eventExtractionLeafProperty(spec.leaf);
  return source?.[property];
}

function eventExtractionSourceObject(source, event) {
  switch (source) {
    case EventExtractionSource.event:
      return event;
    case EventExtractionSource.target:
      return event.target;
    case EventExtractionSource.currentTarget:
      return event.currentTarget;
    default:
      throw new Error(`unknown event extraction source ${source}`);
  }
}

function eventExtractionLeafProperty(leaf) {
  switch (leaf) {
    case EventExtractionLeaf.key:
      return "key";
    case EventExtractionLeaf.value:
      return "value";
    case EventExtractionLeaf.checked:
      return "checked";
    case EventExtractionLeaf.shiftKey:
      return "shiftKey";
    default:
      throw new Error(`unknown event extraction leaf ${leaf}`);
  }
}

function describeEventExtractionPlan(spec) {
  switch (spec.kind) {
    case "unit":
      return "unit";
    case "text":
    case "bool":
      return `${spec.kind}:${eventExtractionSourceName(spec.source)}.${eventExtractionLeafProperty(spec.leaf)}`;
    case "record":
      return `{ ${spec.fields
        .map((field) => `${field.name}: ${describeEventExtractionPlan(field.spec)}`)
        .join(", ")} }`;
    default:
      return `unknown:${spec.kind}`;
  }
}

function eventExtractionSourceName(source) {
  switch (source) {
    case EventExtractionSource.event:
      return "event";
    case EventExtractionSource.target:
      return "target";
    case EventExtractionSource.currentTarget:
      return "currentTarget";
    default:
      return `unknown:${source}`;
  }
}

function preventDefaultForRocEvent(domEvent, event) {
  if (!domEvent.startsWith("pointer")) {
    return false;
  }
  if (typeof event?.preventDefault !== "function") {
    return false;
  }
  event.preventDefault();
  return true;
}

function setNodeText(node, value) {
  if (node.nodeType === Node.TEXT_NODE) {
    node.nodeValue = value;
  } else {
    node.textContent = value;
  }
}

function describeDomNode(node, id = undefined) {
  if (!node) {
    return null;
  }
  if (node.nodeType === Node.TEXT_NODE) {
    return compactObject({
      id,
      type: "text",
      text: compactText(node.nodeValue),
    });
  }

  return compactObject({
    id,
    type: "element",
    tag: node.tagName?.toLowerCase(),
    role: node.getAttribute?.("role"),
    label: node.getAttribute?.("aria-label"),
    testId: node.getAttribute?.("data-testid"),
    className: node.getAttribute?.("class"),
    rocEventId: node.dataset?.rocEventId,
    text: compactText(node.textContent),
  });
}

function describePointerEvent(event) {
  if (!event || !event.type?.startsWith("pointer")) {
    return null;
  }
  return compactObject({
    pointerId: event.pointerId,
    pointerType: event.pointerType,
    isPrimary: event.isPrimary,
    button: event.button,
    buttons: event.buttons,
    clientX: event.clientX,
    clientY: event.clientY,
    pageX: event.pageX,
    pageY: event.pageY,
  });
}

function compactObject(input) {
  const out = {};
  for (const [key, value] of Object.entries(input)) {
    if (value !== undefined && value !== null && value !== "") {
      out[key] = value;
    }
  }
  return out;
}

function compactText(value) {
  if (value === undefined || value === null) {
    return "";
  }
  const text = String(value).replace(/\s+/g, " ").trim();
  return text.length > 160 ? `${text.slice(0, 157)}...` : text;
}

function setRole(node, value) {
  node.setAttribute("role", value);
  if (node.tagName === "INPUT" && value === "checkbox") {
    node.type = "checkbox";
  }
}

function setClass(node, value) {
  if (value === "") {
    node.removeAttribute("class");
  } else {
    node.className = value;
  }
}

function align4(value) {
  return (value + 3) & ~3;
}

function ensureDynamicAvailable(cursor, byteCount, field) {
  if (cursor.offset + byteCount <= cursor.limit) {
    return;
  }
  throw new Error(
    `malformed dynamic render record at byte ${cursor.recordOffset}: ${cursor.opName} operand ${field} extends beyond payload_len`,
  );
}

function readDynamicU32(view, cursor, field) {
  ensureDynamicAvailable(cursor, 4, field);
  const value = view.getUint32(cursor.offset, true);
  cursor.offset += 4;
  return value;
}

function readDynamicString(view, cursor, field) {
  const length = readDynamicU32(view, cursor, `${field}_len`);
  ensureDynamicAvailable(cursor, length, field);
  const bytes = new Uint8Array(view.buffer, view.byteOffset + cursor.offset, length);
  cursor.offset += length;
  try {
    return dynamicTextDecoder.decode(bytes);
  } catch (err) {
    throw new Error(
      `malformed dynamic render record at byte ${cursor.recordOffset}: ${cursor.opName} ${field} was not valid UTF-8`,
      { cause: err },
    );
  }
}

function readDynamicByteArray(view, cursor, field) {
  const length = readDynamicU32(view, cursor, `${field}_len`);
  ensureDynamicAvailable(cursor, length, field);
  const bytes = new Uint8Array(view.buffer, view.byteOffset + cursor.offset, length);
  cursor.offset += length;
  return new Uint8Array(bytes);
}

function assertDynamicPayloadConsumed(cursor) {
  if (cursor.offset === cursor.limit) {
    return;
  }
  throw new Error(
    `malformed dynamic render record at byte ${cursor.recordOffset}: ${cursor.opName} left ${cursor.limit - cursor.offset} trailing payload bytes`,
  );
}

function setDynamicTextAttribute(node, name, value) {
  if (name === "role") {
    setRole(node, value);
  } else if (name === "class") {
    setClass(node, value);
  } else {
    node.setAttribute(name, value);
  }
}

function removeDynamicAttribute(node, name) {
  if (name === "class") {
    setClass(node, "");
  } else {
    node.removeAttribute(name);
  }
}
