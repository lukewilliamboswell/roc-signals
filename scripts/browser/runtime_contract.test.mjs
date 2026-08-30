import test from "node:test";
import assert from "node:assert/strict";

import {
  DynamicOp,
  ListenerOptions,
  LocationBoundarySchema,
  OnlineBoundarySchema,
  Op,
  PayloadKind,
  Protocol,
  ProtocolFeature,
  StorageArea,
  SignalsRuntime,
  VisibilityBoundarySchema,
  decodeHttpRequestPayload,
  decodeHttpResponsePayload,
  encodeBoundarySchemaPayloadBytes,
  encodeStoragePayloadBytes,
  encodeHttpRequestPayload,
  encodeHttpResponsePayload,
  httpFetchTaskHandler,
  locationSnapshotFromHref,
  onlineSnapshotFromNavigator,
  visibilitySnapshotFromDocument,
} from "../../www/static/signals.mjs";
import {
  apiRequestConsoleTaskHandler,
  createOpsBackend,
  lookupTaskHandler,
  opsApiTaskHandler,
  publicExampleTaskHandler,
} from "../../www/static/example_tasks.mjs";
import {
  applySetValue,
  beginComposition,
  blurInput,
  createControlledInputState,
  endComposition,
  focusInput,
  userInput,
} from "../../www/static/controlled_input_policy.mjs";
import {
  installDomDouble,
  findByText,
  findTextNode,
  findNode,
  findAll,
  fireEvent,
  ELEMENT_NODE,
} from "./dom_double.mjs";

const PAGE = 65536;
const CMD_BASE = 1024;
const STR_BASE = 16384;
const DYN_BASE = 24576;
const ERROR_BASE = 32768;
const STORAGE_DECL_BASE = 34816;
const DEFAULT_ALLOC_BASE = 40960;
const RECORD_WORDS = 6;

const encoder = new TextEncoder();
const decoder = new TextDecoder();

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
  detail: 5,
});

const unitEventExtractionPlan = new Uint8Array([BoundarySchemaTag.unit]);
const targetValueEventExtractionPlan = new Uint8Array([
  BoundarySchemaTag.text,
  EventExtractionSource.currentTarget,
  EventExtractionLeaf.value,
]);
const eventKeyEventExtractionPlan = new Uint8Array([
  BoundarySchemaTag.text,
  EventExtractionSource.event,
  EventExtractionLeaf.key,
]);
const eventDetailExtractionPlan = new Uint8Array([
  BoundarySchemaTag.text,
  EventExtractionSource.event,
  EventExtractionLeaf.detail,
]);
const keyShiftEventExtractionPlan = concatBytes([
  new Uint8Array([BoundarySchemaTag.record, 2]),
  fieldSpec("key", new Uint8Array([BoundarySchemaTag.text, EventExtractionSource.event, EventExtractionLeaf.key])),
  fieldSpec(
    "shift_key",
    new Uint8Array([BoundarySchemaTag.bool, EventExtractionSource.event, EventExtractionLeaf.shiftKey]),
  ),
]);

class MockHost {
  constructor({
    allocBase = DEFAULT_ALLOC_BASE,
    protocolVersion = Protocol.version,
    protocolFeatures = ProtocolFeature.dynamicAttrs | ProtocolFeature.dynamicEvents,
    storageDeclarations = [],
    debugAllocations = null,
    failAllocationNumber = null,
    maximumMemoryPages = undefined,
  } = {}) {
    this.memory = new WebAssembly.Memory({ initial: 1, ...(maximumMemoryPages === undefined ? {} : { maximum: maximumMemoryPages }) });
    this.cmdLen = 0;
    this.strLen = 0;
    this.dynamicLen = 0;
    this.lastErrorLen = 0;
    this.allocPtr = allocBase;
    this.allocationAttempts = 0;
    this.failAllocationNumber = failAllocationNumber;
    this.deallocCalls = [];
    this.protocolVersion = protocolVersion;
    this.protocolFeatures = protocolFeatures;
    this.dispatches = [];
    this.eventPayloadKinds = new Map();
    this.timers = [];
    this.resolutions = [];
    this.resolveTrapMessage = null;
    this.mountScript = [];
    this.eventResponses = new Map();
    this.eventResponseBits = new Map();
    this.eventTrapMessages = new Map();
    this.deallocTrapMessage = null;
    this.timerResponses = new Map();
    this.initialLocationPayload = null;
    this.initialVisibilityPayload = null;
    this.initialOnlinePayload = null;
    this.locationUpdatePayloads = [];
    this.visibilityUpdatePayloads = [];
    this.onlineUpdatePayloads = [];
    this.locationUpdateScript = [];
    this.visibilityUpdateScript = [];
    this.onlineUpdateScript = [];
    this.prepareMounts = 0;
    this.storageDeclarations = storageDeclarations.map((entry) => ({
      area: entry.area,
      key: String(entry.key),
      keyBytes: encoder.encode(String(entry.key)),
      keyPtr: 0,
    }));
    this.storagePayloads = [];
    this.writeStorageDeclarationKeys();

    this.exports = {
      memory: this.memory,
      roc_ui_protocol_version: () => this.protocolVersion,
      roc_ui_protocol_features: () => this.protocolFeatures,
      roc_ui_command_record_words: () => RECORD_WORDS,
      roc_ui_command_buffer_ptr: () => (this.cmdLen === 0 ? 0 : CMD_BASE),
      roc_ui_command_buffer_len: () => this.cmdLen,
      roc_ui_string_buffer_ptr: () => STR_BASE,
      roc_ui_string_buffer_len: () => this.strLen,
      roc_ui_dynamic_buffer_ptr: () => (this.dynamicLen === 0 ? 0 : DYN_BASE),
      roc_ui_dynamic_buffer_len: () => this.dynamicLen,
      roc_ui_last_error_ptr: () => (this.lastErrorLen === 0 ? 0 : ERROR_BASE),
      roc_ui_last_error_len: () => this.lastErrorLen,
      roc_ui_live_host_values: () => 0,
      roc_alloc: (len) => this.alloc(len),
      roc_dealloc: (ptr) => {
        this.deallocCalls.push(ptr);
        if (this.deallocTrapMessage !== null) {
          this.writeLastError(this.deallocTrapMessage);
          throw new WebAssembly.RuntimeError("unreachable");
        }
      },
      roc_ui_prepare_mount: () => {
        this.prepareMounts += 1;
      },
      roc_ui_storage_declaration_count: () => this.storageDeclarations.length,
      roc_ui_storage_declaration_area: (index) => this.storageDeclarations[index].area,
      roc_ui_storage_declaration_key_ptr: (index) => this.storageDeclarations[index].keyPtr,
      roc_ui_storage_declaration_key_len: (index) => this.storageDeclarations[index].keyBytes.length,
      roc_ui_set_storage_payload: (area, keyPtr, keyLen, payloadPtr, payloadLen) => {
        this.storagePayloads.push({
          area,
          key: decoder.decode(new Uint8Array(this.memory.buffer, keyPtr, keyLen)),
          payload: [...new Uint8Array(this.memory.buffer, payloadPtr, payloadLen)],
        });
      },
      roc_ui_mount: () => this.writeCommands(this.mountScript),
      roc_ui_set_location: (ptr, len) => {
        this.initialLocationPayload = [...new Uint8Array(this.memory.buffer, ptr, len)];
      },
      roc_ui_update_location: (ptr, len) => {
        this.locationUpdatePayloads.push([...new Uint8Array(this.memory.buffer, ptr, len)]);
        this.writeCommands(this.locationUpdateScript);
      },
      roc_ui_set_visibility: (ptr, len) => {
        this.initialVisibilityPayload = [...new Uint8Array(this.memory.buffer, ptr, len)];
      },
      roc_ui_update_visibility: (ptr, len) => {
        this.visibilityUpdatePayloads.push([...new Uint8Array(this.memory.buffer, ptr, len)]);
        this.writeCommands(this.visibilityUpdateScript);
      },
      roc_ui_set_online: (ptr, len) => {
        this.initialOnlinePayload = [...new Uint8Array(this.memory.buffer, ptr, len)];
      },
      roc_ui_update_online: (ptr, len) => {
        this.onlineUpdatePayloads.push([...new Uint8Array(this.memory.buffer, ptr, len)]);
        this.writeCommands(this.onlineUpdateScript);
      },
      roc_ui_unmount: () => {
        this.cmdLen = 0;
        this.strLen = 0;
        this.dynamicLen = 0;
      },
      roc_ui_timer: (token) => {
        this.timers.push(token);
        const respond = this.timerResponses.get(token);
        this.writeCommands(respond ? respond(token) : []);
      },
      roc_ui_resolve: (requestId, ptr, len, failed) => {
        this.resolutions.push({
          requestId,
          payload: decoder.decode(new Uint8Array(this.memory.buffer, ptr, len)),
          failed: failed !== 0,
        });
        if (this.resolveTrapMessage !== null) {
          this.writeLastError(this.resolveTrapMessage);
          throw new WebAssembly.RuntimeError("unreachable");
        }
        this.writeCommands([]);
      },
      roc_ui_event: (eventId, payloadKind, ptr, len, boolValue) => {
        const trapMessage = this.eventTrapMessages.get(eventId);
        if (trapMessage !== undefined) {
          this.writeLastError(trapMessage);
          throw new WebAssembly.RuntimeError("unreachable");
        }
        const expectedKind = this.eventPayloadKinds.get(eventId);
        if (expectedKind === undefined) {
          throw new Error(`mock host received event ${eventId} without a recorded payload descriptor`);
        }
        if (payloadKind !== expectedKind) {
          this.writeLastError("DOM event payload kind does not match Roc event descriptor");
          throw new WebAssembly.RuntimeError("unreachable");
        }
        const kind = payloadKind;
        const dispatch = { eventId, kind };
        if (kind === PayloadKind.str) {
          dispatch.payload = decoder.decode(new Uint8Array(this.memory.buffer, ptr, len));
        } else if (kind === PayloadKind.bool) {
          dispatch.payload = boolValue !== 0;
        } else if (kind === PayloadKind.bytes) {
          dispatch.payloadBytes = [...new Uint8Array(this.memory.buffer, ptr, len)];
        }
        this.dispatches.push(dispatch);
        const respond = this.eventResponses.get(eventId);
        this.writeCommands(respond ? respond(dispatch) : []);
        return this.eventResponseBits.get(eventId) ?? 0;
      },
    };
    if (debugAllocations !== null) {
      this.exports.roc_ui_debug_live_allocation_count = () => debugAllocations.length;
      this.exports.roc_ui_debug_live_allocation_bytes = () =>
        debugAllocations.reduce((total, allocation) => total + allocation.size, 0);
      this.exports.roc_ui_debug_live_allocation_size = (index) => debugAllocations[index]?.size ?? 0;
      this.exports.roc_ui_debug_live_allocation_phase = (index) => debugAllocations[index]?.phase ?? 0;
    }
  }

  writeStorageDeclarationKeys() {
    let offset = STORAGE_DECL_BASE;
    const memory = new Uint8Array(this.memory.buffer);
    for (const declaration of this.storageDeclarations) {
      declaration.keyPtr = offset;
      memory.set(declaration.keyBytes, offset);
      offset += declaration.keyBytes.length;
    }
  }

  writeLastError(message) {
    const bytes = encoder.encode(message);
    new Uint8Array(this.memory.buffer).set(bytes, ERROR_BASE);
    this.lastErrorLen = bytes.length;
  }

  alloc(len) {
    this.allocationAttempts += 1;
    if (this.allocationAttempts === this.failAllocationNumber) return 0;
    const ptr = this.allocPtr;
    const end = ptr + len;
    if (end > this.memory.buffer.byteLength) {
      try {
        this.memory.grow(Math.ceil((end - this.memory.buffer.byteLength) / PAGE));
      } catch (err) {
        if (err instanceof RangeError) return 0;
        throw err;
      }
    }
    this.allocPtr = end;
    return ptr;
  }

  writeCommands(script) {
    const view = new DataView(this.memory.buffer);
    const bytes = new Uint8Array(this.memory.buffer);
    let strOffset = 0;
    let dynamicOffset = 0;
    script.forEach((entry, index) => {
      this.noteEventBinding(entry);
      let op = entry.op;
      let { a = 0, b = 0, c = 0, d = 0, e = 0 } = entry;
      if (entry.strings !== undefined) {
        const [first, second] = entry.strings.map((value) => encoder.encode(value));
        bytes.set(first, STR_BASE + strOffset);
        b = strOffset;
        c = first.length;
        strOffset += first.length;
        bytes.set(second, STR_BASE + strOffset);
        d = strOffset;
        e = second.length;
        strOffset += second.length;
      } else if (entry.s !== undefined) {
        const encoded = encoder.encode(entry.s);
        bytes.set(encoded, STR_BASE + strOffset);
        if (entry.op === Op.pushState || entry.op === Op.replaceState) {
          a = strOffset;
          b = encoded.length;
        } else {
          b = strOffset;
          c = encoded.length;
        }
        strOffset += encoded.length;
      }
      if (entry.dynamic !== undefined || entry.dynamicBytes !== undefined) {
        const encoded =
          entry.dynamicBytes === undefined
            ? encodeDynamicRecord(entry.dynamic)
            : toUint8Array(entry.dynamicBytes);
        bytes.set(encoded, DYN_BASE + dynamicOffset);
        op = Op.extended;
        a = dynamicOffset;
        b = entry.dynamicLength ?? encoded.length;
        dynamicOffset += encoded.length;
      }
      const base = CMD_BASE + index * RECORD_WORDS * 4;
      view.setUint32(base, op, true);
      view.setUint32(base + 4, a, true);
      view.setUint32(base + 8, b, true);
      view.setUint32(base + 12, c, true);
      view.setUint32(base + 16, d, true);
      view.setUint32(base + 20, e, true);
    });
    this.cmdLen = script.length;
    this.strLen = strOffset;
    this.dynamicLen = dynamicOffset;
  }

  noteEventBinding(entry) {
    if (entry.dynamic?.op === DynamicOp.bindEvent) {
      const payloadKind = payloadKindForTestExtractionPlan(entry.dynamic.eventExtractionPlan);
      if (payloadKind !== undefined) {
        this.eventPayloadKinds.set(entry.dynamic.eventId, payloadKind);
      }
      return;
    }

    switch (entry.op) {
      case Op.bindClick:
      case Op.bindInput:
      case Op.bindCheck:
      case Op.bindPointerDown:
      case Op.bindPointerUp:
      case Op.bindPointerEnter:
      case Op.bindPointerLeave:
        this.eventPayloadKinds.set(entry.b, payloadKindForFixedEventOp(entry.op));
        return;

      default:
        return;
    }
  }
}

