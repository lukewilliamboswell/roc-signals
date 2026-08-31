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
  pushState: 28,
  replaceState: 29,
  setStorageText: 30,
  removeStorage: 31,
  setDocumentTitle: 32,
});

// Version 12: `remove_node` releases the whole subtree under its target. The
// engine publishes one removal per retired subtree root, and the runtime drops
// every DOM id, listener, controlled input, and behaviour under that root.
export const Protocol = Object.freeze({
  version: 13,
});

export const ProtocolFeature = Object.freeze({
  dynamicAttrs: 1 << 0,
  dynamicEvents: 1 << 1,
});

const requiredProtocolFeatures =
  ProtocolFeature.dynamicAttrs | ProtocolFeature.dynamicEvents;

const behaviorAttrName = "data-signals-behavior";

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
  [Op.pushState]: "push_state",
  [Op.replaceState]: "replace_state",
  [Op.setStorageText]: "set_storage_text",
  [Op.removeStorage]: "remove_storage",
  [Op.setDocumentTitle]: "set_document_title",
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

const eventResponseBitMask =
  ListenerOptions.preventDefault |
  ListenerOptions.stopPropagation |
  ListenerOptions.stopImmediatePropagation;

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

export const LocationBoundarySchema = Object.freeze({
  kind: "record",
  fields: Object.freeze([
    Object.freeze({ name: "path", spec: Object.freeze({ kind: "text" }) }),
    Object.freeze({ name: "query", spec: Object.freeze({ kind: "text" }) }),
    Object.freeze({ name: "hash", spec: Object.freeze({ kind: "text" }) }),
  ]),
});

export const VisibilityBoundarySchema = Object.freeze({
  kind: "bool",
});

export const OnlineBoundarySchema = Object.freeze({
  kind: "bool",
});

export function entropySeedFromCrypto(cryptoProvider) {
  if (cryptoProvider == null || typeof cryptoProvider.getRandomValues !== "function") {
    throw new Error("Signals entropy source requires crypto.getRandomValues");
  }
  const values = new Uint32Array(1);
  cryptoProvider.getRandomValues(values);
  return values[0] >>> 0;
}

export const StorageArea = Object.freeze({
  local: 1,
  session: 2,
});