function encodeDynamicRecord(spec) {
  const payload = spec.payloadBytes === undefined ? encodeDynamicPayload(spec) : toUint8Array(spec.payloadBytes);
  const totalLen = 8 + align4(payload.length);
  const out = new Uint8Array(totalLen);
  const view = new DataView(out.buffer);
  view.setUint16(0, spec.op, true);
  view.setUint16(2, spec.flags ?? 0, true);
  view.setUint32(4, payload.length, true);
  out.set(payload, 8);
  return out;
}

function encodeDynamicPayload(spec) {
  switch (spec.op) {
    case DynamicOp.setAttrText:
      return concatBytes([
        u32Bytes(spec.elemId),
        stringBytes(spec.name),
        stringBytes(spec.value),
      ]);

    case DynamicOp.removeAttr:
      return concatBytes([u32Bytes(spec.elemId), stringBytes(spec.name)]);

    case DynamicOp.bindEvent:
      const delivery = spec.delivery ?? deliveryForTestBinding(spec);
      return concatBytes([
        u32Bytes(spec.elemId),
        u32Bytes(spec.eventId),
        stringBytes(spec.eventName),
        u32Bytes(spec.options ?? 0),
        u32Bytes(delivery.requested),
        u32Bytes(delivery.effective),
        u32Bytes(delivery.reason),
        bytesField(spec.eventExtractionPlan),
      ]);

    case DynamicOp.clearEvent:
      return concatBytes([u32Bytes(spec.elemId), stringBytes(spec.eventName)]);

    default:
      return new Uint8Array(0);
  }
}

function deliveryForTestBinding(spec) {
  return {
    requested: EventDeliveryRequestWire.auto,
    effective: EventDeliveryEffectiveWire.native,
    reason: nativeDeliveryReasonForTestBinding(spec),
  };
}

function nativeDeliveryReasonForTestBinding(spec) {
  const options = spec.options ?? 0;
  if ((options & ListenerOptions.capture) !== 0) return EventDeliveryReasonWire.capturePolicy;
  if ((options & ListenerOptions.stopImmediatePropagation) !== 0) return EventDeliveryReasonWire.stopImmediatePolicy;
  if ((options & ListenerOptions.stopPropagation) !== 0) return EventDeliveryReasonWire.stopPropagationPolicy;
  if ((options & ListenerOptions.preventDefault) !== 0) return EventDeliveryReasonWire.preventDefaultPolicy;
  if ((options & ListenerOptions.once) !== 0) return EventDeliveryReasonWire.oncePolicy;
  if ((options & ListenerOptions.passive) !== 0) return EventDeliveryReasonWire.passivePolicy;
  if ((options & ListenerOptions.self) !== 0) return EventDeliveryReasonWire.selfFilter;
  return EventDeliveryReasonWire.nativeRuntimeDefault;
}

function payloadKindForFixedEventOp(op) {
  switch (op) {
    case Op.bindClick:
    case Op.bindPointerDown:
    case Op.bindPointerUp:
    case Op.bindPointerEnter:
    case Op.bindPointerLeave:
      return PayloadKind.unit;

    case Op.bindInput:
      return PayloadKind.str;

    case Op.bindCheck:
      return PayloadKind.bool;

    default:
      return undefined;
  }
}

function payloadKindForTestExtractionPlan(value) {
  const bytes = toUint8Array(value);
  switch (bytes[0]) {
    case BoundarySchemaTag.unit:
      return PayloadKind.unit;
    case BoundarySchemaTag.text:
      return PayloadKind.str;
    case BoundarySchemaTag.bool:
      return PayloadKind.bool;
    case BoundarySchemaTag.record:
      return PayloadKind.bytes;
    default:
      return undefined;
  }
}

function stringBytes(value) {
  const bytes = encoder.encode(value);
  return concatBytes([u32Bytes(bytes.length), bytes]);
}

function bytesField(value) {
  const bytes = toUint8Array(value);
  return concatBytes([u32Bytes(bytes.length), bytes]);
}

function fieldSpec(name, spec) {
  const nameBytes = encoder.encode(name);
  return concatBytes([new Uint8Array([nameBytes.length]), nameBytes, spec]);
}

function keyShiftBytes(key, shiftKey) {
  const keyBytes = encoder.encode(key);
  return [...concatBytes([u32Bytes(keyBytes.length), keyBytes, new Uint8Array([shiftKey ? 1 : 0])])];
}

function allocBaseLeavingOneByteAfterInitialEnvironment() {
  const defaultLocation = { path: "/", query: "", hash: "" };
  return (
    PAGE -
    encodeBoundarySchemaPayloadBytes(LocationBoundarySchema, defaultLocation).length -
    encodeBoundarySchemaPayloadBytes(VisibilityBoundarySchema, true).length -
    encodeBoundarySchemaPayloadBytes(OnlineBoundarySchema, true).length -
    1
  );
}

function u32Bytes(value) {
  const out = new Uint8Array(4);
  new DataView(out.buffer).setUint32(0, value, true);
  return out;
}

function concatBytes(chunks) {
  const len = chunks.reduce((sum, chunk) => sum + chunk.length, 0);
  const out = new Uint8Array(len);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.length;
  }
  return out;
}

function align4(value) {
  return (value + 3) & ~3;
}

function toUint8Array(value) {
  return value instanceof Uint8Array ? value : new Uint8Array(value);
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
    listeners(type) {
      return [...(listeners.get(type) ?? [])];
    },
    listenerCount(type) {
      return listeners.get(type)?.length ?? 0;
    },
  };
}

function createStorageDouble(initial = {}) {
  const values = new Map(Object.entries(initial));
  const calls = [];
  return {
    calls,
    getItem(key) {
      const normalized = String(key);
      return values.has(normalized) ? values.get(normalized) : null;
    },
    setItem(key, value) {
      calls.push(["set", String(key), String(value)]);
      values.set(String(key), String(value));
    },
    removeItem(key) {
      calls.push(["remove", String(key)]);
      values.delete(String(key));
    },
    dump() {
      return Object.fromEntries(values.entries());
    },
  };
}

function mountWith(mountScript, options = {}) {
  const {
    taskHandler,
    onError,
    telemetry,
    behaviors,
    location,
    history,
    eventTarget,
    document,
    visibilityDocument,
    navigator,
    networkEventTarget,
    localStorage,
    sessionStorage,
    storage,
    limits,
    ...hostOptions
  } = options;
  const host = new MockHost(hostOptions);
  host.mountScript = mountScript;
  const root = installDomDouble();
  const runtime = new SignalsRuntime(host.exports, root, {
    taskHandler,
    onError,
    telemetry,
    behaviors,
    location,
    history,
    eventTarget,
    document,
    visibilityDocument,
    navigator,
    networkEventTarget,
    localStorage,
    sessionStorage,
    storage,
    limits,
  });
  runtime.mount();
  return { host, root, runtime };
}

test("controlled input policy writes unfocused SetValue immediately", () => {
  const state = createControlledInputState("old");

  const op = applySetValue(state, "new");

  assert.equal(op.status, "wrote");
  assert.equal(state.value, "new");
  assert.equal(state.pendingValue, null);
});

test("controlled input policy clears stale pending state on equal SetValue", () => {
  const state = createControlledInputState("text");
  focusInput(state, 2, 2);

  const deferred = applySetValue(state, "server-text");
  assert.equal(deferred.status, "deferred");
  assert.equal(state.pendingValue, "server-text");

  userInput(state, "server-text", 11, 11);
  const echo = applySetValue(state, "server-text");

  assert.equal(echo.status, "skipped");
  assert.equal(echo.reason, "equal");
  assert.equal(state.pendingValue, null);
  assert.equal(state.selectionStart, 11);
  assert.equal(state.selectionEnd, 11);
});

test("controlled input policy defers focused differing SetValue", () => {
  const state = createControlledInputState("abcdef");
  focusInput(state, 3, 3);

  const op = applySetValue(state, "abcXYZdef");

  assert.equal(op.status, "deferred");
  assert.equal(op.reason, "focused");
  assert.equal(state.value, "abcdef");
  assert.equal(state.pendingValue, "abcXYZdef");
  assert.equal(state.selectionStart, 3);
  assert.equal(state.selectionEnd, 3);
});

test("controlled input policy defers composition writes until blur", () => {
  const state = createControlledInputState("");
  focusInput(state, 0, 0);
  beginComposition(state);
  userInput(state, "に", 1, 1);

  const composing = applySetValue(state, "host");
  assert.equal(composing.status, "deferred");
  assert.equal(composing.reason, "composing");
  assert.equal(state.value, "に");
  assert.equal(state.pendingValue, "host");

  const stillFocused = endComposition(state);
  assert.equal(stillFocused.status, "deferred");
  assert.equal(stillFocused.reason, "focused");
  assert.equal(state.value, "に");

  const blurred = blurInput(state);
  assert.equal(blurred.status, "wrote");
  assert.equal(state.value, "host");
  assert.equal(state.pendingValue, null);
});

test("controlled input policy clears pending write when user typed it", () => {
  const state = createControlledInputState("a");
  focusInput(state, 1, 1);

  const deferred = applySetValue(state, "abc");
  assert.equal(deferred.status, "deferred");
  assert.equal(state.pendingValue, "abc");

  userInput(state, "abc", 3, 3);
  const blurred = blurInput(state);

  assert.equal(blurred.status, "skipped");
  assert.equal(blurred.reason, "no-pending");
  assert.equal(state.value, "abc");
});

test("protocol checks reject incompatible wasm exports", () => {
  assert.throws(
    () => new SignalsRuntime(new MockHost({ protocolVersion: Protocol.version + 1 }).exports, installDomDouble()),
    /wire protocol version mismatch/,
  );
  assert.throws(
    () => new SignalsRuntime(new MockHost({ protocolFeatures: 0 }).exports, installDomDouble()),
    /wire protocol feature mismatch/,
  );

  const host = new MockHost();
  delete host.exports.roc_ui_protocol_features;
  assert.throws(
    () => new SignalsRuntime(host.exports, installDomDouble()),
    /roc_ui_protocol_features is missing/,
  );

  const missingDynamic = new MockHost();
  delete missingDynamic.exports.roc_ui_dynamic_buffer_ptr;
  assert.throws(
    () => new SignalsRuntime(missingDynamic.exports, installDomDouble()),
    /roc_ui_dynamic_buffer_ptr is missing/,
  );
});

test("location boundary schema encodes normalized URL pieces", () => {
  const snapshot = locationSnapshotFromHref(
    "../orders/42?tab=events&region=apac#deploys",
    "https://ops.example.test/apps/service/",
  );

  assert.deepEqual(snapshot, {
    path: "/apps/orders/42",
    query: "tab=events&region=apac",
    hash: "deploys",
  });
  assert.deepEqual(
    [...encodeBoundarySchemaPayloadBytes(LocationBoundarySchema, snapshot)],
    [
      ...stringBytes("/apps/orders/42"),
      ...stringBytes("tab=events&region=apac"),
      ...stringBytes("deploys"),
    ],
  );
  assert.throws(
    () => encodeBoundarySchemaPayloadBytes(LocationBoundarySchema, { path: "/x", query: "", hash: 7 }),
    /payload\.hash expected text boundary value/,
  );
});

test("visibility boundary schema encodes document visibility", () => {
  assert.equal(visibilitySnapshotFromDocument({ visibilityState: "visible" }), true);
  assert.equal(visibilitySnapshotFromDocument({ visibilityState: "hidden" }), false);
  assert.equal(visibilitySnapshotFromDocument({}), true);
  assert.deepEqual([...encodeBoundarySchemaPayloadBytes(VisibilityBoundarySchema, true)], [1]);
  assert.deepEqual([...encodeBoundarySchemaPayloadBytes(VisibilityBoundarySchema, false)], [0]);
  assert.throws(
    () => encodeBoundarySchemaPayloadBytes(VisibilityBoundarySchema, "visible"),
    /payload expected bool boundary value/,
  );
});

test("online boundary schema encodes navigator status", () => {
  assert.equal(onlineSnapshotFromNavigator({ onLine: true }), true);
  assert.equal(onlineSnapshotFromNavigator({ onLine: false }), false);
  assert.equal(onlineSnapshotFromNavigator({}), true);
  assert.deepEqual([...encodeBoundarySchemaPayloadBytes(OnlineBoundarySchema, true)], [1]);
  assert.deepEqual([...encodeBoundarySchemaPayloadBytes(OnlineBoundarySchema, false)], [0]);
  assert.throws(
    () => encodeBoundarySchemaPayloadBytes(OnlineBoundarySchema, "online"),
    /payload expected bool boundary value/,
  );
});

test("storage payload encoder surfaces missing value and unavailable snapshots", () => {
  assert.deepEqual([...encodeStoragePayloadBytes({ kind: "missing" })], [0]);
  assert.deepEqual(
    [...encodeStoragePayloadBytes({ kind: "value", value: "draft" })],
    [1, ...stringBytes("draft")],
  );
  assert.deepEqual(
    [...encodeStoragePayloadBytes({ kind: "unavailable", message: "blocked" })],
    [2, ...stringBytes("blocked")],
  );
  assert.throws(
    () => encodeStoragePayloadBytes({ kind: "unknown" }),
    /unknown storage payload snapshot/,
  );
});

test("mount seeds wasm host with initial location visibility and online snapshots", () => {
  const telemetry = [];
  const { host } = mountWith([], {
    location: { href: "https://ops.example.test/services/api?tab=logs#tail" },
    visibilityDocument: { visibilityState: "hidden" },
    navigator: { onLine: false },
    telemetry: (entry) => telemetry.push(entry),
  });

  assert.deepEqual(host.initialLocationPayload, [
    ...stringBytes("/services/api"),
    ...stringBytes("tab=logs"),
    ...stringBytes("tail"),
  ]);
  assert.deepEqual(host.initialVisibilityPayload, [0]);
  assert.deepEqual(host.initialOnlinePayload, [0]);
  assert.ok(
    telemetry.some(
      (entry) =>
        entry.kind === "environment_snapshot" &&
        entry.location.path === "/services/api" &&
        entry.location.query === "tab=logs" &&
        entry.location.hash === "tail",
    ),
  );
  assert.ok(
    telemetry.some(
      (entry) => entry.kind === "environment_snapshot" && entry.visibility === false && entry.payloadLen === 1,
    ),
  );
  assert.ok(
    telemetry.some((entry) => entry.kind === "environment_snapshot" && entry.online === false && entry.payloadLen === 1),
  );
});

test("mount seeds wasm host with declared storage snapshots before first render", () => {
  const telemetry = [];
  const localStorage = createStorageDouble({ "checkout:draft": "seeded local" });
  const sessionStorage = createStorageDouble({ "checkout:flash": "seeded flash" });
  const { host } = mountWith([], {
    storageDeclarations: [
      { area: StorageArea.local, key: "checkout:draft" },
      { area: StorageArea.session, key: "checkout:flash" },
      { area: StorageArea.local, key: "checkout:missing" },
    ],
    localStorage,
    sessionStorage,
    telemetry: (entry) => telemetry.push(entry),
  });

  assert.equal(host.prepareMounts, 1);
  assert.deepEqual(host.storagePayloads, [
    {
      area: StorageArea.local,
      key: "checkout:draft",
      payload: [...encodeStoragePayloadBytes({ kind: "value", value: "seeded local" })],
    },
    {
      area: StorageArea.session,
      key: "checkout:flash",
      payload: [...encodeStoragePayloadBytes({ kind: "value", value: "seeded flash" })],
    },
    {
      area: StorageArea.local,
      key: "checkout:missing",
      payload: [...encodeStoragePayloadBytes({ kind: "missing" })],
    },
  ]);

  assert.deepEqual(
    telemetry
      .filter((entry) => entry.kind === "storage_snapshot")
      .map((entry) => ({ area: entry.area, key: entry.key, snapshotKind: entry.snapshotKind, value: entry.value })),
    [
      { area: StorageArea.local, key: "checkout:draft", snapshotKind: "value", value: undefined },
      { area: StorageArea.session, key: "checkout:flash", snapshotKind: "value", value: undefined },
      { area: StorageArea.local, key: "checkout:missing", snapshotKind: "missing", value: undefined },
    ],
  );
});

test("popstate updates wasm location source and drains render commands", () => {
  const telemetry = [];
  const eventTarget = createEventTargetDouble();
  const location = { href: "https://ops.example.test/" };
  const { host, root } = mountWith(
    [
      { op: Op.resetDom },
      { op: Op.createText, a: 1, s: "Path: /" },
      { op: Op.appendChild, a: 0, b: 1 },
    ],
    {
      location,
      eventTarget,
      telemetry: (entry) => telemetry.push(entry),
    },
  );
  host.locationUpdateScript = [{ op: Op.setText, a: 1, s: "Path: /services/api" }];

  assert.equal(eventTarget.listenerCount("popstate"), 1);
  location.href = "https://ops.example.test/services/api?tab=logs#tail";
  eventTarget.dispatch("popstate");

  assert.deepEqual(host.locationUpdatePayloads, [
    [
      ...stringBytes("/services/api"),
      ...stringBytes("tab=logs"),
      ...stringBytes("tail"),
    ],
  ]);
  assert.ok(findTextNode(root, "Path: /services/api"));
  assert.ok(
    telemetry.some(
      (entry) =>
        entry.kind === "location_update" &&
        entry.trigger === "popstate" &&
        entry.location.path === "/services/api" &&
        entry.location.query === "tab=logs" &&
        entry.location.hash === "tail",
    ),
  );
  const commands = telemetry.find((entry) => entry.kind === "commands" && entry.phase === "popstate:1");
  assert.equal(commands.opCounts.set_text, 1);
});

test("popstate listener is removed on unmount and stale dispatches are ignored", () => {
  const telemetry = [];
  const eventTarget = createEventTargetDouble();
  const { host, runtime } = mountWith([{ op: Op.resetDom }], {
    eventTarget,
    telemetry: (entry) => telemetry.push(entry),
  });
  const staleListener = eventTarget.listeners("popstate")[0];

  runtime.unmount();
  assert.equal(eventTarget.listenerCount("popstate"), 0);
  staleListener();

  assert.deepEqual(host.locationUpdatePayloads, []);
  assert.ok(
    telemetry.some(
      (entry) =>
        entry.kind === "ignored_popstate" &&
        entry.reason === "unmounted" &&
        entry.generation === 1 &&
        entry.currentGeneration === 1,
    ),
  );

  runtime.mount();
  assert.equal(eventTarget.listenerCount("popstate"), 1);
  staleListener();
  assert.deepEqual(host.locationUpdatePayloads, []);
  assert.ok(
    telemetry.some(
      (entry) =>
        entry.kind === "ignored_popstate" &&
        entry.reason === "stale_generation" &&
        entry.generation === 1 &&
        entry.currentGeneration === 2,
    ),
  );
  runtime.unmount();
});

test("visibilitychange updates wasm visibility source and drains render commands", () => {
  const telemetry = [];
  const visibilityDocument = createEventTargetDouble();
  visibilityDocument.visibilityState = "visible";
  const { host, root } = mountWith(
    [
      { op: Op.resetDom },
      { op: Op.createText, a: 1, s: "Visible" },
      { op: Op.appendChild, a: 0, b: 1 },
    ],
    {
      document: visibilityDocument,
      telemetry: (entry) => telemetry.push(entry),
    },
  );
  host.visibilityUpdateScript = [{ op: Op.setText, a: 1, s: "Hidden" }];

  assert.equal(visibilityDocument.listenerCount("visibilitychange"), 1);
  visibilityDocument.visibilityState = "hidden";
  visibilityDocument.dispatch("visibilitychange");

  assert.deepEqual(host.visibilityUpdatePayloads, [[0]]);
  assert.ok(findTextNode(root, "Hidden"));
  assert.ok(
    telemetry.some(
      (entry) =>
        entry.kind === "visibility_update" &&
        entry.trigger === "visibilitychange" &&
        entry.visibility === false,
    ),
  );
  const commands = telemetry.find((entry) => entry.kind === "commands" && entry.phase === "visibilitychange:1");
  assert.equal(commands.opCounts.set_text, 1);
});

test("visibilitychange listener is removed on unmount and stale dispatches are ignored", () => {
  const telemetry = [];
  const visibilityDocument = createEventTargetDouble();
  visibilityDocument.visibilityState = "visible";
  const { host, runtime } = mountWith([{ op: Op.resetDom }], {
    document: visibilityDocument,
    telemetry: (entry) => telemetry.push(entry),
  });
  const staleListener = visibilityDocument.listeners("visibilitychange")[0];

  runtime.unmount();
  assert.equal(visibilityDocument.listenerCount("visibilitychange"), 0);
  staleListener();

  assert.deepEqual(host.visibilityUpdatePayloads, []);
  assert.ok(
    telemetry.some(
      (entry) =>
        entry.kind === "ignored_visibilitychange" &&
        entry.reason === "unmounted" &&
        entry.generation === 1 &&
        entry.currentGeneration === 1,
    ),
  );

  runtime.mount();
  assert.equal(visibilityDocument.listenerCount("visibilitychange"), 1);
  staleListener();
  assert.deepEqual(host.visibilityUpdatePayloads, []);
  assert.ok(
    telemetry.some(
      (entry) =>
        entry.kind === "ignored_visibilitychange" &&
        entry.reason === "stale_generation" &&
        entry.generation === 1 &&
        entry.currentGeneration === 2,
    ),
  );
  runtime.unmount();
});

test("online and offline events update wasm online source and drain render commands", () => {
  const telemetry = [];
  const networkEventTarget = createEventTargetDouble();
  const navigator = { onLine: true };
  const { host, root } = mountWith(
    [
      { op: Op.resetDom },
      { op: Op.createText, a: 1, s: "Online" },
      { op: Op.appendChild, a: 0, b: 1 },
    ],
    {
      navigator,
      networkEventTarget,
      telemetry: (entry) => telemetry.push(entry),
    },
  );
  host.onlineUpdateScript = [{ op: Op.setText, a: 1, s: "Offline" }];

  assert.equal(networkEventTarget.listenerCount("online"), 1);
  assert.equal(networkEventTarget.listenerCount("offline"), 1);
  navigator.onLine = false;
  networkEventTarget.dispatch("offline");

  assert.deepEqual(host.onlineUpdatePayloads, [[0]]);
  assert.ok(findTextNode(root, "Offline"));
  assert.ok(
    telemetry.some(
      (entry) => entry.kind === "online_update" && entry.trigger === "offline" && entry.online === false,
    ),
  );
  const commands = telemetry.find((entry) => entry.kind === "commands" && entry.phase === "onlinechange:1");
  assert.equal(commands.opCounts.set_text, 1);
});

test("online listeners are removed on unmount and stale dispatches are ignored", () => {
  const telemetry = [];
  const networkEventTarget = createEventTargetDouble();
  const navigator = { onLine: true };
  const { host, runtime } = mountWith([{ op: Op.resetDom }], {
    navigator,
    networkEventTarget,
    telemetry: (entry) => telemetry.push(entry),
  });
  const staleOfflineListener = networkEventTarget.listeners("offline")[0];

  runtime.unmount();
  assert.equal(networkEventTarget.listenerCount("online"), 0);
  assert.equal(networkEventTarget.listenerCount("offline"), 0);
  staleOfflineListener();

  assert.deepEqual(host.onlineUpdatePayloads, []);
  assert.ok(
    telemetry.some(
      (entry) =>
        entry.kind === "ignored_onlinechange" &&
        entry.reason === "unmounted" &&
        entry.trigger === "offline" &&
        entry.generation === 1 &&
        entry.currentGeneration === 1,
    ),
  );

  runtime.mount();
  assert.equal(networkEventTarget.listenerCount("online"), 1);
  assert.equal(networkEventTarget.listenerCount("offline"), 1);
  staleOfflineListener();
  assert.deepEqual(host.onlineUpdatePayloads, []);
  assert.ok(
    telemetry.some(
      (entry) =>
        entry.kind === "ignored_onlinechange" &&
        entry.reason === "stale_generation" &&
        entry.trigger === "offline" &&
        entry.generation === 1 &&
        entry.currentGeneration === 2,
    ),
  );
  runtime.unmount();
});

test("command opcodes map to the expected DOM operations", () => {
  const { root } = mountWith([
    { op: Op.resetDom },
    { op: Op.createElement, a: 1, s: "section" },
    { op: Op.appendChild, a: 0, b: 1 },
    { op: Op.createElement, a: 2, s: "input" },
    { op: Op.setValue, a: 2, s: "hello" },
    { op: Op.setChecked, a: 2, b: 1 },
    { op: Op.setDisabled, a: 2, b: 1 },
    { op: Op.setRole, a: 2, s: "textbox" },
    { op: Op.setLabel, a: 2, s: "Name" },
    { op: Op.setTestId, a: 2, s: "name-field" },
    { op: Op.setClass, a: 2, s: "rounded-md border-zinc-300" },
    { op: Op.appendChild, a: 1, b: 2 },
    { op: Op.createText, a: 3, s: "before" },
    { op: Op.appendChild, a: 1, b: 3 },
    { op: Op.createElement, a: 4, s: "span" },
    { op: Op.setText, a: 4, s: "label" },
    { op: Op.appendChild, a: 1, b: 4 },
    { op: Op.moveBefore, a: 1, b: 4, c: 2 },
    { op: Op.removeNode, a: 3 },
  ]);

  const section = findNode(root, (node) => node.tagName === "SECTION");
  const input = findNode(root, (node) => node.tagName === "INPUT");

  assert.deepEqual(
    section.childNodes
      .filter((node) => node.nodeType === ELEMENT_NODE)
      .map((node) => node.tagName),
    ["SPAN", "INPUT"],
  );
  assert.equal(input.value, "hello");
  assert.equal(input.checked, true);
  assert.equal(input.disabled, true);
  assert.equal(input.getAttribute("role"), "textbox");
  assert.equal(input.getAttribute("aria-label"), "Name");
  assert.equal(input.getAttribute("data-testid"), "name-field");
  assert.equal(input.getAttribute("class"), "rounded-md border-zinc-300");
  assert.equal(findTextNode(root, "before"), null);
});

test("navigation opcodes call browser history and emit telemetry", () => {
  const calls = [];
  const telemetry = [];
  mountWith(
    [
      { op: Op.pushState, s: "/services/api?tab=logs#tail" },
      { op: Op.replaceState, s: "/services/web" },
    ],
    {
      history: {
        pushState: (state, title, href) => calls.push(["push", state, title, href]),
        replaceState: (state, title, href) => calls.push(["replace", state, title, href]),
      },
      telemetry: (entry) => telemetry.push(entry),
    },
  );

  assert.deepEqual(calls, [
    ["push", null, "", "/services/api?tab=logs#tail"],
    ["replace", null, "", "/services/web"],
  ]);
  assert.deepEqual(
    telemetry
      .filter((entry) => entry.kind === "navigation")
      .map((entry) => ({ kind: entry.kind, mode: entry.mode, href: entry.href })),
    [
      { kind: "navigation", mode: "push", href: "/services/api?tab=logs#tail" },
      { kind: "navigation", mode: "replace", href: "/services/web" },
    ],
  );
  const commands = telemetry.find((entry) => entry.kind === "commands" && entry.phase === "mount");
  assert.equal(commands.opCounts.push_state, 1);
  assert.equal(commands.opCounts.replace_state, 1);
});

test("document title opcode updates document title and emits telemetry", () => {
  const document = { title: "Initial" };
  const telemetry = [];
  mountWith([{ op: Op.setDocumentTitle, s: "api service detail - Service Ops Center" }], {
    document,
    telemetry: (entry) => telemetry.push(entry),
  });

  assert.equal(document.title, "api service detail - Service Ops Center");
  assert.deepEqual(
    telemetry
      .filter((entry) => entry.kind === "document_title")
      .map((entry) => ({ kind: entry.kind, title: entry.title })),
    [{ kind: "document_title", title: "api service detail - Service Ops Center" }],
  );
  const commands = telemetry.find((entry) => entry.kind === "commands" && entry.phase === "mount");
  assert.equal(commands.opCounts.set_document_title, 1);
  assert.deepEqual(
    commands.commands.filter((command) => command.op === "set_document_title"),
    [{ op: "set_document_title", title: "api service detail - Service Ops Center" }],
  );
});

test("storage commands coalesce by area and key before touching browser storage", () => {
  const localStorage = createStorageDouble({
    "checkout:draft": "old",
    "checkout:remove": "keep",
  });
  const sessionStorage = createStorageDouble({ "checkout:flash": "shown" });
  const telemetry = [];
  const { host, runtime } = mountWith([], {
    localStorage,
    sessionStorage,
    telemetry: (entry) => telemetry.push(entry),
  });

  host.writeCommands([
    { op: Op.setStorageText, a: StorageArea.local, strings: ["checkout:draft", "first"] },
    { op: Op.setStorageText, a: StorageArea.local, strings: ["checkout:draft", "second"] },
    { op: Op.removeStorage, a: StorageArea.session, s: "checkout:flash" },
    { op: Op.setStorageText, a: StorageArea.local, strings: ["checkout:cleanup", "temp"] },
    { op: Op.removeStorage, a: StorageArea.local, s: "checkout:cleanup" },
    { op: Op.removeStorage, a: StorageArea.local, s: "checkout:remove" },
  ]);
  runtime.applyPendingCommands("storage-drain");

  assert.equal(localStorage.getItem("checkout:draft"), "second");
  assert.equal(localStorage.getItem("checkout:cleanup"), null);
  assert.equal(localStorage.getItem("checkout:remove"), null);
  assert.equal(sessionStorage.getItem("checkout:flash"), null);
  assert.deepEqual(localStorage.calls, [
    ["set", "checkout:draft", "second"],
    ["remove", "checkout:cleanup"],
    ["remove", "checkout:remove"],
  ]);
  assert.deepEqual(sessionStorage.calls, [["remove", "checkout:flash"]]);

  const commandTelemetry = telemetry.find(
    (entry) => entry.kind === "commands" && entry.phase === "storage-drain",
  );
  assert.equal(commandTelemetry.opCounts.set_storage_text, 3);
  assert.equal(commandTelemetry.opCounts.remove_storage, 3);

  const storageTelemetry = telemetry
    .filter((entry) => entry.kind === "storage")
    .map((entry) => ({ mode: entry.mode, area: entry.area, key: entry.key, value: entry.value }));
  assert.deepEqual(storageTelemetry, [
    { mode: "set", area: StorageArea.local, key: "checkout:draft", value: undefined },
    { mode: "remove", area: StorageArea.session, key: "checkout:flash", value: undefined },
    { mode: "remove", area: StorageArea.local, key: "checkout:cleanup", value: undefined },
    { mode: "remove", area: StorageArea.local, key: "checkout:remove", value: undefined },
  ]);
});