const StoragePayloadTag = Object.freeze({
  missing: 0,
  value: 1,
  unavailable: 2,
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
  detail: 5,
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

export function createHttpTaskRouter(routes) {
  const entries = Object.entries(routes).map(([key, handler]) => {
    const [method, ...uriParts] = key.trim().split(/\s+/);
    const uri = uriParts.join(" ");
    if (!method || !uri || typeof handler !== "function") {
      throw new Error(`invalid HTTP task route: ${key}`);
    }
    return { method: method.toUpperCase(), uri, handler };
  });
  const routeByKey = new Map(entries.map((entry) => [`${entry.method} ${entry.uri}`, entry]));
  const knownUris = new Set(entries.map((entry) => entry.uri));

  return function httpTaskRouter({ name, request, signal, requestId }) {
    if (!name.startsWith(HttpTask.namePrefix)) {
      return null;
    }

    let decoded;
    try {
      decoded = decodeHttpRequestPayload(request);
    } catch (err) {
      throw httpTaskError("unsupported", err?.message ?? err);
    }

    const method = decoded.method.toUpperCase();
    const route = routeByKey.get(`${method} ${decoded.uri}`);
    if (!route) {
      if (knownUris.has(decoded.uri)) {
        throw httpTaskError("unsupported", `unsupported HTTP method ${decoded.method} for ${decoded.uri}`);
      }
      return null;
    }

    const routeRequest = {
      method: decoded.method,
      uri: decoded.uri,
      headers: decoded.headers,
      body: decoded.body,
      bodyText: () => dynamicTextDecoder.decode(decoded.body),
      timeoutMs: decoded.timeoutMs,
      signal,
      name,
      requestId,
    };

    try {
      const result = route.handler(routeRequest);
      if (result && typeof result.then === "function") {
        return Promise.resolve(result).catch((err) => {
          throw normalizeHttpRouterError(err);
        });
      }
      return result;
    } catch (err) {
      throw normalizeHttpRouterError(err);
    }
  };
}

export function httpJsonResponse(value, { status = 200, headers = [] } = {}) {
  return httpTextResponse(JSON.stringify(value), {
    status,
    contentType: "application/json; charset=utf-8",
    headers,
  });
}

export function httpTextResponse(
  text,
  { status = 200, contentType = "text/plain; charset=utf-8", headers = [] } = {},
) {
  return encodeHttpResponsePayload({
    status,
    headers: [["content-type", contentType], ...headers],
    body: textEncoder.encode(String(text)),
  });
}

export function httpTaskError(code, message = "") {
  return new Error(encodeHttpErrorPayload(code, message));
}

export function httpHeaderValue(headers, targetName) {
  const target = String(targetName).toLowerCase();
  for (const [name, value] of headers) {
    if (String(name).toLowerCase() === target) {
      return String(value);
    }
  }
  return "";
}

function normalizeHttpRouterError(err) {
  const message = String(err?.message ?? err);
  if (message.startsWith(HttpPayloadVersion.error)) {
    return err instanceof Error ? err : new Error(message);
  }
  return httpTaskError("unsupported", message);
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

function storageForArea(options, area) {
  if (area === StorageArea.local) {
    return options.localStorage ?? options.storage?.localStorage ?? globalThis.localStorage;
  }
  if (area === StorageArea.session) {
    return options.sessionStorage ?? options.storage?.sessionStorage ?? globalThis.sessionStorage;
  }
  return null;
}

function storageSnapshotForKey(options, area, key) {
  const storage = storageForArea(options, area);
  if (storage === undefined || storage === null || typeof storage.getItem !== "function") {
    return { kind: "unavailable", message: "browser storage is unavailable" };
  }

  try {
    const value = storage.getItem(key);
    return value === null ? { kind: "missing" } : { kind: "value", value: String(value) };
  } catch (err) {
    return { kind: "unavailable", message: err?.message ?? String(err) };
  }
}

function createStorageImports(getExports, options = {}) {
  function readKey(keyPtr, keyLen) {
    const exports = getExports();
    if (!exports?.memory) {
      throw new Error("storage import ran before wasm memory was available");
    }
    return textDecoder.decode(new Uint8Array(exports.memory.buffer, keyPtr, keyLen));
  }

  function payloadBytes(area, keyPtr, keyLen) {
    const key = readKey(keyPtr, keyLen);
    return encodeStoragePayloadBytes(storageSnapshotForKey(options, area, key));
  }

  return {
    roc_ui_storage_payload_len(area, keyPtr, keyLen) {
      return payloadBytes(area, keyPtr, keyLen).length;
    },
    roc_ui_read_storage_payload(area, keyPtr, keyLen, outPtr, outLen) {
      const exports = getExports();
      if (!exports?.memory) {
        throw new Error("storage import ran before wasm memory was available");
      }
      const bytes = payloadBytes(area, keyPtr, keyLen);
      if (bytes.length > outLen) {
        return bytes.length;
      }
      new Uint8Array(exports.memory.buffer, outPtr, outLen).set(bytes);
      return bytes.length;
    },
  };
}

export async function instantiateSignalsBytes(bytes, options = {}) {
  let instanceRef = null;
  const result = await WebAssembly.instantiate(bytes, {
    env: createStorageImports(() => instanceRef?.exports, options),
  });
  instanceRef = result.instance;
  return result;
}

export async function instantiateSignalsWasm(url, options = {}) {
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`failed to fetch ${url}: ${response.status}`);
  }

  const bytes = await response.arrayBuffer();
  const { instance } = await instantiateSignalsBytes(bytes, options);
  return instance;
}

export async function mountSignalsApp({ wasmUrl, root, taskHandler, onError, telemetry, behaviors, localStorage, sessionStorage, storage, document, visibilityDocument, navigator, networkEventTarget, crypto }) {
  const instance = await instantiateSignalsWasm(wasmUrl, { telemetry, localStorage, sessionStorage, storage });
  const runtime = new SignalsRuntime(instance.exports, root, { taskHandler, onError, telemetry, behaviors, localStorage, sessionStorage, storage, document, visibilityDocument, navigator, networkEventTarget, crypto });
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
    this.nodeIds = new WeakMap([[root, 0]]);
    this.eventCleanups = new Map();
    this.controlledInputs = new Map();
    this.pendingSelectValues = new Map();
    this.intervals = new Map();
    this.tasks = new Map();
    this.issuedTasks = new Map();
    this.taskHandler = options.taskHandler ?? null;
    this.location = options.location ?? globalThis.location;
    this.history = options.history ?? globalThis.history;
    this.localStorage = options.localStorage ?? options.storage?.localStorage ?? globalThis.localStorage;
    this.sessionStorage = options.sessionStorage ?? options.storage?.sessionStorage ?? globalThis.sessionStorage;
    this.eventTarget = options.eventTarget ?? globalThis;
    this.document = options.document ?? globalThis.document;
    this.visibilityDocument = options.visibilityDocument ?? this.document;
    this.navigator = options.navigator ?? globalThis.navigator;
    this.crypto = options.crypto ?? globalThis.crypto;
    this.networkEventTarget = options.networkEventTarget ?? this.eventTarget;
    this.behaviors = normalizeBehaviors(options.behaviors);
    this.behaviorInstances = new Map();
    this.pendingBehaviorAttaches = new Set();
    this.pendingBehaviorUpdates = new Map();
    this.telemetryLog = normalizeTelemetry(options.telemetry);
    this.telemetrySeq = 0;
    this.mounted = false;
    this.mountGeneration = 0;
    this.locationListenerCleanup = null;
    this.visibilityListenerCleanup = null;
    this.onlineListenerCleanup = null;
    this.pointerProbeCleanups = [];
    this.lastEventResponseBits = 0;
    this.storageBatch = null;
    this.failedError = null;
    this.hasErrorReporter = typeof options.onError === "function";
    this.maxPayloadBytes = options.limits?.maxPayloadBytes ?? 0xffff_ffff;
    if (!Number.isSafeInteger(this.maxPayloadBytes) || this.maxPayloadBytes < 0 || this.maxPayloadBytes > 0xffff_ffff) {
      throw new RangeError("Signals maxPayloadBytes must be an integer between 0 and 4294967295");
    }
    this.onError = options.onError ?? ((err) => {
      setTimeout(() => {
        throw err;
      }, 0);
    });
    // The patch stream is inspectable: `lastCommands` holds the records drained
    // by the most recent host call so guards can assert the per-event patch
    // budget (mirrors the native host's `patches_emitted` discipline).
    this.lastCommands = [];
    // Non-null while a drained command batch is being applied; see
    // snapshotCommandBuffers.
    this.commandBuffers = null;
    this.commandDecodeStats = null;
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
    this.assertUsable();
    const initialPayloads = this.prepareInitialEnvironmentPayloads();
    try {
      this.commitInitialEnvironmentPayloads(initialPayloads);
    } finally {
      this.freePreparedPayloads(initialPayloads);
    }
    this.mountGeneration += 1;
    this.prepareMountEnvironment();
    this.installLocationListener(this.mountGeneration);
    this.installVisibilityListener(this.mountGeneration);
    this.installOnlineListener(this.mountGeneration);
    this.emitTelemetry("host_call", { call: "mount" });
    try {
      this.views.callHost(this.exports.roc_ui_mount);
    } catch (err) {
      throw this.poisonAfterHostFailure(err);
    }
    this.applyPendingCommands("mount");
    this.mounted = true;
  }

  prepareInitialEnvironmentPayloads() {
    const specs = [];
    if (typeof this.exports.roc_ui_set_entropy_seed === "function") {
      const seed = entropySeedFromCrypto(this.crypto);
      specs.push({ hostCall: this.exports.roc_ui_set_entropy_seed, scalar: seed, detail: { entropySeeded: true } });
    }
    if (typeof this.exports.roc_ui_set_location === "function") {
      const value = locationSnapshotFromLocation(this.location);
      specs.push({ hostCall: this.exports.roc_ui_set_location, value, bytes: encodeBoundarySchemaPayloadBytes(LocationBoundarySchema, value), detail: { location: value } });
    }
    if (typeof this.exports.roc_ui_set_visibility === "function") {
      const value = visibilitySnapshotFromDocument(this.visibilityDocument);
      specs.push({ hostCall: this.exports.roc_ui_set_visibility, value, bytes: encodeBoundarySchemaPayloadBytes(VisibilityBoundarySchema, value), detail: { visibility: value } });
    }
    if (typeof this.exports.roc_ui_set_online === "function") {
      const value = onlineSnapshotFromNavigator(this.navigator);
      specs.push({ hostCall: this.exports.roc_ui_set_online, value, bytes: encodeBoundarySchemaPayloadBytes(OnlineBoundarySchema, value), detail: { online: value } });
    }

    const prepared = [];
    try {
      for (const spec of specs) {
        prepared.push(spec.bytes == null ? spec : { ...spec, ptr: this.allocatePayload(spec.bytes.length) });
      }
      return prepared;
    } catch (err) {
      this.freePreparedPayloads(prepared);
      throw err;
    }
  }

  commitInitialEnvironmentPayloads(prepared) {
    for (const entry of prepared) {
      if (entry.scalar != null) {
        this.emitTelemetry("environment_snapshot", { ...entry.detail });
        try {
          this.views.callHost(entry.hostCall, entry.scalar);
        } catch (err) {
          throw this.poisonAfterHostFailure(err);
        }
        continue;
      }
      this.views.u8.set(entry.bytes, entry.ptr);
      this.emitTelemetry("environment_snapshot", { ...entry.detail, payloadLen: entry.bytes.length });
      try {
        this.views.callHost(entry.hostCall, entry.ptr, entry.bytes.length);
      } catch (err) {
        throw this.poisonAfterHostFailure(err);
      }
    }
  }

  freePreparedPayloads(prepared) {
    for (const entry of prepared) {
      if (entry.ptr == null) continue;
      this.views.callHost(this.exports.roc_dealloc, entry.ptr, 1);
    }
  }

  prepareMountEnvironment() {
    if (typeof this.exports.roc_ui_prepare_mount !== "function") {
      return;
    }
    this.emitTelemetry("host_call", { call: "prepare_mount" });
    try {
      this.views.callHost(this.exports.roc_ui_prepare_mount);
      this.seedInitialStorageSnapshots();
    } catch (err) {
      throw this.poisonAfterHostFailure(err);
    }
  }

  seedInitialStorageSnapshots() {
    const countExport = this.exports.roc_ui_storage_declaration_count;
    const areaExport = this.exports.roc_ui_storage_declaration_area;
    const keyPtrExport = this.exports.roc_ui_storage_declaration_key_ptr;
    const keyLenExport = this.exports.roc_ui_storage_declaration_key_len;
    const setPayload = this.exports.roc_ui_set_storage_payload;
    if (
      typeof countExport !== "function" ||
      typeof areaExport !== "function" ||
      typeof keyPtrExport !== "function" ||
      typeof keyLenExport !== "function" ||
      typeof setPayload !== "function"
    ) {
      return;
    }

    const count = countExport();
    for (let index = 0; index < count; index += 1) {
      const area = areaExport(index);
      const keyPtr = keyPtrExport(index);
      const keyLen = keyLenExport(index);
      const key = this.readMemoryString(keyPtr, keyLen);
      const snapshot = storageSnapshotForKey(
        { localStorage: this.localStorage, sessionStorage: this.sessionStorage },
        area,
        key,
      );
      const bytes = encodeStoragePayloadBytes(snapshot);
      const payloadPtr = this.allocatePayload(bytes.length);
      try {
        this.views.u8.set(bytes, payloadPtr);
        this.emitTelemetry("storage_snapshot", {
          area,
          key,
          snapshotKind: snapshot.kind,
          payloadLen: bytes.length,
        });
        this.views.callHost(setPayload, area, keyPtr, keyLen, payloadPtr, bytes.length);
      } finally {
        this.views.callHost(this.exports.roc_dealloc, payloadPtr, 1);
      }
    }
  }

  writeLocationPayload(exportName, snapshot, telemetryKind, telemetryDetail = {}) {
    const hostCall = this.exports[exportName];
    if (typeof hostCall !== "function") {
      return false;
    }
    const bytes = encodeBoundarySchemaPayloadBytes(LocationBoundarySchema, snapshot);
    const ptr = this.allocatePayload(bytes.length);
    try {
      this.views.u8.set(bytes, ptr);
      this.emitTelemetry(telemetryKind, {
        ...telemetryDetail,
        payloadLen: bytes.length,
      });
      this.views.callHost(hostCall, ptr, bytes.length);
      return true;
    } catch (err) {
      throw this.poisonAfterHostFailure(err);
    } finally {
      this.views.callHost(this.exports.roc_dealloc, ptr, 1);
    }
  }

  writeVisibilityPayload(exportName, visible, telemetryKind, telemetryDetail = {}) {
    const hostCall = this.exports[exportName];
    if (typeof hostCall !== "function") {
      return false;
    }
    const bytes = encodeBoundarySchemaPayloadBytes(VisibilityBoundarySchema, visible);
    const ptr = this.allocatePayload(bytes.length);
    try {
      this.views.u8.set(bytes, ptr);
      this.emitTelemetry(telemetryKind, {
        ...telemetryDetail,
        payloadLen: bytes.length,
      });
      this.views.callHost(hostCall, ptr, bytes.length);
      return true;
    } catch (err) {
      throw this.poisonAfterHostFailure(err);
    } finally {
      this.views.callHost(this.exports.roc_dealloc, ptr, 1);
    }
  }

  writeOnlinePayload(exportName, online, telemetryKind, telemetryDetail = {}) {
    const hostCall = this.exports[exportName];
    if (typeof hostCall !== "function") {
      return false;
    }
    const bytes = encodeBoundarySchemaPayloadBytes(OnlineBoundarySchema, online);
    const ptr = this.allocatePayload(bytes.length);
    try {
      this.views.u8.set(bytes, ptr);
      this.emitTelemetry(telemetryKind, {
        ...telemetryDetail,
        payloadLen: bytes.length,
      });
      this.views.callHost(hostCall, ptr, bytes.length);
      return true;
    } catch (err) {
      throw this.poisonAfterHostFailure(err);
    } finally {
      this.views.callHost(this.exports.roc_dealloc, ptr, 1);
    }
  }

  installLocationListener(generation) {
    this.clearLocationListener();
    if (typeof this.exports.roc_ui_update_location !== "function") {
      return;
    }
    if (
      this.eventTarget === undefined ||
      this.eventTarget === null ||
      typeof this.eventTarget.addEventListener !== "function" ||
      typeof this.eventTarget.removeEventListener !== "function"
    ) {
      return;
    }

    const listener = () => this.dispatchPopstate(generation);
    this.eventTarget.addEventListener("popstate", listener);
    this.locationListenerCleanup = () => {
      this.eventTarget.removeEventListener("popstate", listener);
    };
    this.emitTelemetry("popstate_listener", { action: "install", generation });
  }

  clearLocationListener() {
    if (this.locationListenerCleanup === null) {
      return;
    }
    this.locationListenerCleanup();
    this.locationListenerCleanup = null;
    this.emitTelemetry("popstate_listener", { action: "remove", generation: this.mountGeneration });
  }

  dispatchPopstate(generation) {
    if (!this.mounted || generation !== this.mountGeneration) {
      this.emitTelemetry("ignored_popstate", {
        reason: this.mounted ? "stale_generation" : "unmounted",
        generation,
        currentGeneration: this.mountGeneration,
      });
      return;
    }
    const snapshot = locationSnapshotFromLocation(this.location);
    this.emitTelemetry("host_call", { call: "popstate", generation });
    this.writeLocationPayload("roc_ui_update_location", snapshot, "location_update", {
      trigger: "popstate",
      generation,
      location: snapshot,
    });
    this.applyPendingCommands(`popstate:${generation}`);
  }

  installVisibilityListener(generation) {
    this.clearVisibilityListener();
    if (typeof this.exports.roc_ui_update_visibility !== "function") {
      return;
    }
    if (
      this.visibilityDocument === undefined ||
      this.visibilityDocument === null ||
      typeof this.visibilityDocument.addEventListener !== "function" ||
      typeof this.visibilityDocument.removeEventListener !== "function"
    ) {
      return;
    }

    const listener = () => this.dispatchVisibilitychange(generation);
    this.visibilityDocument.addEventListener("visibilitychange", listener);
    this.visibilityListenerCleanup = () => {
      this.visibilityDocument.removeEventListener("visibilitychange", listener);
    };
    this.emitTelemetry("visibility_listener", { action: "install", generation });
  }

  clearVisibilityListener() {
    if (this.visibilityListenerCleanup === null) {
      return;
    }
    this.visibilityListenerCleanup();
    this.visibilityListenerCleanup = null;
    this.emitTelemetry("visibility_listener", { action: "remove", generation: this.mountGeneration });
  }

  dispatchVisibilitychange(generation) {
    if (!this.mounted || generation !== this.mountGeneration) {
      this.emitTelemetry("ignored_visibilitychange", {
        reason: this.mounted ? "stale_generation" : "unmounted",
        generation,
        currentGeneration: this.mountGeneration,
      });
      return;
    }
    const visible = visibilitySnapshotFromDocument(this.visibilityDocument);
    this.emitTelemetry("host_call", { call: "visibilitychange", generation });
    this.writeVisibilityPayload("roc_ui_update_visibility", visible, "visibility_update", {
      trigger: "visibilitychange",
      generation,
      visibility: visible,
    });
    this.applyPendingCommands(`visibilitychange:${generation}`);
  }

  installOnlineListener(generation) {
    this.clearOnlineListener();
    if (typeof this.exports.roc_ui_update_online !== "function") {
      return;
    }
    if (
      this.networkEventTarget === undefined ||
      this.networkEventTarget === null ||
      typeof this.networkEventTarget.addEventListener !== "function" ||
      typeof this.networkEventTarget.removeEventListener !== "function"
    ) {
      return;
    }

    const onlineListener = () => this.dispatchOnlineChange(generation, "online");
    const offlineListener = () => this.dispatchOnlineChange(generation, "offline");
    this.networkEventTarget.addEventListener("online", onlineListener);
    this.networkEventTarget.addEventListener("offline", offlineListener);
    this.onlineListenerCleanup = () => {
      this.networkEventTarget.removeEventListener("online", onlineListener);
      this.networkEventTarget.removeEventListener("offline", offlineListener);
    };
    this.emitTelemetry("online_listener", { action: "install", generation });
  }

  clearOnlineListener() {
    if (this.onlineListenerCleanup === null) {
      return;
    }
    this.onlineListenerCleanup();
    this.onlineListenerCleanup = null;
    this.emitTelemetry("online_listener", { action: "remove", generation: this.mountGeneration });
  }

  dispatchOnlineChange(generation, trigger) {
    if (!this.mounted || generation !== this.mountGeneration) {
      this.emitTelemetry("ignored_onlinechange", {
        reason: this.mounted ? "stale_generation" : "unmounted",
        generation,
        currentGeneration: this.mountGeneration,
        trigger,
      });
      return;
    }
    const online = onlineSnapshotFromNavigator(this.navigator);
    this.emitTelemetry("host_call", { call: "onlinechange", generation, trigger });
    this.writeOnlinePayload("roc_ui_update_online", online, "online_update", {
      trigger,
      generation,
      online,
    });
    this.applyPendingCommands(`onlinechange:${generation}`);
  }

  unmount() {
    if (this.failedError !== null) return;
    this.mounted = false;
    this.clearLocationListener();
    this.clearVisibilityListener();
    this.clearOnlineListener();
    this.emitTelemetry("host_call", { call: "unmount" });
    try {
      this.views.callHost(this.exports.roc_ui_unmount);
    } catch (err) {
      throw this.poisonAfterHostFailure(err);
    }
    this.applyPendingCommands("unmount");
    this.clearPointerProbe();
    this.clearDom();
  }

  dispatchUnit(eventId, options = {}) {
    return this.dispatch(eventId, PayloadKind.unit, 0, 0, 0, options);
  }

  dispatchBool(eventId, value, options = {}) {
    return this.dispatch(eventId, PayloadKind.bool, 0, 0, value ? 1 : 0, options);
  }

  dispatchString(eventId, value, options = {}) {
    const bytes = textEncoder.encode(value);
    const ptr = this.allocatePayload(bytes.length);
    let primaryError;
    try {
      this.views.u8.set(bytes, ptr);
      return this.dispatch(eventId, PayloadKind.str, ptr, bytes.length, 0, options);
    } catch (err) {
      primaryError = err;
      throw err;
    } finally {
      this.deallocEventPayload(ptr, primaryError);
    }
  }

  dispatchBytes(eventId, bytes, options = {}) {
    const ptr = this.allocatePayload(bytes.length);
    let primaryError;
    try {
      this.views.u8.set(bytes, ptr);
      return this.dispatch(eventId, PayloadKind.bytes, ptr, bytes.length, 0, options);
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

  dispatch(eventId, payloadKind, payloadPtr, payloadLen, boolValue, options = {}) {
    this.assertUsable();
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
      const responseBits = validateEventResponseBits(eventCall.result ?? 0);
      this.lastEventResponseBits = responseBits;
      if (options.drainCommands !== false) {
        this.applyPendingCommands(`event:${eventId}`);
      }
      return responseBits;
    } catch (err) {
      throw this.poisonAfterHostFailure(err);
    }
  }

  tickTimer(token) {
    this.assertUsable();
    if (!this.intervals.has(token)) {
      this.emitTelemetry("ignored_timer_tick", { token });
      return;
    }
    this.emitTelemetry("host_call", { call: "timer", token });
    try {
      this.views.callHost(this.exports.roc_ui_timer, token);
    } catch (err) {
      throw this.poisonAfterHostFailure(err);
    }
    this.applyPendingCommands(`timer:${token}`);
  }

  resolveTask(requestId, value, failed = false) {
    this.assertUsable();
    const task = this.tasks.get(requestId);
    const issuedTask = this.issuedTasks.get(requestId);
    if (!task && !issuedTask) {
      this.emitTelemetry("unknown_task_resolution", { requestId, failed: failed !== false });
      throw this.runtimeError(new Error(`task result had no matching pending request: ${requestId}`));
    }
    if (!task) {
      this.emitTelemetry("ignored_task_resolution", {
        requestId,
        name: issuedTask.name,
        request: issuedTask.request,
        failed: failed !== false,
        reason: "not_pending",
      });
    }
    const bytes = textEncoder.encode(value);
    const ptr = this.allocatePayload(bytes.length);
    try {
      this.views.u8.set(bytes, ptr);
      if (task) {
        this.emitTelemetry("task_resolution", {
          requestId,
          name: task.name,
          request: task.request,
          failed: failed !== false,
          payloadLen: bytes.length,
        });
      }
      this.emitTelemetry("host_call", {
        call: "resolve_task",
        requestId,
        failed: failed !== false,
        payloadLen: bytes.length,
      });
      this.views.callHost(this.exports.roc_ui_resolve, requestId, ptr, bytes.length, failed ? 1 : 0);
    } catch (err) {
      throw this.poisonAfterHostFailure(err);
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

  allocatePayload(length) {
    this.assertUsable();
    if (!Number.isSafeInteger(length) || length < 0 || length > this.maxPayloadBytes) {
      const err = new Error(`Signals payload length ${length} exceeds configured limit ${this.maxPayloadBytes}`);
      err.code = "resource_limit";
      throw err;
    }
    let result;
    try {
      result = this.views.callHost(this.exports.roc_alloc, length, 1).result;
    } catch (err) {
      throw this.poisonAfterHostFailure(err);
    }
    if ((result === 0 || result == null) && length !== 0) {
      const err = new Error(`Signals Wasm payload allocation failed for ${length} bytes`);
      err.code = "out_of_memory";
      throw err;
    }
    return result ?? 0;
  }

  assertUsable() {
    if (this.failedError !== null) {
      throw this.failedError;
    }
  }

  poisonAfterHostFailure(err) {
    if (this.failedError !== null) return this.failedError;
    const fatal = this.runtimeError(err);
    this.failedError = fatal;
    this.mounted = false;
    this.mountGeneration += 1;
    this.lastCommands = [];
    this.commandBuffers = null;
    this.clearLocationListener();
    this.clearVisibilityListener();
    this.clearOnlineListener();
    this.clearPointerProbe();
    this.clearAsyncResources();
    for (const cleanup of this.eventCleanups.values()) cleanup();
    this.eventCleanups.clear();
    this.clearControlledInputs();
    this.cleanupBehaviors();
    if (this.hasErrorReporter) {
      this.onError(fatal);
      fatal.signalsReported = true;
    }
    return fatal;
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
    if (err?.signalsReported === true) return;
    this.onError(err);
  }

  /// Copy the host's string and dynamic payload buffers into JS-owned arrays.
  ///
  /// Applying a command can re-enter the host (moving DOM focus fires a focus
  /// listener, which dispatches into Roc), and every host entry point starts by
  /// clearing these buffers. Reading them lazily during apply therefore races
  /// with that clear: the dynamic buffer reports a null base and throws, and the
  /// string buffer silently decodes from address 0. Snapshotting at drain time
  /// makes apply independent of what the host does next.
  snapshotCommandBuffers() {
    this.views.afterHostCall();
    const stringLen = this.exports.roc_ui_string_buffer_len();
    const stringBase = this.exports.roc_ui_string_buffer_ptr();
    const dynamicLen = this.exports.roc_ui_dynamic_buffer_len();
    const dynamicBase = this.exports.roc_ui_dynamic_buffer_ptr();
    return {
      strings: stringLen === 0 || stringBase === 0
        ? new Uint8Array(0)
        : this.views.u8.slice(stringBase, stringBase + stringLen),
      dynamic: dynamicLen === 0 || dynamicBase === 0
        ? new Uint8Array(0)
        : this.views.u8.slice(dynamicBase, dynamicBase + dynamicLen),
    };
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
    recordFixedStringDecode(this.commandDecodeStats, length);
    if (length === 0) {
      return "";
    }

    const snapshot = this.commandBuffers;
    if (snapshot) {
      if (offset + length > snapshot.strings.byteLength) {
        throw new Error(
          `render command string slice ${offset}:${offset + length} exceeds string buffer length ${snapshot.strings.byteLength}`,
        );
      }
      return textDecoder.decode(snapshot.strings.subarray(offset, offset + length));
    }

    this.views.afterHostCall();
    const base = this.exports.roc_ui_string_buffer_ptr();
    if (base === 0) {
      throw new Error("render command referenced an empty string buffer");
    }
    const bytes = this.views.u8.subarray(base + offset, base + offset + length);
    return textDecoder.decode(bytes);
  }

  readMemoryString(ptr, length) {
    if (length === 0) {
      return "";
    }
    this.views.afterHostCall();
    return textDecoder.decode(this.views.u8.subarray(ptr, ptr + length));
  }

  readDynamicBytes(offset, length) {
    if (length === 0) {
      return new Uint8Array(0);
    }

    const snapshot = this.commandBuffers;
    if (snapshot) {
      if (offset + length > snapshot.dynamic.byteLength) {
        throw new Error(
          `dynamic render command slice ${offset}:${offset + length} exceeds dynamic buffer length ${snapshot.dynamic.byteLength}`,
        );
      }
      return snapshot.dynamic.subarray(offset, offset + length);
    }

    this.views.afterHostCall();
    const base = this.exports.roc_ui_dynamic_buffer_ptr();
    const available = this.exports.roc_ui_dynamic_buffer_len();
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
    const buffers = records.length === 0 ? null : this.snapshotCommandBuffers();
    this.lastCommands = records;
    const previousBuffers = this.commandBuffers;
    this.commandBuffers = buffers;
    this.emitCommandTelemetry(phase, records);
    const previousDecodeStats = this.commandDecodeStats;
    const previousStorageBatch = this.storageBatch;
    const decodeStats = newCommandDecodeStats();
    this.commandDecodeStats = decodeStats;
    this.storageBatch = new Map();
    try {
      for (const record of records) {
        this.applyCommand(record);
      }
    } finally {
      const storageBatch = this.storageBatch;
      this.commandBuffers = previousBuffers;
      this.commandDecodeStats = previousDecodeStats;
      this.storageBatch = previousStorageBatch;
      this.flushStorageBatch(storageBatch);
    }
    this.reapplyPendingSelectValues();
    this.flushBehaviorEffects();
    this.emitTelemetry("commands_applied", {
      phase,
      count: records.length,
      domNodes: this.nodes.size,
      eventListeners: this.eventCleanups.size,
      liveHostValues: this.liveHostValues(),
      decode: decodeStats,
    });
    this.emitAllocationTelemetry(phase);
    return records;
  }

  emitAllocationTelemetry(phase) {
    if (!this.telemetryLog) return;
    const countFn = this.exports.roc_ui_debug_live_allocation_count;
    const bytesFn = this.exports.roc_ui_debug_live_allocation_bytes;
    const sizeFn = this.exports.roc_ui_debug_live_allocation_size;
    const phaseFn = this.exports.roc_ui_debug_live_allocation_phase;
    if (![countFn, bytesFn, sizeFn, phaseFn].every((fn) => typeof fn === "function")) return;

    const live = this.views.callHost(countFn).result;
    const cohorts = new Map();
    for (let index = 0; index < live; index += 1) {
      const size = this.views.callHost(sizeFn, index).result;
      const allocationPhase = this.views.callHost(phaseFn, index).result;
      const key = `${allocationPhase}:${size}`;
      const cohort = cohorts.get(key) ?? { phase: allocationPhase, size, count: 0, bytes: 0 };
      cohort.count += 1;
      cohort.bytes += size;
      cohorts.set(key, cohort);
    }
    this.emitTelemetry("allocation_checkpoint", {
      phase,
      live,
      bytes: this.views.callHost(bytesFn).result,
      cohorts: [...cohorts.values()],
    });
  }

  applyCommand(record) {
    switch (record.op) {
      case Op.resetDom:
        this.clearDom();
        return;

      case Op.createElement:
        this.registerNode(record.a, document.createElement(this.readString(record.b, record.c)));
        return;

      case Op.createText:
        this.registerNode(record.a, document.createTextNode(this.readString(record.b, record.c)));
        return;

      case Op.appendChild:
        this.node(record.a).appendChild(this.node(record.b));
        return;

      case Op.removeNode: {
        const node = this.node(record.a);
        this.cleanupBehaviorSubtree(node);
        node.parentNode?.removeChild(node);
        this.releaseSubtree(node);
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
        setOptionalAttribute(this.node(record.a), "aria-label", this.readString(record.b, record.c));
        return;

      case Op.setTestId:
        setOptionalAttribute(this.node(record.a), "data-testid", this.readString(record.b, record.c));
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

      case Op.pushState:
        this.applyNavigationCommand("push", this.readString(record.a, record.b));
        return;

      case Op.replaceState:
        this.applyNavigationCommand("replace", this.readString(record.a, record.b));
        return;

      case Op.setStorageText:
        this.queueStorageCommand("set", record.a, this.readString(record.b, record.c), this.readString(record.d, record.e));
        return;

      case Op.removeStorage:
        this.queueStorageCommand("remove", record.a, this.readString(record.b, record.c), "");
        return;

      case Op.setDocumentTitle:
        this.applyDocumentTitleCommand(this.readString(record.b, record.c));
        return;

      case Op.extended:
        this.applyDynamicCommand(record.a, record.b);
        return;

      default:
        throw new Error(`unknown render op ${record.op}`);
    }
  }

  applyNavigationCommand(kind, href) {
    if (this.history === undefined || this.history === null) {
      throw new Error("browser history is unavailable");
    }
    if (kind === "push") {
      this.history.pushState(null, "", href);
    } else if (kind === "replace") {
      this.history.replaceState(null, "", href);
    } else {
      throw new Error(`unknown navigation kind ${kind}`);
    }
    this.emitTelemetry("navigation", { mode: kind, href });
  }

  storageForArea(area) {
    if (area === StorageArea.local) {
      return this.localStorage;
    }
    if (area === StorageArea.session) {
      return this.sessionStorage;
    }
    throw new Error(`unknown storage area ${area}`);
  }

  queueStorageCommand(mode, area, key, value) {
    const command = { mode, area, key, value };
    if (this.storageBatch === null) {
      this.applyStorageCommand(command);
      return;
    }
    this.storageBatch.set(`${area}\u0000${key}`, command);
  }

  flushStorageBatch(batch) {
    if (batch === null) {
      return;
    }
    for (const command of batch.values()) {
      this.applyStorageCommand(command);
    }
  }

  applyStorageCommand(command) {
    const storage = this.storageForArea(command.area);
    if (storage === undefined || storage === null) {
      throw new Error("browser storage is unavailable");
    }
    if (command.mode === "set") {
      if (typeof storage.setItem !== "function") {
        throw new Error("browser storage setItem is unavailable");
      }
      storage.setItem(command.key, command.value);
      this.emitTelemetry("storage", { mode: "set", area: command.area, key: command.key });
      return;
    }
    if (command.mode === "remove") {
      if (typeof storage.removeItem !== "function") {
        throw new Error("browser storage removeItem is unavailable");
      }
      storage.removeItem(command.key);
      this.emitTelemetry("storage", { mode: "remove", area: command.area, key: command.key });
      return;
    }
    throw new Error(`unknown storage command ${command.mode}`);
  }

  applyDocumentTitleCommand(title) {
    if (this.document === undefined || this.document === null) {
      throw new Error("document title is unavailable");
    }
    this.document.title = title;
    this.emitTelemetry("document_title", { title });
  }

  applyDynamicCommand(offset, length) {
    const command = this.decodeDynamicCommand(offset, length);
    switch (command.op) {
      case DynamicOp.setAttrText: {
        setDynamicTextAttribute(this.node(command.elemId), command.name, command.value);
        this.afterDynamicAttrSet(command.elemId, command.name, command.value);
        return;
      }

      case DynamicOp.removeAttr: {
        removeDynamicAttribute(this.node(command.elemId), command.name);
        this.afterDynamicAttrRemove(command.elemId, command.name);
        return;
      }

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

    recordDynamicRecordDecode(this.commandDecodeStats, bytes.byteLength);
    const cursor = {
      offset: 8,
      limit: 8 + payloadLen,
      recordOffset: offset,
      opName,
      stats: this.commandDecodeStats,
    };
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
      const responseBits = this.dispatchEventPayload(eventId, payloadDescriptor, event, payloadTelemetry, {
        drainCommands: false,
      });
      const responsePolicy = applyDynamicEventResponse(responseBits, event);
      if (this.telemetryLog && responsePolicy.changed) {
        this.emitTelemetry("dom_event_response", {
          domEvent,
          eventId,
          responseBits,
          preventedDefault: responsePolicy.preventedDefault,
          stoppedPropagation: responsePolicy.stoppedPropagation,
          stoppedImmediatePropagation: responsePolicy.stoppedImmediatePropagation,
        });
      }
      this.applyPendingCommands(`event:${eventId}`);
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

  // Behavior updates are scoped to dynamic custom attributes. Fixed-field render
  // ops such as text, class, value, checked, and test-id do not call update().
  afterDynamicAttrSet(elemId, name, value) {
    if (name === behaviorAttrName) {
      this.setBehaviorMarker(elemId, value);
      return;
    }
    this.scheduleBehaviorUpdate(elemId, name);
  }

  afterDynamicAttrRemove(elemId, name) {
    if (name === behaviorAttrName) {
      this.cleanupBehavior(elemId);
      this.pendingBehaviorAttaches.delete(elemId);
      this.pendingBehaviorUpdates.delete(elemId);
      return;
    }
    this.scheduleBehaviorUpdate(elemId, name);
  }

  setBehaviorMarker(elemId, name) {
    const current = this.behaviorInstances.get(elemId);
    if (current?.name === name) {
      return;
    }
    if (current) {
      this.cleanupBehavior(elemId);
    }
    this.pendingBehaviorAttaches.add(elemId);
    this.pendingBehaviorUpdates.delete(elemId);
  }

  scheduleBehaviorUpdate(elemId, attrName) {
    if (!this.behaviorInstances.has(elemId)) {
      return;
    }
    let attrs = this.pendingBehaviorUpdates.get(elemId);
    if (!attrs) {
      attrs = new Set();
      this.pendingBehaviorUpdates.set(elemId, attrs);
    }
    attrs.add(attrName);
  }

  flushBehaviorEffects() {
    if (this.pendingBehaviorAttaches.size !== 0) {
      const attachIds = [...this.pendingBehaviorAttaches];
      this.pendingBehaviorAttaches.clear();
      for (const elemId of attachIds) {
        this.attachBehavior(elemId);
      }
    }

    if (this.pendingBehaviorUpdates.size !== 0) {
      const updates = [...this.pendingBehaviorUpdates.entries()];
      this.pendingBehaviorUpdates.clear();
      for (const [elemId, attrs] of updates) {
        const instance = this.behaviorInstances.get(elemId);
        if (!instance || typeof instance.behavior.update !== "function") {
          continue;
        }
        for (const attrName of attrs) {
          instance.behavior.update(instance.el, attrName, { runtime: this });
          this.emitTelemetry("behavior_update", {
            elemId,
            behavior: instance.name,
            attrName,
            elem: describeDomNode(instance.el, elemId),
          });
        }
      }
    }
  }

  attachBehavior(elemId) {
    const el = this.nodes.get(elemId);
    if (!isElementLike(el)) {
      return;
    }
    const name = el.getAttribute?.(behaviorAttrName) ?? "";
    if (name === "") {
      return;
    }
    const behavior = this.behaviors.get(name);
    if (!behavior || typeof behavior.attach !== "function") {
      this.emitTelemetry("behavior_missing", {
        elemId,
        behavior: name,
        elem: describeDomNode(el, elemId),
      });
      return;
    }
    // Behaviors may return a cleanup function. Other return values are ignored.
    const attached = behavior.attach(el, { runtime: this });
    const cleanup = typeof attached === "function" ? attached : null;
    this.behaviorInstances.set(elemId, { name, el, behavior, cleanup });
    this.emitTelemetry("behavior_attach", {
      elemId,
      behavior: name,
      elem: describeDomNode(el, elemId),
    });
  }

  cleanupBehavior(elemId) {
    const instance = this.behaviorInstances.get(elemId);
    if (!instance) {
      return;
    }
    this.behaviorInstances.delete(elemId);
    this.pendingBehaviorUpdates.delete(elemId);
    instance.cleanup?.();
    this.emitTelemetry("behavior_cleanup", {
      elemId,
      behavior: instance.name,
      elem: describeDomNode(instance.el, elemId),
    });
  }

  cleanupBehaviorSubtree(node) {
    for (const [elemId, instance] of [...this.behaviorInstances.entries()]) {
      if (node === instance.el || nodeContains(node, instance.el)) {
        this.cleanupBehavior(elemId);
      }
    }
  }

  cleanupBehaviors() {
    for (const elemId of [...this.behaviorInstances.keys()]) {
      this.cleanupBehavior(elemId);
    }
    this.pendingBehaviorAttaches.clear();
    this.pendingBehaviorUpdates.clear();
  }

  dispatchEventPayload(eventId, payloadDescriptor, event, payloadTelemetry = null, options = {}) {
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
        return this.dispatchUnit(eventId, options);

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
        return this.dispatchString(eventId, value, options);
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
        return this.dispatchBool(eventId, value, options);
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
        return this.dispatchBytes(eventId, bytes, options);
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
      [
        "change",
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
    // A <select>'s value is meaningless until its <option> children carry their
    // own values, and the command stream sets the select's value first. The
    // assignment then matches nothing, the browser parks selectedIndex at -1,
    // and the control renders blank forever. Remember the intent and re-apply
    // it once the whole batch - options included - has been materialised.
    const node = this.nodes.get(elemId);
    if (node && node.tagName === "SELECT" && node.selectedIndex === -1 && value !== "") {
      this.pendingSelectValues.set(elemId, value);
    } else {
      this.pendingSelectValues.delete(elemId);
    }
  }

  reapplyPendingSelectValues() {
    if (this.pendingSelectValues.size === 0) {
      return;
    }
    for (const [elemId, value] of [...this.pendingSelectValues]) {
      const node = this.nodes.get(elemId);
      if (!node) {
        this.pendingSelectValues.delete(elemId);
        continue;
      }
      node.value = value;
      if (node.selectedIndex !== -1) {
        this.pendingSelectValues.delete(elemId);
      }
    }
  }

  clearControlledInput(elemId) {
    const entry = this.controlledInputs.get(elemId);
    if (!entry) {
      return;
    }
    entry.cleanup();
    this.controlledInputs.delete(elemId);
    this.pendingSelectValues.delete(elemId);
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
    this.issuedTasks.set(requestId, { name, request });
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
        try {
          this.resolveTask(requestId, String(value), false);
        } catch (err) {
          this.reportError(err);
        }
      },
      (err) => {
        try {
          this.resolveTask(requestId, String(err?.message ?? err), true);
        } catch (resolveErr) {
          this.reportError(resolveErr);
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

  registerNode(id, node) {
    const previous = this.nodes.get(id);
    if (previous) {
      this.nodeIds.delete(previous);
    }
    this.nodes.set(id, node);
    this.nodeIds.set(node, id);
  }

  // Releases every per-node registration under one removed root: the engine
  // publishes a single `remove_node` for a retired subtree, so the ids,
  // listeners, controlled inputs, and pending behaviour work of every
  // descendant are released here, exactly once, with the root's.
  releaseSubtree(root) {
    const released = new Set();
    const stack = [root];
    while (stack.length !== 0) {
      const node = stack.pop();
      const elemId = this.nodeIds.get(node);
      if (elemId !== undefined) {
        released.add(elemId);
        this.nodeIds.delete(node);
        this.nodes.delete(elemId);
        this.clearControlledInput(elemId);
        this.pendingBehaviorAttaches.delete(elemId);
        this.pendingBehaviorUpdates.delete(elemId);
      }
      const children = node.childNodes;
      if (children) {
        for (let index = children.length - 1; index >= 0; index -= 1) {
          stack.push(children[index]);
        }
      }
    }
    if (released.size !== 0 && this.eventCleanups.size !== 0) {
      for (const key of [...this.eventCleanups.keys()]) {
        if (released.has(Number(key.slice(0, key.indexOf(":"))))) {
          this.eventCleanups.get(key)();
          this.eventCleanups.delete(key);
        }
      }
    }
    return released;
  }

  clearDom() {
    this.emitTelemetry("clear_dom", {
      domNodes: this.nodes.size,
      eventListeners: this.eventCleanups.size,
      intervals: this.intervals.size,
      tasks: this.tasks.size,
    });
    this.clearAsyncResources();
    this.cleanupBehaviors();
    for (const cleanup of this.eventCleanups.values()) {
      cleanup();
    }
    this.eventCleanups.clear();
    this.clearControlledInputs();
    this.nodes.clear();
    this.nodes.set(0, this.root);
    this.nodeIds = new WeakMap([[this.root, 0]]);
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

      case Op.pushState:
      case Op.replaceState:
        return {
          op,
          href: this.readString(record.a, record.b),
        };

      case Op.setStorageText:
        return {
          op,
          area: record.a,
          key: this.readString(record.b, record.c),
          valueBytes: record.e,
        };

      case Op.removeStorage:
        return {
          op,
          area: record.a,
          key: this.readString(record.b, record.c),
        };

      case Op.setDocumentTitle:
        return { op, title: this.readString(record.b, record.c) };

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

function normalizeBehaviors(behaviors) {
  if (behaviors === undefined || behaviors === null) {
    return new Map();
  }
  if (behaviors instanceof Map) {
    return new Map(behaviors);
  }
  if (typeof behaviors === "object") {
    return new Map(Object.entries(behaviors));
  }
  throw new TypeError("SignalsRuntime behaviors must be an object or Map");
}

function isElementLike(node) {
  return !!node && typeof node.getAttribute === "function" && typeof node.setAttribute === "function";
}

function nodeContains(root, child) {
  if (!root || !child) {
    return false;
  }
  if (typeof root.contains === "function") {
    return root.contains(child);
  }
  let current = child.parentNode ?? null;
  while (current) {
    if (current === root) {
      return true;
    }
    current = current.parentNode ?? null;
  }
  return false;
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
  // Compact fixed-event opcodes omit delivery fields. They are only emitted for
  // canonical fixed bindings, so JS derives the same Auto -> Native delivery
  // decision from fixed binding traits for telemetry and listener setup.
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

function applyDynamicEventResponse(responseBits, event) {
  const result = applyStaticListenerPolicy(responseBits, event);
  return {
    ...result,
    changed:
      result.preventedDefault ||
      result.stoppedPropagation ||
      result.stoppedImmediatePropagation,
  };
}

function validateEventResponseBits(responseBits) {
  if (
    !Number.isInteger(responseBits) ||
    responseBits < 0 ||
    responseBits > 0xffffffff
  ) {
    throw new Error(`event response bits must be an unsigned 32-bit integer, got ${responseBits}`);
  }
  const unsupported = responseBits & ~eventResponseBitMask;
  if (unsupported !== 0) {
    throw new Error(`unsupported event response bits 0x${(unsupported >>> 0).toString(16)}`);
  }
  return responseBits;
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
  if (
    kind === "text" &&
    (leaf === EventExtractionLeaf.key || leaf === EventExtractionLeaf.value || leaf === EventExtractionLeaf.detail)
  ) {
    return;
  }
  if (kind === "bool" && (leaf === EventExtractionLeaf.checked || leaf === EventExtractionLeaf.shiftKey)) {
    return;
  }
  throw malformedEventExtractionPlan(cursor, `${kind} event extraction used incompatible leaf tag ${leaf}`);
}

function validateEventExtractionSourceLeaf(source, leaf, cursor) {
  if (
    (leaf === EventExtractionLeaf.key || leaf === EventExtractionLeaf.shiftKey || leaf === EventExtractionLeaf.detail) &&
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

function concatBytes(chunks) {
  let totalLen = 0;
  for (const chunk of chunks) {
    totalLen += chunk.length;
  }
  const out = new Uint8Array(totalLen);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.length;
  }
  return out;
}

export function encodeBoundarySchemaPayloadBytes(spec, value = undefined) {
  const chunks = [];
  let totalLen = 0;
  const push = (bytes) => {
    chunks.push(bytes);
    totalLen += bytes.length;
  };
  writeBoundarySchemaPayloadBytes(spec, value, push, "payload");
  const out = new Uint8Array(totalLen);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.length;
  }
  return out;
}

export function encodeStoragePayloadBytes(snapshot) {
  if (snapshot?.kind === "missing") {
    return new Uint8Array([StoragePayloadTag.missing]);
  }
  if (snapshot?.kind === "value") {
    return concatBytes([
      new Uint8Array([StoragePayloadTag.value]),
      encodeBoundarySchemaPayloadBytes(Object.freeze({ kind: "text" }), String(snapshot.value)),
    ]);
  }
  if (snapshot?.kind === "unavailable") {
    return concatBytes([
      new Uint8Array([StoragePayloadTag.unavailable]),
      encodeBoundarySchemaPayloadBytes(Object.freeze({ kind: "text" }), String(snapshot.message)),
    ]);
  }
  throw new Error("unknown storage payload snapshot");
}

export function locationSnapshotFromHref(href, baseHref = "http://signals.local/") {
  const url = new URL(String(href), baseHref);
  return {
    path: url.pathname,
    query: url.search.startsWith("?") ? url.search.slice(1) : url.search,
    hash: url.hash.startsWith("#") ? url.hash.slice(1) : url.hash,
  };
}

export function locationSnapshotFromLocation(location = globalThis.location) {
  if (location === undefined || location === null) {
    return locationSnapshotFromHref("/");
  }
  return locationSnapshotFromHref(location.href);
}

export function visibilitySnapshotFromDocument(doc = globalThis.document) {
  if (doc === undefined || doc === null || typeof doc.visibilityState !== "string") {
    return true;
  }
  return doc.visibilityState !== "hidden";
}

export function onlineSnapshotFromNavigator(navigator = globalThis.navigator) {
  if (navigator === undefined || navigator === null || typeof navigator.onLine !== "boolean") {
    return true;
  }
  return navigator.onLine;
}

function writeBoundarySchemaPayloadBytes(spec, value, push, path) {
  switch (spec.kind) {
    case "unit":
      return;
    case "text": {
      if (typeof value !== "string") {
        throw new Error(`${path} expected text boundary value`);
      }
      const bytes = textEncoder.encode(value);
      const len = new Uint8Array(4);
      new DataView(len.buffer).setUint32(0, bytes.length, true);
      push(len);
      push(bytes);
      return;
    }
    case "bool":
      if (typeof value !== "boolean") {
        throw new Error(`${path} expected bool boundary value`);
      }
      push(new Uint8Array([value ? 1 : 0]));
      return;
    case "record":
      if (value === null || typeof value !== "object") {
        throw new Error(`${path} expected record boundary value`);
      }
      for (const field of spec.fields) {
        writeBoundarySchemaPayloadBytes(field.spec, value[field.name], push, `${path}.${field.name}`);
      }
      return;
    default:
      throw new Error(`unknown boundary schema kind ${spec.kind}`);
  }
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
  if (spec.leaf === EventExtractionLeaf.detail) {
    return serializeEventDetail(event?.detail);
  }
  const source = eventExtractionSourceObject(spec.source, event);
  const property = eventExtractionLeafProperty(spec.leaf);
  return source?.[property];
}

function serializeEventDetail(detail) {
  if (detail === undefined || detail === null) {
    return "";
  }
  if (typeof detail === "string") {
    return detail;
  }
  const encoded = JSON.stringify(detail);
  return encoded === undefined ? "" : encoded;
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
    case EventExtractionLeaf.detail:
      return "detail";
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
  setOptionalAttribute(node, "role", value);
  if (node.tagName === "INPUT" && value === "checkbox") {
    node.type = "checkbox";
  }
}

function setOptionalAttribute(node, name, value) {
  if (value === "") {
    node.removeAttribute(name);
  } else {
    node.setAttribute(name, value);
  }
}

function setClass(node, value) {
  if (value === "") {
    node.removeAttribute("class");
  } else {
    node.className = value;
  }
}

function newCommandDecodeStats() {
  return {
    fixedStringDecodes: 0,
    fixedStringBytes: 0,
    dynamicRecordsDecoded: 0,
    dynamicRecordBytes: 0,
    dynamicStringDecodes: 0,
    dynamicStringBytes: 0,
    dynamicByteArrayDecodes: 0,
    dynamicByteArrayBytes: 0,
  };
}

function recordFixedStringDecode(stats, bytes) {
  if (!stats) {
    return;
  }
  stats.fixedStringDecodes += 1;
  stats.fixedStringBytes += bytes;
}

function recordDynamicRecordDecode(stats, bytes) {
  if (!stats) {
    return;
  }
  stats.dynamicRecordsDecoded += 1;
  stats.dynamicRecordBytes += bytes;
}

function recordDynamicStringDecode(stats, bytes) {
  if (!stats) {
    return;
  }
  stats.dynamicStringDecodes += 1;
  stats.dynamicStringBytes += bytes;
}

function recordDynamicByteArrayDecode(stats, bytes) {
  if (!stats) {
    return;
  }
  stats.dynamicByteArrayDecodes += 1;
  stats.dynamicByteArrayBytes += bytes;
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
  recordDynamicStringDecode(cursor.stats, length);
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
  recordDynamicByteArrayDecode(cursor.stats, length);
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