test("storage commands fail clearly when browser storage is unavailable", () => {
  const { host, runtime } = mountWith([], {
    localStorage: {
      getItem() {
        return null;
      },
    },
  });

  host.writeCommands([
    { op: Op.setStorageText, a: StorageArea.local, strings: ["checkout:draft", "saved"] },
  ]);

  assert.throws(
    () => runtime.applyPendingCommands("storage-unavailable"),
    /browser storage setItem is unavailable/,
  );
});

test("focused SetValue patches are deferred until blur", () => {
  const { host, root, runtime } = mountWith([
    { op: Op.resetDom },
    { op: Op.createElement, a: 1, s: "input" },
    { op: Op.setValue, a: 1, s: "old" },
    { op: Op.appendChild, a: 0, b: 1 },
  ]);
  const input = findNode(root, (node) => node.tagName === "INPUT");

  fireEvent(input, "focus");
  input.value = "typed";
  fireEvent(input, "input");

  host.writeCommands([{ op: Op.setValue, a: 1, s: "host" }]);
  runtime.applyPendingCommands("host-update");
  assert.equal(input.value, "typed");

  fireEvent(input, "blur");
  assert.equal(input.value, "host");
});

test("focused SetValue patches apply the latest deferred value on blur", () => {
  const { host, root, runtime } = mountWith([
    { op: Op.resetDom },
    { op: Op.createElement, a: 1, s: "input" },
    { op: Op.setValue, a: 1, s: "old" },
    { op: Op.appendChild, a: 0, b: 1 },
  ]);
  const input = findNode(root, (node) => node.tagName === "INPUT");

  fireEvent(input, "focus");
  input.value = "draft";
  fireEvent(input, "input");

  host.writeCommands([{ op: Op.setValue, a: 1, s: "canonical-a" }]);
  runtime.applyPendingCommands("canonical-a");
  assert.equal(input.value, "draft");

  host.writeCommands([{ op: Op.setValue, a: 1, s: "canonical-b" }]);
  runtime.applyPendingCommands("canonical-b");
  assert.equal(input.value, "draft");

  fireEvent(input, "blur");
  assert.equal(input.value, "canonical-b");
});

test("composition keeps SetValue patches deferred while focused", () => {
  const { host, root, runtime } = mountWith([
    { op: Op.resetDom },
    { op: Op.createElement, a: 1, s: "input" },
    { op: Op.bindInput, a: 1, b: 10 },
    { op: Op.appendChild, a: 0, b: 1 },
  ]);
  const input = findNode(root, (node) => node.tagName === "INPUT");

  fireEvent(input, "focus");
  fireEvent(input, "compositionstart");
  input.value = "に";
  fireEvent(input, "input");

  host.writeCommands([{ op: Op.setValue, a: 1, s: "host" }]);
  runtime.applyPendingCommands("host-update");
  assert.equal(input.value, "に");

  fireEvent(input, "compositionend");
  assert.equal(input.value, "に");

  fireEvent(input, "blur");
  assert.equal(input.value, "host");
});

test("remove_node clears controlled input pending state and listeners", () => {
  const { host, root, runtime } = mountWith([
    { op: Op.resetDom },
    { op: Op.createElement, a: 1, s: "input" },
    { op: Op.setValue, a: 1, s: "old" },
    { op: Op.appendChild, a: 0, b: 1 },
  ]);
  const removedInput = findNode(root, (node) => node.tagName === "INPUT");

  fireEvent(removedInput, "focus");
  removedInput.value = "draft";
  fireEvent(removedInput, "input");

  host.writeCommands([{ op: Op.setValue, a: 1, s: "pending" }]);
  runtime.applyPendingCommands("host-update");
  assert.equal(removedInput.value, "draft");
  assert.equal(runtime.controlledInputs.get(1)?.state.pendingValue, "pending");

  host.writeCommands([{ op: Op.removeNode, a: 1 }]);
  runtime.applyPendingCommands("remove-input");
  assert.equal(runtime.controlledInputs.has(1), false);
  assert.equal(removedInput.listeners.get("blur")?.length ?? 0, 0);

  fireEvent(removedInput, "blur");
  assert.equal(removedInput.value, "draft");

  host.writeCommands([
    { op: Op.createElement, a: 1, s: "input" },
    { op: Op.setValue, a: 1, s: "fresh" },
    { op: Op.appendChild, a: 0, b: 1 },
  ]);
  runtime.applyPendingCommands("recreate-input");
  const recreatedInput = findNode(root, (node) => node.tagName === "INPUT");
  assert.equal(recreatedInput.value, "fresh");
  assert.equal(runtime.controlledInputs.get(1)?.state.pendingValue, null);
});

test("single select change syncs controlled value before Roc echo", () => {
  const { host, root, runtime } = mountWith([
    { op: Op.resetDom },
    { op: Op.createElement, a: 1, s: "select" },
    { op: Op.setValue, a: 1, s: "starter" },
    {
      dynamic: {
        op: DynamicOp.bindEvent,
        elemId: 1,
        eventName: "change",
        eventId: 41,
        options: 0,
        eventExtractionPlan: targetValueEventExtractionPlan,
      },
    },
    { op: Op.appendChild, a: 0, b: 1 },
  ]);
  const select = findNode(root, (node) => node.tagName === "SELECT");

  fireEvent(select, "focus");
  select.value = "growth";
  fireEvent(select, "change");

  assert.deepEqual(host.dispatches, [{ eventId: 41, kind: PayloadKind.str, payload: "growth" }]);
  assert.equal(runtime.controlledInputs.get(1)?.state.value, "growth");

  host.writeCommands([{ op: Op.setValue, a: 1, s: "growth" }]);
  runtime.applyPendingCommands("roc-echo");

  assert.equal(select.value, "growth");
  assert.equal(runtime.controlledInputs.get(1)?.state.pendingValue, null);
});

test("radio change dispatches the option target value", () => {
  const { host, root, runtime } = mountWith([
    { op: Op.resetDom },
    { op: Op.createElement, a: 1, s: "input" },
    { op: Op.setRole, a: 1, s: "radio" },
    { op: Op.setLabel, a: 1, s: "Annual" },
    { op: Op.setValue, a: 1, s: "annual" },
    { op: Op.setChecked, a: 1, b: 0 },
    {
      dynamic: {
        op: DynamicOp.setAttrText,
        elemId: 1,
        name: "type",
        value: "radio",
      },
    },
    {
      dynamic: {
        op: DynamicOp.setAttrText,
        elemId: 1,
        name: "name",
        value: "billing",
      },
    },
    {
      dynamic: {
        op: DynamicOp.bindEvent,
        elemId: 1,
        eventName: "change",
        eventId: 51,
        options: 0,
        eventExtractionPlan: targetValueEventExtractionPlan,
      },
    },
    { op: Op.appendChild, a: 0, b: 1 },
  ]);
  const radio = findNode(root, (node) => node.tagName === "INPUT" && node.getAttribute("role") === "radio");

  radio.checked = true;
  fireEvent(radio, "change");

  assert.deepEqual(host.dispatches, [{ eventId: 51, kind: PayloadKind.str, payload: "annual" }]);
  assert.equal(runtime.controlledInputs.get(1)?.state.value, "annual");

  host.writeCommands([{ op: Op.setChecked, a: 1, b: 1 }]);
  runtime.applyPendingCommands("radio-checked");
  assert.equal(radio.checked, true);
  assert.equal(radio.getAttribute("type"), "radio");
  assert.equal(radio.getAttribute("name"), "billing");
});

test("textarea SetValue patches use the controlled text policy", () => {
  const { host, root, runtime } = mountWith([
    { op: Op.resetDom },
    { op: Op.createElement, a: 1, s: "textarea" },
    { op: Op.setValue, a: 1, s: "draft" },
    { op: Op.bindInput, a: 1, b: 42 },
    { op: Op.appendChild, a: 0, b: 1 },
  ]);
  const textarea = findNode(root, (node) => node.tagName === "TEXTAREA");

  fireEvent(textarea, "focus");
  textarea.value = "user edit";
  fireEvent(textarea, "input");

  assert.deepEqual(host.dispatches, [{ eventId: 42, kind: PayloadKind.str, payload: "user edit" }]);

  host.writeCommands([{ op: Op.setValue, a: 1, s: "canonical edit" }]);
  runtime.applyPendingCommands("textarea-host-update");

  assert.equal(textarea.value, "user edit");
  assert.equal(runtime.controlledInputs.get(1)?.state.pendingValue, "canonical edit");

  fireEvent(textarea, "blur");
  assert.equal(textarea.value, "canonical edit");
  assert.equal(runtime.controlledInputs.get(1)?.state.pendingValue, null);
});

test("number input keeps draft string while focused", () => {
  const { host, root, runtime } = mountWith([
    { op: Op.resetDom },
    { op: Op.createElement, a: 1, s: "input" },
    {
      dynamic: {
        op: DynamicOp.setAttrText,
        elemId: 1,
        name: "type",
        value: "number",
      },
    },
    { op: Op.setValue, a: 1, s: "3" },
    { op: Op.bindInput, a: 1, b: 61 },
    { op: Op.appendChild, a: 0, b: 1 },
  ]);
  const input = findNode(root, (node) => node.tagName === "INPUT");

  fireEvent(input, "focus");
  input.value = "12.";
  fireEvent(input, "input");

  assert.deepEqual(host.dispatches, [{ eventId: 61, kind: PayloadKind.str, payload: "12." }]);

  host.writeCommands([{ op: Op.setValue, a: 1, s: "12" }]);
  runtime.applyPendingCommands("number-commit");

  assert.equal(input.value, "12.");
  assert.equal(runtime.controlledInputs.get(1)?.state.pendingValue, "12");

  fireEvent(input, "blur");
  assert.equal(input.value, "12");
  assert.equal(runtime.controlledInputs.get(1)?.state.pendingValue, null);
  assert.equal(input.getAttribute("type"), "number");
});

test("dynamic attribute commands set and remove DOM attributes", () => {
  const telemetry = [];
  const { host, root, runtime } = mountWith(
    [
      { op: Op.resetDom },
      { op: Op.createElement, a: 1, s: "button" },
      {
        dynamic: {
          op: DynamicOp.setAttrText,
          elemId: 1,
          name: "aria-label",
          value: "Save",
        },
      },
      {
        dynamic: {
          op: DynamicOp.setAttrText,
          elemId: 1,
          name: "data-mode",
          value: "primary",
        },
      },
      {
        dynamic: {
          op: DynamicOp.setAttrText,
          elemId: 1,
          name: "required",
          value: "",
        },
      },
      {
        dynamic: {
          op: DynamicOp.setAttrText,
          elemId: 1,
          name: "class",
          value: "toolbar",
        },
      },
      { op: Op.appendChild, a: 0, b: 1 },
    ],
    { telemetry: (entry) => telemetry.push(entry) },
  );

  const button = findNode(root, (node) => node.tagName === "BUTTON");
  assert.equal(button.getAttribute("aria-label"), "Save");
  assert.equal(button.getAttribute("data-mode"), "primary");
  assert.equal(button.getAttribute("required"), "");
  assert.equal(button.getAttribute("class"), "toolbar");

  const mountCommands = telemetry.find((entry) => entry.kind === "commands" && entry.phase === "mount");
  assert.equal(mountCommands.opCounts.set_attr_text, 4);
  assert.equal(mountCommands.dynamicBytes, 132);
  assert.equal(mountCommands.fixedRecordBytes, 7 * RECORD_WORDS * 4);
  const mountApplied = telemetry.find(
    (entry) => entry.kind === "commands_applied" && entry.phase === "mount",
  );
  assert.deepEqual(mountApplied.decode, {
    fixedStringDecodes: 1,
    fixedStringBytes: 6,
    dynamicRecordsDecoded: 4,
    dynamicRecordBytes: 132,
    dynamicStringDecodes: 8,
    dynamicStringBytes: 50,
    dynamicByteArrayDecodes: 0,
    dynamicByteArrayBytes: 0,
  });

  host.writeCommands([
    {
      dynamic: {
        op: DynamicOp.removeAttr,
        elemId: 1,
        name: "data-mode",
      },
    },
    {
      dynamic: {
        op: DynamicOp.removeAttr,
        elemId: 1,
        name: "class",
      },
    },
    {
      dynamic: {
        op: DynamicOp.removeAttr,
        elemId: 1,
        name: "required",
      },
    },
  ]);
  runtime.applyPendingCommands("dynamic-remove");

  assert.equal(button.getAttribute("aria-label"), "Save");
  assert.equal(button.getAttribute("data-mode"), null);
  assert.equal(button.getAttribute("required"), null);
  assert.equal(button.getAttribute("class"), null);

  const removeCommands = telemetry.find(
    (entry) => entry.kind === "commands" && entry.phase === "dynamic-remove",
  );
  assert.equal(removeCommands.opCounts.remove_attr, 3);
  assert.equal(removeCommands.dynamicBytes, 76);
  const removeApplied = telemetry.find(
    (entry) => entry.kind === "commands_applied" && entry.phase === "dynamic-remove",
  );
  assert.deepEqual(removeApplied.decode, {
    fixedStringDecodes: 0,
    fixedStringBytes: 0,
    dynamicRecordsDecoded: 3,
    dynamicRecordBytes: 76,
    dynamicStringDecodes: 3,
    dynamicStringBytes: 22,
    dynamicByteArrayDecodes: 0,
    dynamicByteArrayBytes: 0,
  });
});

test("malformed dynamic command records fail closed", () => {
  const { host, runtime } = mountWith([
    { op: Op.resetDom },
    { op: Op.createElement, a: 1, s: "button" },
    { op: Op.appendChild, a: 0, b: 1 },
  ]);

  const record = (payloadBytes, overrides = {}) =>
    encodeDynamicRecord({
      op: overrides.op ?? DynamicOp.removeAttr,
      flags: overrides.flags ?? 0,
      payloadBytes,
    });
  const validEmptyNameRemove = record(concatBytes([u32Bytes(1), u32Bytes(0)]));
  const withExtraByte = new Uint8Array(validEmptyNameRemove.length + 4);
  withExtraByte.set(validEmptyNameRemove);

  const cases = [
    [{ dynamicBytes: new Uint8Array([1, 0, 0, 0]) }, /header needs 8 bytes/],
    [
      { dynamicBytes: encodeDynamicRecord({ op: DynamicOp.removeAttr, flags: 1, payloadBytes: [] }) },
      /unsupported flags/,
    ],
    [
      {
        dynamicBytes: record(concatBytes([u32Bytes(1), u32Bytes(99), encoder.encode("abc")])),
      },
      /operand name extends beyond payload_len/,
    ],
    [
      {
        dynamicBytes: record(concatBytes([u32Bytes(1), u32Bytes(1), new Uint8Array([0xff])])),
      },
      /name was not valid UTF-8/,
    ],
    [
      {
        dynamicBytes: record(concatBytes([u32Bytes(1), u32Bytes(0), new Uint8Array([1])])),
      },
      /left 1 trailing payload bytes/,
    ],
    [{ dynamicBytes: withExtraByte }, /outer length 20 did not match payload_len 8/],
    [
      { dynamicBytes: encodeDynamicRecord({ op: 65535, payloadBytes: [] }) },
      /unknown dynamic render op 65535/,
    ],
    [
      { dynamicBytes: new Uint8Array([1, 0, 0, 0]), dynamicLength: 12 },
      /exceeds dynamic buffer length/,
    ],
  ];

  for (const [entry, pattern] of cases) {
    host.writeCommands([entry]);
    assert.throws(() => runtime.applyPendingCommands("malformed-dynamic"), pattern);
  }
});

test("event payloads round-trip through the wasm memory boundary", () => {
  const telemetry = [];
  const { host, root } = mountWith([
    { op: Op.resetDom },
    { op: Op.createElement, a: 1, s: "button" },
    { op: Op.setText, a: 1, s: "click" },
    { op: Op.bindClick, a: 1, b: 10 },
    { op: Op.appendChild, a: 0, b: 1 },
    { op: Op.createElement, a: 2, s: "input" },
    { op: Op.bindInput, a: 2, b: 11 },
    { op: Op.appendChild, a: 0, b: 2 },
    { op: Op.createElement, a: 3, s: "input" },
    { op: Op.setRole, a: 3, s: "checkbox" },
    { op: Op.bindCheck, a: 3, b: 12 },
    { op: Op.appendChild, a: 0, b: 3 },
    { op: Op.createElement, a: 4, s: "section" },
    { op: Op.setText, a: 4, s: "drop-zone" },
    { op: Op.bindPointerDown, a: 4, b: 13 },
    { op: Op.bindPointerEnter, a: 4, b: 14 },
    { op: Op.bindPointerUp, a: 4, b: 15 },
    { op: Op.bindPointerLeave, a: 4, b: 16 },
    { op: Op.appendChild, a: 0, b: 4 },
  ], { telemetry: (entry) => telemetry.push(entry) });

  fireEvent(findByText(root, "button", "click"), "click");
  const textInput = findAll(root, (node) => node.tagName === "INPUT")[0];
  textInput.value = "typed text";
  fireEvent(textInput, "input");
  const checkbox = findAll(root, (node) => node.tagName === "INPUT")[1];
  checkbox.checked = true;
  fireEvent(checkbox, "change");
  const dropZone = findByText(root, "section", "drop-zone");
  assert.equal(dropZone.dataset.rocPointerDrag, "true");
  assert.equal(dropZone.draggable, false);
  assert.equal(dropZone.style.userSelect, "none");
  assert.equal(dropZone.style.touchAction, "none");
  assert.equal(fireEvent(dropZone, "pointerdown").defaultPrevented, true);
  assert.equal(fireEvent(dropZone, "pointerenter").defaultPrevented, true);
  assert.equal(fireEvent(dropZone, "pointerup").defaultPrevented, true);
  assert.equal(fireEvent(dropZone, "pointerleave").defaultPrevented, true);

  assert.deepEqual(host.dispatches, [
    { eventId: 10, kind: PayloadKind.unit },
    { eventId: 11, kind: PayloadKind.str, payload: "typed text" },
    { eventId: 12, kind: PayloadKind.bool, payload: true },
    { eventId: 13, kind: PayloadKind.unit },
    { eventId: 14, kind: PayloadKind.unit },
    { eventId: 15, kind: PayloadKind.unit },
    { eventId: 16, kind: PayloadKind.unit },
  ]);
  assert.ok(
    telemetry.some(
      (entry) =>
        entry.kind === "bind_event" &&
        entry.domEvent === "pointerdown" &&
        entry.eventId === 13 &&
        entry.requestedDelivery === "auto" &&
        entry.effectiveDelivery === "native" &&
        entry.deliveryReason === "pointer-drag",
    ),
  );
  for (const [domEvent, eventId] of [
    ["pointerenter", 14],
    ["pointerup", 15],
    ["pointerleave", 16],
  ]) {
    assert.ok(
      telemetry.some(
        (entry) =>
          entry.kind === "bind_event" &&
          entry.domEvent === domEvent &&
          entry.eventId === eventId &&
          entry.requestedDelivery === "auto" &&
          entry.effectiveDelivery === "native" &&
          entry.deliveryReason === "prevent-default-policy",
      ),
    );
  }
});

test("dynamic keydown events dispatch explicit key shift byte payloads", () => {
  const telemetry = [];
  const { host, root } = mountWith([
    { op: Op.resetDom },
    { op: Op.createElement, a: 1, s: "input" },
    {
      dynamic: {
        op: DynamicOp.bindEvent,
        elemId: 1,
        eventName: "keydown",
        eventId: 21,
        options: 0,
        eventExtractionPlan: keyShiftEventExtractionPlan,
      },
    },
    { op: Op.appendChild, a: 0, b: 1 },
  ], { telemetry: (entry) => telemetry.push(entry) });

  const input = findNode(root, (node) => node.tagName === "INPUT");
  fireEvent(input, "keydown", { key: "K", shiftKey: true });

  assert.deepEqual(host.dispatches, [
    { eventId: 21, kind: PayloadKind.bytes, payloadBytes: keyShiftBytes("K", true) },
  ]);
  const mountApplied = telemetry.find(
    (entry) => entry.kind === "commands_applied" && entry.phase === "mount",
  );
  assert.deepEqual(mountApplied.decode, {
    fixedStringDecodes: 1,
    fixedStringBytes: 5,
    dynamicRecordsDecoded: 1,
    dynamicRecordBytes: 72,
    dynamicStringDecodes: 1,
    dynamicStringBytes: 7,
    dynamicByteArrayDecodes: 1,
    dynamicByteArrayBytes: keyShiftEventExtractionPlan.length,
  });
});

test("dynamic custom events dispatch serialized detail payloads", () => {
  const { host, root } = mountWith([
    { op: Op.resetDom },
    { op: Op.createElement, a: 1, s: "section" },
    {
      dynamic: {
        op: DynamicOp.bindEvent,
        elemId: 1,
        eventName: "chart-select",
        eventId: 30,
        options: 0,
        eventExtractionPlan: eventDetailExtractionPlan,
      },
    },
    { op: Op.createElement, a: 2, s: "button" },
    { op: Op.appendChild, a: 1, b: 2 },
    { op: Op.appendChild, a: 0, b: 1 },
  ]);

  const button = findNode(root, (node) => node.tagName === "BUTTON");
  button.dispatchEvent(new CustomEvent("chart-select", { detail: "point-a", bubbles: true }));
  button.dispatchEvent(new CustomEvent("chart-select", { detail: { id: "point-b", rpm: 1200 }, bubbles: true }));
  button.dispatchEvent(new CustomEvent("chart-select", { bubbles: true }));

  const circular = {};
  circular.self = circular;
  assert.throws(
    () => button.dispatchEvent(new CustomEvent("chart-select", { detail: circular, bubbles: true })),
    /Converting circular structure to JSON/,
  );

  assert.deepEqual(host.dispatches, [
    { eventId: 30, kind: PayloadKind.str, payload: "point-a" },
    { eventId: 30, kind: PayloadKind.str, payload: '{"id":"point-b","rpm":1200}' },
    { eventId: 30, kind: PayloadKind.str, payload: "" },
  ]);
});

test("behavior lifecycle attaches after batch, coalesces updates, and cleans up", () => {
  const telemetry = [];
  const calls = [];
  let behaviorElement = null;
  const behaviors = {
    demo: {
      attach(el) {
        behaviorElement = el;
        calls.push(["attach", el.getAttribute("data-value"), el.parentNode !== null]);
        return () => calls.push(["cleanup", el.getAttribute("data-value")]);
      },
      update(el, attrName) {
        calls.push(["update", attrName, el.getAttribute(attrName)]);
      },
    },
  };
  const setAttr = (elemId, name, value) => ({
    dynamic: { op: DynamicOp.setAttrText, elemId, name, value },
  });
  const removeAttr = (elemId, name) => ({
    dynamic: { op: DynamicOp.removeAttr, elemId, name },
  });
  const { host, runtime } = mountWith(
    [
      { op: Op.resetDom },
      { op: Op.createElement, a: 1, s: "section" },
      {
        dynamic: {
          op: DynamicOp.bindEvent,
          elemId: 1,
          eventName: "chart-select",
          eventId: 31,
          options: 0,
          eventExtractionPlan: eventDetailExtractionPlan,
        },
      },
      { op: Op.createElement, a: 2, s: "div" },
      setAttr(2, "data-value", "one"),
      setAttr(2, "data-signals-behavior", "demo"),
      { op: Op.appendChild, a: 1, b: 2 },
      { op: Op.appendChild, a: 0, b: 1 },
    ],
    { behaviors, telemetry: (entry) => telemetry.push(entry) },
  );

  assert.deepEqual(calls, [["attach", "one", true]]);
  behaviorElement.dispatchEvent(new CustomEvent("chart-select", { detail: "from behavior", bubbles: true }));
  assert.deepEqual(host.dispatches, [
    { eventId: 31, kind: PayloadKind.str, payload: "from behavior" },
  ]);

  host.writeCommands([
    setAttr(2, "data-value", "two"),
    setAttr(2, "data-value", "three"),
    setAttr(2, "data-extra", "x"),
  ]);
  runtime.applyPendingCommands("behavior-update");
  assert.deepEqual(calls.slice(1), [
    ["update", "data-value", "three"],
    ["update", "data-extra", "x"],
  ]);

  host.writeCommands([setAttr(2, "data-signals-behavior", "missing")]);
  runtime.applyPendingCommands("behavior-missing");
  assert.deepEqual(calls.at(-1), ["cleanup", "three"]);
  assert.ok(telemetry.some((entry) => entry.kind === "behavior_missing" && entry.behavior === "missing"));

  host.writeCommands([setAttr(2, "data-signals-behavior", "demo")]);
  runtime.applyPendingCommands("behavior-reattach");
  assert.deepEqual(calls.at(-1), ["attach", "three", true]);

  host.writeCommands([removeAttr(2, "data-signals-behavior")]);
  runtime.applyPendingCommands("behavior-remove-marker");
  assert.deepEqual(calls.at(-1), ["cleanup", "three"]);

  host.writeCommands([setAttr(2, "data-signals-behavior", "demo")]);
  runtime.applyPendingCommands("behavior-reattach-before-unmount");
  runtime.unmount();
  assert.deepEqual(calls.at(-1), ["cleanup", "three"]);
  assert.ok(telemetry.some((entry) => entry.kind === "behavior_attach" && entry.behavior === "demo"));
  assert.ok(telemetry.some((entry) => entry.kind === "behavior_update" && entry.attrName === "data-value"));
  assert.ok(telemetry.some((entry) => entry.kind === "behavior_cleanup" && entry.behavior === "demo"));
});

test("dynamic submit events apply static prevent-default policy", () => {
  const { host, root, runtime } = mountWith([
    { op: Op.resetDom },
    { op: Op.createElement, a: 1, s: "form" },
    {
      dynamic: {
        op: DynamicOp.bindEvent,
        elemId: 1,
        eventName: "submit",
        eventId: 22,
        options: ListenerOptions.preventDefault,
        eventExtractionPlan: unitEventExtractionPlan,
      },
    },
    { op: Op.appendChild, a: 0, b: 1 },
  ]);

  const form = findNode(root, (node) => node.tagName === "FORM");
  const event = fireEvent(form, "submit");
  assert.equal(event.defaultPrevented, true);
  assert.deepEqual(host.dispatches, [{ eventId: 22, kind: PayloadKind.unit }]);

  host.writeCommands([
    {
      dynamic: {
        op: DynamicOp.clearEvent,
        elemId: 1,
        eventName: "submit",
      },
    },
  ]);
  runtime.applyPendingCommands("clear-submit");
  fireEvent(form, "submit");
  assert.deepEqual(host.dispatches, [{ eventId: 22, kind: PayloadKind.unit }]);
});

test("dynamic events apply static stop-propagation policy", () => {
  const telemetry = [];
  const { host, root } = mountWith(
    [
      { op: Op.resetDom },
      { op: Op.createElement, a: 1, s: "button" },
      { op: Op.setText, a: 1, s: "click" },
      {
        dynamic: {
          op: DynamicOp.bindEvent,
          elemId: 1,
          eventName: "click",
          eventId: 123,
          options: ListenerOptions.stopPropagation,
          eventExtractionPlan: unitEventExtractionPlan,
        },
      },
      { op: Op.appendChild, a: 0, b: 1 },
    ],
    { telemetry: (entry) => telemetry.push(entry) },
  );
  const button = findByText(root, "button", "click");
  let stopCalls = 0;

  const event = fireEvent(button, "click", {
    stopPropagation() {
      stopCalls += 1;
      this.propagationStopped = true;
    },
  });

  assert.equal(stopCalls, 1);
  assert.equal(event.propagationStopped, true);
  assert.equal(event.immediatePropagationStopped, false);
  assert.deepEqual(host.dispatches, [{ eventId: 123, kind: PayloadKind.unit }]);
  assert.ok(
    telemetry.some(
      (entry) =>
        entry.kind === "dom_event" &&
        entry.eventId === 123 &&
        entry.listenerOptions?.stopPropagation === true &&
        entry.stoppedPropagation === true &&
        entry.stoppedImmediatePropagation === false,
    ),
  );
});

test("dynamic events apply static stop-immediate propagation policy", () => {
  const { host, root } = mountWith([
    { op: Op.resetDom },
    { op: Op.createElement, a: 1, s: "button" },
    { op: Op.setText, a: 1, s: "click" },
    {
      dynamic: {
        op: DynamicOp.bindEvent,
        elemId: 1,
        eventName: "click",
        eventId: 23,
        options: ListenerOptions.stopImmediatePropagation,
        eventExtractionPlan: unitEventExtractionPlan,
      },
    },
    { op: Op.appendChild, a: 0, b: 1 },
  ]);
  const button = findByText(root, "button", "click");
  let laterListenerFired = false;
  button.addEventListener("click", () => {
    laterListenerFired = true;
  });

  const event = fireEvent(button, "click");

  assert.equal(event.immediatePropagationStopped, true);
  assert.equal(laterListenerFired, false);
  assert.deepEqual(host.dispatches, [{ eventId: 23, kind: PayloadKind.unit }]);
});

test("dynamic events apply self and trusted filters before static policy", () => {
  const telemetry = [];
  const { host, root } = mountWith(
    [
      { op: Op.resetDom },
      { op: Op.createElement, a: 1, s: "button" },
      { op: Op.setText, a: 1, s: "self" },
      {
        dynamic: {
          op: DynamicOp.bindEvent,
          elemId: 1,
          eventName: "click",
          eventId: 24,
          options: ListenerOptions.self | ListenerOptions.preventDefault,
          eventExtractionPlan: unitEventExtractionPlan,
        },
      },
      { op: Op.appendChild, a: 0, b: 1 },
      { op: Op.createElement, a: 2, s: "button" },
      { op: Op.setText, a: 2, s: "trusted" },
      {
        dynamic: {
          op: DynamicOp.bindEvent,
          elemId: 2,
          eventName: "click",
          eventId: 25,
          options: ListenerOptions.trusted,
          eventExtractionPlan: unitEventExtractionPlan,
        },
      },
      { op: Op.appendChild, a: 0, b: 2 },
    ],
    { telemetry: (entry) => telemetry.push(entry) },
  );
  const selfButton = findByText(root, "button", "self");
  const childTarget = document.createElement("span");
  selfButton.appendChild(childTarget);

  const filteredSelf = fireEvent(selfButton, "click", { target: childTarget });
  assert.equal(filteredSelf.defaultPrevented, false);
  assert.deepEqual(host.dispatches, []);

  const acceptedSelf = fireEvent(selfButton, "click");
  assert.equal(acceptedSelf.defaultPrevented, true);
  assert.deepEqual(host.dispatches, [{ eventId: 24, kind: PayloadKind.unit }]);

  const trustedButton = findByText(root, "button", "trusted");
  fireEvent(trustedButton, "click", { isTrusted: false });
  assert.deepEqual(host.dispatches, [{ eventId: 24, kind: PayloadKind.unit }]);
  fireEvent(trustedButton, "click", { isTrusted: true });
  assert.deepEqual(host.dispatches, [
    { eventId: 24, kind: PayloadKind.unit },
    { eventId: 25, kind: PayloadKind.unit },
  ]);
  assert.ok(
    telemetry.some(
      (entry) =>
        entry.kind === "dom_event_filtered" &&
        entry.eventId === 24 &&
        entry.filter === "self",
    ),
  );
  assert.ok(
    telemetry.some(
      (entry) =>
        entry.kind === "dom_event_filtered" &&
        entry.eventId === 25 &&
        entry.filter === "trusted",
    ),
  );
});

test("dynamic once listener survives self-filtered deliveries", () => {
  const { host, root } = mountWith([
    { op: Op.resetDom },
    { op: Op.createElement, a: 1, s: "button" },
    { op: Op.setText, a: 1, s: "once" },
    {
      dynamic: {
        op: DynamicOp.bindEvent,
        elemId: 1,
        eventName: "click",
        eventId: 26,
        options: ListenerOptions.once | ListenerOptions.self,
        eventExtractionPlan: unitEventExtractionPlan,
      },
    },
    { op: Op.appendChild, a: 0, b: 1 },
  ]);
  const button = findByText(root, "button", "once");
  const childTarget = document.createElement("span");
  button.appendChild(childTarget);

  assert.deepEqual(button.listeners.get("click")[0].options, {
    capture: false,
    passive: false,
    once: false,
  });

  fireEvent(button, "click", { target: childTarget });
  assert.deepEqual(host.dispatches, []);
  assert.equal(button.listeners.get("click").length, 1);

  fireEvent(button, "click");
  assert.deepEqual(host.dispatches, [{ eventId: 26, kind: PayloadKind.unit }]);
  assert.equal(button.listeners.get("click").length, 0);

  fireEvent(button, "click");
  assert.deepEqual(host.dispatches, [{ eventId: 26, kind: PayloadKind.unit }]);
});

test("event dispatch applies response bits before draining response commands", () => {
  const telemetry = [];
  const { host, root, runtime } = mountWith(
    [
      { op: Op.resetDom },
      { op: Op.createElement, a: 1, s: "button" },
      { op: Op.setText, a: 1, s: "click" },
      { op: Op.bindClick, a: 1, b: 23 },
      { op: Op.appendChild, a: 0, b: 1 },
    ],
    { telemetry: (entry) => telemetry.push(entry) },
  );
  const responseBits =
    ListenerOptions.preventDefault |
    ListenerOptions.stopPropagation |
    ListenerOptions.stopImmediatePropagation;
  host.eventResponseBits.set(23, responseBits);
  host.eventResponses.set(23, () => [{ op: Op.setText, a: 1, s: "clicked" }]);

  const event = fireEvent(findByText(root, "button", "click"), "click");

  assert.equal(event.defaultPrevented, true);
  assert.equal(event.cancelBubble, true);
  assert.equal(event.immediatePropagationStopped, true);
  assert.deepEqual(host.dispatches, [{ eventId: 23, kind: PayloadKind.unit }]);
  assert.equal(runtime.lastEventResponseBits, responseBits);
  assert.equal(findByText(root, "button", "clicked").textContent, "clicked");
  const responseIndex = telemetry.findIndex(
    (entry) => entry.kind === "dom_event_response" && entry.eventId === 23,
  );
  const commandsIndex = telemetry.findIndex(
    (entry) => entry.kind === "commands" && entry.phase === "event:23",
  );
  assert.ok(responseIndex >= 0);
  assert.ok(commandsIndex > responseIndex);
});

test("event dispatch rejects unsupported response bits before draining response commands", () => {
  const { host, root } = mountWith([
    { op: Op.resetDom },
    { op: Op.createElement, a: 1, s: "button" },
    { op: Op.setText, a: 1, s: "click" },
    { op: Op.bindClick, a: 1, b: 23 },
    { op: Op.appendChild, a: 0, b: 1 },
  ]);
  host.eventResponseBits.set(23, ListenerOptions.capture);
  host.eventResponses.set(23, () => [{ op: Op.setText, a: 1, s: "clicked" }]);

  assert.throws(
    () => fireEvent(findByText(root, "button", "click"), "click"),
    /unsupported event response bits 0x4/,
  );
  assert.deepEqual(host.dispatches, [{ eventId: 23, kind: PayloadKind.unit }]);
  assert.equal(findByText(root, "button", "click").textContent, "click");
});

test("event dispatch wraps wasm host trap diagnostics", () => {
  const { host, root } = mountWith([
    { op: Op.resetDom },
    { op: Op.createElement, a: 1, s: "button" },
    { op: Op.setText, a: 1, s: "click" },
    { op: Op.bindClick, a: 1, b: 24 },
    { op: Op.appendChild, a: 0, b: 1 },
  ]);
  host.eventTrapMessages.set(
    24,
    "DOM event payload descriptor does not match Roc event descriptor",
  );

  assert.throws(
    () => fireEvent(findByText(root, "button", "click"), "click"),
    /DOM event payload descriptor does not match Roc event descriptor: unreachable/,
  );
  assert.deepEqual(host.dispatches, []);
});

test("event dispatch preserves diagnostics when payload dealloc also traps", () => {
  const { host, root } = mountWith([
    { op: Op.resetDom },
    { op: Op.createElement, a: 1, s: "input" },
    { op: Op.bindInput, a: 1, b: 25 },
    { op: Op.appendChild, a: 0, b: 1 },
  ]);
  host.eventTrapMessages.set(
    25,
    "DOM event payload kind does not match Roc event descriptor",
  );
  host.deallocTrapMessage = "roc_dealloc failed after event trap";

  const input = findNode(root, (node) => node.tagName === "INPUT");
  input.value = "typed";
  assert.throws(
    () => fireEvent(input, "input"),
    /DOM event payload kind does not match Roc event descriptor: unreachable/,
  );
  assert.deepEqual(host.dispatches, []);
});

test("mount payload preflight sweeps every allocation failure and remains retryable", () => {
  const baseline = mountWith([]);
  const allocationCount = baseline.host.allocationAttempts;
  baseline.runtime.unmount();
  assert.ok(allocationCount >= 3);

  for (let allocationNumber = 1; allocationNumber <= allocationCount; allocationNumber += 1) {
    const host = new MockHost({ failAllocationNumber: allocationNumber });
    const root = installDomDouble();
    const runtime = new SignalsRuntime(host.exports, root);

    assert.throws(
      () => runtime.mount(),
      (err) => err.code === "out_of_memory" && /payload allocation failed/.test(err.message),
    );
    assert.equal(runtime.failedError, null);
    assert.equal(runtime.mounted, false);
    assert.equal(root.childNodes.length, 0);
    assert.equal(host.initialLocationPayload, null);
    assert.equal(host.initialVisibilityPayload, null);
    assert.equal(host.initialOnlinePayload, null);
    assert.equal(host.prepareMounts, 0);
    assert.equal(host.deallocCalls.length, allocationNumber - 1);

    host.failAllocationNumber = null;
    runtime.mount();
    assert.equal(runtime.mounted, true);
    runtime.unmount();
  }
});

test("bounded Wasm memory growth failure is recoverable before event mutation", () => {
  const { host, runtime } = mountWith(
    [{ op: Op.bindInput, a: 0, b: 124 }],
    { maximumMemoryPages: 1 },
  );
  const oversized = "x".repeat(PAGE);

  assert.throws(
    () => runtime.dispatchString(124, oversized),
    (err) => err.code === "out_of_memory",
  );
  assert.equal(runtime.failedError, null);
  assert.deepEqual(host.dispatches, []);

  runtime.dispatchString(124, "retry");
  assert.deepEqual(host.dispatches, [{ eventId: 124, kind: PayloadKind.str, payload: "retry" }]);
  runtime.unmount();
});

test("configured payload limit rejects before allocator or host mutation", () => {
  const { host, runtime } = mountWith(
    [{ op: Op.bindInput, a: 0, b: 123 }],
    { limits: { maxPayloadBytes: 64 } },
  );
  const attemptsBefore = host.allocationAttempts;

  assert.throws(
    () => runtime.dispatchString(123, "x".repeat(65)),
    (err) => err.code === "resource_limit",
  );
  assert.equal(host.allocationAttempts, attemptsBefore);
  assert.deepEqual(host.dispatches, []);
  assert.equal(runtime.failedError, null);

  runtime.dispatchString(123, "within limit");
  assert.equal(host.dispatches.length, 1);
  runtime.unmount();
});

test("fatal wasm trap poisons runtime detaches resources and rejects re-entry", () => {
  const errors = [];
  const { host, root, runtime } = mountWith(
    [
      { op: Op.resetDom },
      { op: Op.createElement, a: 1, s: "input" },
      { op: Op.bindInput, a: 1, b: 125 },
      { op: Op.appendChild, a: 0, b: 1 },
    ],
    { onError: (err) => errors.push(err) },
  );
  host.eventTrapMessages.set(125, "out of memory while staging render strings");
  const input = findNode(root, (node) => node.tagName === "INPUT");
  input.value = "still visible";
  const deallocsBefore = host.deallocCalls.length;

  assert.throws(() => fireEvent(input, "input"), /out of memory while staging render strings/);
  assert.equal(errors.length, 1);
  assert.equal(runtime.mounted, false);
  assert.equal(runtime.lastCommands.length, 0);
  assert.equal(runtime.eventCleanups.size, 0);
  assert.equal(runtime.intervals.size, 0);
  assert.equal(runtime.tasks.size, 0);
  assert.equal(host.deallocCalls.length, deallocsBefore + 1);
  assert.equal(input.value, "still visible");

  const dispatchCount = host.dispatches.length;
  assert.throws(() => runtime.dispatchUnit(125), /out of memory while staging render strings/);
  assert.equal(host.dispatches.length, dispatchCount);

  const replacement = mountWith([]);
  assert.equal(replacement.runtime.mounted, true);
  replacement.runtime.unmount();
});

test("dynamic form named events dispatch unit and target value payloads", () => {
  const telemetry = [];
  const { host, root } = mountWith(
    [
      { op: Op.resetDom },
      { op: Op.createElement, a: 1, s: "input" },
      {
        dynamic: {
          op: DynamicOp.bindEvent,
          elemId: 1,
          eventName: "focus",
          eventId: 23,
          options: ListenerOptions.capture | ListenerOptions.passive,
          eventExtractionPlan: unitEventExtractionPlan,
        },
      },
      {
        dynamic: {
          op: DynamicOp.bindEvent,
          elemId: 1,
          eventName: "blur",
          eventId: 24,
          options: ListenerOptions.once,
          eventExtractionPlan: unitEventExtractionPlan,
        },
      },
      {
        dynamic: {
          op: DynamicOp.bindEvent,
          elemId: 1,
          eventName: "change",
          eventId: 25,
          options: 0,
          eventExtractionPlan: targetValueEventExtractionPlan,
        },
      },
      {
        dynamic: {
          op: DynamicOp.bindEvent,
          elemId: 1,
          eventName: "compositionstart",
          eventId: 26,
          options: 0,
          eventExtractionPlan: unitEventExtractionPlan,
        },
      },
      {
        dynamic: {
          op: DynamicOp.bindEvent,
          elemId: 1,
          eventName: "compositionend",
          eventId: 27,
          options: 0,
          eventExtractionPlan: unitEventExtractionPlan,
        },
      },
      { op: Op.appendChild, a: 0, b: 1 },
    ],
    { telemetry: (entry) => telemetry.push(entry) },
  );

  const input = findNode(root, (node) => node.tagName === "INPUT");
  assert.deepEqual(input.listeners.get("focus")[0].options, {
    capture: true,
    passive: true,
    once: false,
  });
  assert.deepEqual(input.listeners.get("blur")[0].options, {
    capture: false,
    passive: false,
    once: true,
  });

  fireEvent(input, "focus");
  input.value = "team@example.com";
  fireEvent(input, "change");
  fireEvent(input, "compositionstart");
  fireEvent(input, "compositionend");
  fireEvent(input, "blur");

  assert.deepEqual(host.dispatches, [
    { eventId: 23, kind: PayloadKind.unit },
    { eventId: 25, kind: PayloadKind.str, payload: "team@example.com" },
    { eventId: 26, kind: PayloadKind.unit },
    { eventId: 27, kind: PayloadKind.unit },
    { eventId: 24, kind: PayloadKind.unit },
  ]);
  assert.ok(
    telemetry.some(
      (entry) =>
        entry.kind === "bind_event" &&
        entry.domEvent === "focus" &&
        entry.requestedDelivery === "auto" &&
        entry.effectiveDelivery === "native" &&
        entry.deliveryReason === "capture-policy",
    ),
  );
  assert.ok(
    telemetry.some(
      (entry) =>
        entry.kind === "bind_event" &&
        entry.domEvent === "blur" &&
        entry.requestedDelivery === "auto" &&
        entry.effectiveDelivery === "native" &&
        entry.deliveryReason === "once-policy",
    ),
  );
});

test("malformed dynamic event extraction plans fail closed", () => {
  const { host, runtime } = mountWith([
    { op: Op.resetDom },
    { op: Op.createElement, a: 1, s: "input" },
    { op: Op.appendChild, a: 0, b: 1 },
  ]);

  const bind = (eventExtractionPlan, overrides = {}) => ({
    dynamic: {
      op: DynamicOp.bindEvent,
      elemId: 1,
      eventName: "keydown",
      eventId: 31,
      options: overrides.options ?? 0,
      eventExtractionPlan,
    },
  });

  const duplicateFields = concatBytes([
    new Uint8Array([BoundarySchemaTag.record, 2]),
    fieldSpec("key", new Uint8Array([BoundarySchemaTag.text, EventExtractionSource.event, EventExtractionLeaf.key])),
    fieldSpec("key", new Uint8Array([BoundarySchemaTag.text, EventExtractionSource.event, EventExtractionLeaf.key])),
  ]);
  const nestedRecord = concatBytes([
    new Uint8Array([BoundarySchemaTag.record, 1]),
    fieldSpec(
      "outer",
      concatBytes([
        new Uint8Array([BoundarySchemaTag.record, 1]),
        fieldSpec("inner", new Uint8Array([BoundarySchemaTag.text, EventExtractionSource.event, EventExtractionLeaf.key])),
      ]),
    ),
  ]);
  const invalidUtf8Field = concatBytes([
    new Uint8Array([BoundarySchemaTag.record, 1, 1, 0xff]),
    new Uint8Array([BoundarySchemaTag.text, EventExtractionSource.event, EventExtractionLeaf.key]),
  ]);

  const cases = [
    [bind(new Uint8Array([99])), /malformed event extraction plan.*unknown shape tag 99/],
    [
      bind(new Uint8Array([BoundarySchemaTag.text, 99, EventExtractionLeaf.key])),
      /malformed event extraction plan.*unknown event extraction source tag 99/,
    ],
    [
      bind(new Uint8Array([BoundarySchemaTag.bool, EventExtractionSource.event, EventExtractionLeaf.value])),
      /malformed event extraction plan.*bool event extraction used incompatible leaf tag 2/,
    ],
    [
      bind(new Uint8Array([BoundarySchemaTag.text, EventExtractionSource.currentTarget, EventExtractionLeaf.key])),
      /malformed event extraction plan.*source tag 3 cannot produce leaf tag 1/,
    ],
    [
      bind(new Uint8Array([BoundarySchemaTag.bool, EventExtractionSource.event, EventExtractionLeaf.checked])),
      /malformed event extraction plan.*source tag 1 cannot produce leaf tag 3/,
    ],
    [
      bind(new Uint8Array([BoundarySchemaTag.text, EventExtractionSource.target, EventExtractionLeaf.detail])),
      /malformed event extraction plan.*source tag 2 cannot produce leaf tag 5/,
    ],
    [
      bind(new Uint8Array([BoundarySchemaTag.bool, EventExtractionSource.event, EventExtractionLeaf.detail])),
      /malformed event extraction plan.*bool event extraction used incompatible leaf tag 5/,
    ],
    [
      bind(new Uint8Array([BoundarySchemaTag.record, 0])),
      /malformed event extraction plan.*record field count was zero/,
    ],
    [
      bind(new Uint8Array([BoundarySchemaTag.record, 1, 3, 0x6b])),
      /malformed event extraction plan.*record_field_name extends beyond extraction plan length/,
    ],
    [bind(duplicateFields), /malformed event extraction plan.*duplicated/],
    [bind(invalidUtf8Field), /malformed event extraction plan.*field name was not valid UTF-8/],
    [bind(nestedRecord), /malformed event extraction plan.*nested record shape/],
    [
      bind(keyShiftEventExtractionPlan, { options: 1 << 12 }),
      /unsupported listener option bits/,
    ],
  ];

  for (const [entry, pattern] of cases) {
    host.writeCommands([entry]);
    assert.throws(() => runtime.applyPendingCommands("bad-bind-event"), pattern);
  }
});

test("dynamic event extraction failure fails closed without dispatching reducer", () => {
  const telemetry = [];
  const { host, root } = mountWith(
    [
      { op: Op.resetDom },
      { op: Op.createElement, a: 1, s: "button" },
      { op: Op.setText, a: 1, s: "click" },
      {
        dynamic: {
          op: DynamicOp.bindEvent,
          elemId: 1,
          eventName: "click",
          eventId: 32,
          options: 0,
          eventExtractionPlan: eventKeyEventExtractionPlan,
        },
      },
      { op: Op.appendChild, a: 0, b: 1 },
    ],
    { telemetry: (entry) => telemetry.push(entry) },
  );

  assert.throws(
    () => fireEvent(findByText(root, "button", "click"), "click"),
    /event extraction text leaf did not yield a string/,
  );
  assert.deepEqual(host.dispatches, []);
  assert.ok(
    telemetry.some(
      (entry) =>
        entry.kind === "event_payload_error" &&
        entry.eventId === 32 &&
        entry.payloadKind === "str" &&
        entry.boundarySchema === "text" &&
        entry.eventExtractionPlan === "text:event.key" &&
        /event extraction text leaf did not yield a string/.test(entry.message),
    ),
  );
});

test("memory growth during byte payload allocation keeps response commands readable", () => {
  const { host, root } = mountWith(
    [
      { op: Op.resetDom },
      { op: Op.createElement, a: 1, s: "input" },
      {
        dynamic: {
          op: DynamicOp.bindEvent,
          elemId: 1,
          eventName: "keydown",
          eventId: 41,
          options: 0,
          eventExtractionPlan: keyShiftEventExtractionPlan,
        },
      },
      { op: Op.appendChild, a: 0, b: 1 },
      { op: Op.createText, a: 2, s: "start" },
      { op: Op.appendChild, a: 0, b: 2 },
    ],
    { allocBase: allocBaseLeavingOneByteAfterInitialEnvironment() },
  );
  host.eventResponses.set(41, () => [
    { op: Op.setText, a: 2, s: "keyed" },
    {
      dynamic: {
        op: DynamicOp.setAttrText,
        elemId: 1,
        name: "data-last-key",
        value: "Enter",
      },
    },
  ]);

  const input = findNode(root, (node) => node.tagName === "INPUT");
  const before = host.memory.buffer.byteLength;
  fireEvent(input, "keydown", { key: "Enter", shiftKey: false });

  assert.ok(host.memory.buffer.byteLength > before);
  assert.deepEqual(host.dispatches, [
    { eventId: 41, kind: PayloadKind.bytes, payloadBytes: keyShiftBytes("Enter", false) },
  ]);
  assert.ok(findTextNode(root, "keyed"));
  assert.equal(input.getAttribute("data-last-key"), "Enter");
});

test("remove_node on a subtree root releases every descendant registration exactly once", () => {
  const { host, root, runtime } = mountWith([
    { op: Op.resetDom },
    { op: Op.createElement, a: 1, s: "section" },
    { op: Op.createElement, a: 2, s: "div" },
    { op: Op.createElement, a: 3, s: "input" },
    { op: Op.setValue, a: 3, s: "draft" },
    { op: Op.bindInput, a: 3, b: 31 },
    { op: Op.createElement, a: 4, s: "button" },
    { op: Op.setText, a: 4, s: "inner" },
    { op: Op.bindClick, a: 4, b: 41 },
    { op: Op.createText, a: 5, s: "leaf" },
    { op: Op.createElement, a: 6, s: "button" },
    { op: Op.setText, a: 6, s: "outer" },
    { op: Op.bindClick, a: 6, b: 61 },
    { op: Op.appendChild, a: 0, b: 1 },
    { op: Op.appendChild, a: 1, b: 2 },
    { op: Op.appendChild, a: 2, b: 3 },
    { op: Op.appendChild, a: 2, b: 4 },
    { op: Op.appendChild, a: 2, b: 5 },
    { op: Op.appendChild, a: 0, b: 6 },
  ]);
  const inner = findByText(root, "button", "inner");
  const outer = findByText(root, "button", "outer");
  const input = findNode(root, (node) => node.tagName === "INPUT");
  assert.equal(runtime.nodes.size, 7);
  assert.equal(runtime.eventCleanups.size, 3);
  assert.equal(runtime.controlledInputs.has(3), true);

  host.writeCommands([{ op: Op.removeNode, a: 1 }]);
  runtime.applyPendingCommands("remove-subtree");

  assert.deepEqual([...runtime.nodes.keys()].sort(), [0, 6]);
  assert.deepEqual([...runtime.eventCleanups.keys()], ["6:click"]);
  assert.equal(runtime.controlledInputs.size, 0);
  assert.equal(runtime.pendingSelectValues.size, 0);
  assert.equal(inner.listeners.get("click")?.length ?? 0, 0);
  assert.equal(input.listeners.get("input")?.length ?? 0, 0);
  assert.equal(root.childNodes.length, 1);
  fireEvent(inner, "click");
  fireEvent(input, "input");
  assert.deepEqual(host.dispatches, []);
  fireEvent(outer, "click");
  assert.equal(host.dispatches.length, 1);

  host.writeCommands([
    { op: Op.createElement, a: 3, s: "input" },
    { op: Op.setValue, a: 3, s: "fresh" },
    { op: Op.appendChild, a: 0, b: 3 },
    { op: Op.removeNode, a: 6 },
  ]);
  runtime.applyPendingCommands("reuse-ids");
  assert.deepEqual([...runtime.nodes.keys()].sort(), [0, 3]);
  assert.equal(runtime.eventCleanups.size, 0);
  assert.equal(runtime.controlledInputs.has(3), true);
  assert.equal(findNode(root, (node) => node.tagName === "INPUT").value, "fresh");
});

test("clear_event and remove_node release DOM listeners", () => {
  const { host, root, runtime } = mountWith([
    { op: Op.resetDom },
    { op: Op.createElement, a: 1, s: "button" },
    { op: Op.setText, a: 1, s: "click" },
    { op: Op.bindClick, a: 1, b: 1 },
    { op: Op.appendChild, a: 0, b: 1 },
  ]);

  const button = findByText(root, "button", "click");
  runtime.applyCommand({ op: Op.clearEvent, a: 1, b: 1, c: 0, d: 0, e: 0 });
  fireEvent(button, "click");
  assert.deepEqual(host.dispatches, []);

  runtime.applyCommand({
    op: Op.bindClick,
    a: 1,
    b: 2,
    c: 0,
    d: 0,
    e: 0,
  });
  runtime.applyCommand({ op: Op.removeNode, a: 1, b: 0, c: 0, d: 0, e: 0 });
  fireEvent(button, "click");
  assert.deepEqual(host.dispatches, []);
});

test("telemetry records command batches DOM events and event payload dispatches", () => {
  const telemetry = [];
  const { host, root } = mountWith(
    [
      { op: Op.resetDom },
      { op: Op.createElement, a: 1, s: "button" },
      { op: Op.setText, a: 1, s: "click" },
      { op: Op.bindClick, a: 1, b: 17 },
      { op: Op.appendChild, a: 0, b: 1 },
    ],
    { telemetry: (entry) => telemetry.push(entry) },
  );
  host.eventResponses.set(17, () => [{ op: Op.setText, a: 1, s: "clicked" }]);

  fireEvent(findByText(root, "button", "click"), "click");

  assert.equal(findByText(root, "button", "clicked").textContent, "clicked");
  assert.ok(
    telemetry.some(
      (entry) =>
        entry.kind === "commands" &&
        entry.phase === "mount" &&
        entry.opCounts.create_element === 1 &&
        entry.opCounts.bind_click === 1,
    ),
  );
  assert.ok(
    telemetry.some(
      (entry) =>
        entry.kind === "dom_event" &&
        entry.domEvent === "click" &&
        entry.eventId === 17 &&
        entry.requestedDelivery === "auto" &&
        entry.effectiveDelivery === "native" &&
        entry.deliveryReason === "native-runtime-default" &&
        entry.boundarySchema === "unit" &&
        entry.currentTarget.tag === "button",
    ),
  );
  assert.ok(
    telemetry.some(
      (entry) =>
        entry.kind === "bind_event" &&
        entry.domEvent === "click" &&
        entry.eventId === 17 &&
        entry.requestedDelivery === "auto" &&
        entry.effectiveDelivery === "native" &&
        entry.deliveryReason === "native-runtime-default",
    ),
  );
  assert.ok(
    telemetry.some(
      (entry) =>
        entry.kind === "event_payload" &&
        entry.eventId === 17 &&
        entry.payloadKind === "unit" &&
        entry.boundarySchema === "unit" &&
        entry.eventExtractionPlan === "unit",
    ),
  );
  assert.ok(
    telemetry.some(
      (entry) =>
        entry.kind === "commands" &&
        entry.phase === "event:17" &&
        entry.count === 1 &&
        entry.commands[0].op === "set_text" &&
        entry.commands[0].text === "clicked",
    ),
  );
});

test("allocation telemetry groups live wasm allocations by phase and size", () => {
  const telemetry = [];
  mountWith([], {
    telemetry: (entry) => telemetry.push(entry),
    debugAllocations: [
      { phase: 201, size: 8 },
      { phase: 201, size: 8 },
      { phase: 409, size: 24 },
    ],
  });

  const checkpoint = telemetry.find(
    (entry) => entry.kind === "allocation_checkpoint" && entry.phase === "mount",
  );
  assert.equal(checkpoint.live, 3);
  assert.equal(checkpoint.bytes, 40);
  assert.deepEqual(checkpoint.cohorts, [
    { phase: 201, size: 8, count: 2, bytes: 16 },
    { phase: 409, size: 24, count: 1, bytes: 24 },
  ]);
});

test("memory growth during dispatch keeps the response command stream readable", () => {
  const { host, root } = mountWith(
    [
      { op: Op.resetDom },
      { op: Op.createElement, a: 1, s: "input" },
      { op: Op.bindInput, a: 1, b: 2 },
      { op: Op.appendChild, a: 0, b: 1 },
      { op: Op.createText, a: 2, s: "start" },
      { op: Op.appendChild, a: 0, b: 2 },
    ],
    { allocBase: allocBaseLeavingOneByteAfterInitialEnvironment() },
  );
  host.eventResponses.set(2, (dispatch) => [
    { op: Op.setText, a: 2, s: dispatch.payload },
    {
      dynamic: {
        op: DynamicOp.setAttrText,
        elemId: 1,
        name: "data-last-input",
        value: dispatch.payload,
      },
    },
  ]);

  const input = findNode(root, (node) => node.tagName === "INPUT");
  input.value = "after-grow";
  const before = host.memory.buffer.byteLength;
  fireEvent(input, "input");

  assert.ok(host.memory.buffer.byteLength > before);
  assert.deepEqual(host.dispatches, [
    { eventId: 2, kind: PayloadKind.str, payload: "after-grow" },
  ]);
  assert.ok(findTextNode(root, "after-grow"));
  assert.equal(input.getAttribute("data-last-input"), "after-grow");
});

test("timer commands register intervals and timer ticks re-enter wasm", () => {
  const { host, root, runtime } = mountWith([
    { op: Op.resetDom },
    { op: Op.createText, a: 1, s: "tick-start" },
    { op: Op.appendChild, a: 0, b: 1 },
    { op: Op.startInterval, a: 7, b: 60000 },
  ]);
  host.timerResponses.set(7, () => [{ op: Op.setText, a: 1, s: "tick-fired" }]);

  try {
    assert.equal(runtime.intervals.has(7), true);
    runtime.tickTimer(7);
    assert.deepEqual(host.timers, [7]);
    assert.ok(findTextNode(root, "tick-fired"));

    runtime.applyCommand({ op: Op.cancelInterval, a: 7, b: 0, c: 0, d: 0, e: 0 });
    assert.equal(runtime.intervals.has(7), false);
    runtime.tickTimer(7);
    assert.deepEqual(host.timers, [7]);
  } finally {
    runtime.cancelInterval(7);
  }
});

test("task commands marshal request and resolve payloads by request id", () => {
  const telemetry = [];
  const { host, runtime } = mountWith([
    { op: Op.resetDom },
    { op: Op.startTask, a: 5, strings: ["lookup", "roc"] },
  ], { telemetry: (entry) => telemetry.push(entry) });

  assert.deepEqual(
    [...runtime.tasks.entries()].map(([requestId, task]) => ({
      requestId,
      name: task.name,
      request: task.request,
      aborted: task.controller.signal.aborted,
    })),
    [{ requestId: 5, name: "lookup", request: "roc", aborted: false }],
  );

  runtime.resolveTask(5, "Roc result");
  assert.deepEqual(host.resolutions, [
    { requestId: 5, payload: "Roc result", failed: false },
  ]);
  assert.equal(runtime.tasks.has(5), false);
  assert.ok(
    telemetry.some(
      (entry) =>
        entry.kind === "start_task" &&
        entry.requestId === 5 &&
        entry.name === "lookup" &&
        entry.request === "roc",
    ),
  );
  assert.ok(
    telemetry.some(
      (entry) =>
        entry.kind === "task_resolution" &&
        entry.requestId === 5 &&
        entry.name === "lookup" &&
        entry.request === "roc" &&
        entry.failed === false &&
        entry.payloadLen === "Roc result".length,
    ),
  );

  runtime.applyCommand({ op: Op.startTask, a: 6, b: 0, c: 6, d: 6, e: 3 });
  runtime.applyCommand({ op: Op.cancelTask, a: 6, b: 0, c: 0, d: 0, e: 0 });
  assert.equal(runtime.tasks.has(6), false);
  assert.ok(
    telemetry.some(
      (entry) =>
        entry.kind === "cancel_task" &&
        entry.requestId === 6 &&
        entry.name === "lookup" &&
        entry.request === "roc",
    ),
  );
});

test("stale manual task resolutions reach host classification with telemetry", () => {
  const telemetry = [];
  const { host, runtime } = mountWith([{ op: Op.resetDom }], {
    telemetry: (entry) => telemetry.push(entry),
  });

  runtime.startTask(404, "lookup", "old");
  runtime.cancelTask(404);
  runtime.resolveTask(404, "late payload");

  assert.deepEqual(host.resolutions, [
    { requestId: 404, payload: "late payload", failed: false },
  ]);
  assert.ok(
    telemetry.some(
      (entry) =>
        entry.kind === "ignored_task_resolution" &&
        entry.requestId === 404 &&
        entry.name === "lookup" &&
        entry.failed === false,
    ),
  );
});

test("never-issued manual task resolutions fail loudly", () => {
  const telemetry = [];
  const { host, runtime } = mountWith([{ op: Op.resetDom }], {
    telemetry: (entry) => telemetry.push(entry),
  });

  assert.throws(() => runtime.resolveTask(404, "late payload"), /task result had no matching pending request: 404/);
  assert.deepEqual(host.resolutions, []);
  assert.ok(
    telemetry.some(
      (entry) =>
        entry.kind === "unknown_task_resolution" &&
        entry.requestId === 404 &&
        entry.failed === false,
    ),
  );
});

test("task cancellation aborts stale async settlement and keeps fresh request current", async () => {
  const deferred = [];
  const telemetry = [];
  const { host, runtime } = mountWith([{ op: Op.resetDom }], {
    telemetry: (entry) => telemetry.push(entry),
    taskHandler: ({ requestId, signal }) =>
      new Promise((resolve) => {
        deferred.push({ requestId, signal, resolve });
      }),
  });

  runtime.startTask(10, "lookup", "old");
  runtime.cancelTask(10);
  runtime.startTask(11, "lookup", "fresh");

  assert.equal(deferred[0].signal.aborted, true);
  assert.equal(deferred[1].signal.aborted, false);

  deferred[0].resolve("stale");
  deferred[1].resolve("ready");
  await Promise.resolve();
  await Promise.resolve();

  assert.deepEqual(host.resolutions, [
    { requestId: 10, payload: "stale", failed: false },
    { requestId: 11, payload: "ready", failed: false },
  ]);
  assert.ok(
    telemetry.some(
      (entry) =>
        entry.kind === "ignored_task_resolution" &&
        entry.requestId === 10 &&
        entry.name === "lookup" &&
        entry.failed === false,
    ),
  );
});

test("task handler rejections resolve through the task failure path", async () => {
  const telemetry = [];
  const { host } = mountWith(
    [
      { op: Op.resetDom },
      { op: Op.startTask, a: 8, strings: ["lookup", "roc"] },
    ],
    {
      telemetry: (entry) => telemetry.push(entry),
      taskHandler: () => Promise.reject(new Error("offline")),
    },
  );

  await Promise.resolve();
  await Promise.resolve();

  assert.deepEqual(host.resolutions, [
    { requestId: 8, payload: "offline", failed: true },
  ]);
  assert.ok(
    telemetry.some(
      (entry) =>
        entry.kind === "task_resolution" &&
        entry.requestId === 8 &&
        entry.name === "lookup" &&
        entry.request === "roc" &&
        entry.failed === true &&
        entry.payloadLen === "offline".length,
    ),
  );
});

test("async task resolution traps report onError without retrying as task failure", async () => {
  const errors = [];
  const { host } = mountWith(
    [
      { op: Op.resetDom },
      { op: Op.startTask, a: 9, strings: ["lookup", "roc"] },
    ],
    {
      taskHandler: () => Promise.resolve("ready payload"),
      onError: (err) => errors.push(err),
    },
  );
  host.resolveTrapMessage = "roc_ui_resolve trapped while applying task result";

  await Promise.resolve();
  await Promise.resolve();

  assert.deepEqual(host.resolutions, [
    { requestId: 9, payload: "ready payload", failed: false },
  ]);
  assert.equal(errors.length, 1);
  assert.match(errors[0].message, /roc_ui_resolve trapped while applying task result/);
});

test("HTTP request payload codec preserves method URI timeout headers and body bytes", () => {
  const body = new Uint8Array([0, 82, 255]);
  const payload = encodeHttpRequestPayload({
    method: "PATCH",
    uri: "/api/items/42",
    timeoutMs: 250,
    headers: [
      ["x-mode", "test"],
      ["x-mode", "again"],
    ],
    body,
  });

  assert.deepEqual(decodeHttpRequestPayload(payload), {
    method: "PATCH",
    uri: "/api/items/42",
    timeoutMs: 250,
    headers: [
      ["x-mode", "test"],
      ["x-mode", "again"],
    ],
    body,
  });
});

test("HTTP response payload codec preserves status duplicate headers and body bytes", () => {
  const body = new Uint8Array([1, 2, 3, 255]);
  const payload = encodeHttpResponsePayload({
    status: 202,
    headers: [
      ["set-cookie", "a=1"],
      ["set-cookie", "b=2"],
      ["x-trace", "first"],
      ["x-trace", "second"],
    ],
    body,
  });

  assert.deepEqual(decodeHttpResponsePayload(payload), {
    status: 202,
    headers: [
      ["set-cookie", "a=1"],
      ["set-cookie", "b=2"],
      ["x-trace", "first"],
      ["x-trace", "second"],
    ],
    body,
  });
});

test("HTTP fetch task handler maps request envelopes to fetch response envelopes", async () => {
  const calls = [];
  const payload = encodeHttpRequestPayload({
    method: "POST",
    uri: "/api/widgets",
    timeoutMs: 500,
    headers: [["content-type", "text/plain"]],
    body: "hello",
  });
  const value = await httpFetchTaskHandler({
    name: "http:send:widgets",
    request: payload,
    signal: new AbortController().signal,
    fetchImpl: async (url, options) => {
      calls.push({
        url,
        method: options.method,
        headers: options.headers,
        body: [...options.body],
        hasSignal: options.signal instanceof AbortSignal,
        optionKeys: Object.keys(options).sort(),
      });
      return {
        status: 201,
        headers: {
          entries: () =>
            [
              ["content-type", "text/plain"],
              ["x-reply", "ok"],
              ["x-reply", "again"],
            ][Symbol.iterator](),
        },
        arrayBuffer: async () => textBytes("created").buffer,
      };
    },
  });

  assert.deepEqual(calls, [
    {
      url: "/api/widgets",
      method: "POST",
      headers: [["content-type", "text/plain"]],
      body: [...textBytes("hello")],
      hasSignal: true,
      optionKeys: ["body", "headers", "method", "signal"],
    },
  ]);
  assert.deepEqual(decodeHttpResponsePayload(value), {
    status: 201,
    headers: [
      ["content-type", "text/plain"],
      ["x-reply", "ok"],
      ["x-reply", "again"],
    ],
    body: textBytes("created"),
  });
});

test("HTTP fetch task handler reports network failures as HTTP error envelopes", async () => {
  await assert.rejects(
    () =>
      httpFetchTaskHandler({
        name: "http:send:widgets",
        request: encodeHttpRequestPayload({ uri: "/api/widgets" }),
        signal: new AbortController().signal,
        fetchImpl: async () => {
          throw new Error("offline");
        },
      }),
    /roc-http-error-v1\nnetwork/,
  );
});

test("ops API task handler serves changing documented endpoints", async () => {
  assert.equal(opsApiTaskHandler({ name: "lookup", request: "roc" }), null);

  const backend = createOpsBackend();
  const value = await opsApiTaskHandler({
    name: "http:send:summary",
    request: encodeHttpRequestPayload({ method: "GET", uri: "/api/ops/summary" }),
  }, backend);
  const response = decodeHttpResponsePayload(value);
  assert.equal(response.status, 200);
  assert.deepEqual(response.headers, [["content-type", "text/plain; charset=utf-8"]]);
  assert.match(new TextDecoder().decode(response.body), /Overall:/);
  assert.match(new TextDecoder().decode(response.body), /Traffic:/);

  const firstDashboard = await opsApiTaskHandler({
    name: "http:send:dashboard",
    request: encodeHttpRequestPayload({ method: "GET", uri: "/api/ops/dashboard" }),
  }, backend);
  const secondDashboard = await opsApiTaskHandler({
    name: "http:send:dashboard",
    request: encodeHttpRequestPayload({ method: "GET", uri: "/api/ops/dashboard" }),
  }, backend);
  assert.notEqual(
    new TextDecoder().decode(decodeHttpResponsePayload(firstDashboard).body),
    new TextDecoder().decode(decodeHttpResponsePayload(secondDashboard).body),
  );

  assert.equal(
    opsApiTaskHandler({
      name: "http:send:private",
      request: encodeHttpRequestPayload({ method: "GET", uri: "/api/private" }),
    }),
    null,
  );

  assert.throws(
    () =>
      opsApiTaskHandler({
        name: "http:send:dashboard",
        request: encodeHttpRequestPayload({ method: "POST", uri: "/api/ops/dashboard" }),
      }),
    /roc-http-error-v1\nunsupported/,
  );
});

test("API request console task handler serves deterministic POST scenarios", async () => {
  const success = await apiRequestConsoleTaskHandler({
    name: "http:send:api-request-console",
    request: encodeHttpRequestPayload({
      method: "POST",
      uri: "/api/api-request-console",
      headers: [["x-scenario", "success"]],
      body: '{"lookup":"customer-42"}',
    }),
  });
  const successResponse = decodeHttpResponsePayload(success);
  assert.equal(successResponse.status, 201);
  assert.deepEqual(successResponse.headers, [
    ["content-type", "application/json; charset=utf-8"],
    ["x-result", "ok"],
  ]);
  assert.match(new TextDecoder().decode(successResponse.body), /customer-42/);

  const missing = await apiRequestConsoleTaskHandler({
    name: "http:send:api-request-console",
    request: encodeHttpRequestPayload({
      method: "POST",
      uri: "/api/api-request-console",
      headers: [["x-scenario", "missing"]],
    }),
  });
  assert.equal(decodeHttpResponsePayload(missing).status, 404);

  assert.throws(
    () =>
      apiRequestConsoleTaskHandler({
        name: "http:send:api-request-console",
        request: encodeHttpRequestPayload({
          method: "POST",
          uri: "/api/api-request-console",
          headers: [["x-scenario", "failure"]],
        }),
      }),
    /roc-http-error-v1\nnetwork/,
  );
});

test("public example task handler combines ops, API console, and lookup tasks", async () => {
  const lookup = await lookupTaskHandler({
    name: "lookup",
    request: "roc",
    signal: new AbortController().signal,
  });
  assert.match(lookup, /Top results for "roc"/);

  await assert.rejects(
    () =>
      lookupTaskHandler({
        name: "lookup",
        request: "fail",
        signal: new AbortController().signal,
      }),
    /offline search index/,
  );

  const api = await publicExampleTaskHandler({
    name: "http:send:api-request-console",
    request: encodeHttpRequestPayload({
      method: "POST",
      uri: "/api/api-request-console",
    }),
  });
  assert.equal(decodeHttpResponsePayload(api).status, 201);

  const ops = await publicExampleTaskHandler({
    name: "http:send:summary",
    request: encodeHttpRequestPayload({ method: "GET", uri: "/api/ops/summary" }),
  });
  assert.match(new TextDecoder().decode(decodeHttpResponsePayload(ops).body), /Overall:/);
});

function textBytes(value) {
  return new TextEncoder().encode(value);
}
