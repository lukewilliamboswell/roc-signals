// Primitive browser HTTP execution. Scheduling, occurrence identity and the
// returned action belong to the engine; this module performs one request.
export const HttpEffectLimits = Object.freeze({ bodyBytes: 8 * 1024 * 1024, headerBytes: 65536, headers: 256 });

export class HttpEffectError extends Error {
  constructor(kind, message) {
    super(message);
    this.name = "HttpEffectError";
    this.kind = kind;
  }
}

// This framing carries only primitive HTTP data, never Roc headers or tags.
// Success: 0, status, header count, length-prefixed header pairs and body.
// Failure: kind (1..5), length-prefixed UTF-8 detail. Integers are LE u32.
function encodeResult(value, failure) {
  const encoder = new TextEncoder();
  const fields = [];
  let size = 0;
  const word = value => { fields.push(value); size += 4; };
  const bytes = value => { word(value.length); fields.push(value); size += value.length; };
  if (failure) {
    const kind = { InvalidRequest: 1, Network: 2, Timeout: 3, TooLarge: 4, Unavailable: 5 }[failure.kind];
    if (!kind) throw failure;
    word(kind);
    bytes(encoder.encode(failure.message.slice(0, 4096)));
  } else {
    word(0); word(value.status); word(value.headers.length);
    for (const [name, content] of value.headers) { bytes(encoder.encode(name)); bytes(encoder.encode(content)); }
    bytes(value.body);
  }
  const result = new Uint8Array(size);
  const view = new DataView(result.buffer);
  let offset = 0;
  for (const field of fields) {
    if (typeof field === "number") { view.setUint32(offset, field, true); offset += 4; }
    else { result.set(field, offset); offset += field.length; }
  }
  return result;
}

export function createHttpEffectImports(getExports, options = {}) {
  const execute = async (methodPtr, methodLen, uriPtr, uriLen, timeout, headersPtr, headerCount, bodyPtr, bodyLen, outLenPtr) => {
    const host = getExports();
    const memory = host.memory.buffer;
    const decoder = new TextDecoder("utf-8", { fatal: true });
    const text = (ptr, len) => decoder.decode(new Uint8Array(memory, ptr, len));
    let value;
    let failure;
    try {
      if (headerCount > HttpEffectLimits.headers || bodyLen > HttpEffectLimits.bodyBytes || methodLen > 65536 || uriLen > 65536) {
        throw new HttpEffectError("TooLarge", "HTTP request exceeds browser limits");
      }
      const view = new DataView(memory, headersPtr, headerCount * 16);
      const headers = [];
      let headerBytes = 0;
      for (let index = 0; index < headerCount; index++) {
        const at = index * 16;
        const nameLen = view.getUint32(at + 4, true);
        const valueLen = view.getUint32(at + 12, true);
        headerBytes += nameLen + valueLen;
        if (headerBytes > HttpEffectLimits.headerBytes) throw new HttpEffectError("TooLarge", "HTTP headers exceed browser limits");
        headers.push([text(view.getUint32(at, true), nameLen), text(view.getUint32(at + 8, true), valueLen)]);
      }
      // WebAssembly exposes i64 arguments as signed BigInts, including this
      // u64 field. Recover its bits before interpreting the no-timeout marker.
      const timeoutBits = BigInt.asUintN(64, timeout);
      value = await fetchHttpEffect({
        method: text(methodPtr, methodLen), uri: text(uriPtr, uriLen), headers,
        body: new Uint8Array(memory, bodyPtr, bodyLen).slice(),
        timeoutMs: timeoutBits === 0xffffffffffffffffn ? null : Number(timeoutBits),
      }, options);
    } catch (error) {
      if (!(error instanceof HttpEffectError)) throw error;
      failure = error;
    }
    if (options.isPoisoned?.()) throw new Error("HTTP effect cannot resume a poisoned Signals instance");
    const encoded = encodeResult(value, failure);
    const ptr = host.roc_alloc(encoded.length, 1);
    if (!ptr) throw new Error("HTTP response allocation failed");
    // Allocation may grow memory; neither the request view nor an older view
    // can be reused when publishing the completed primitive result.
    new Uint8Array(host.memory.buffer, ptr, encoded.length).set(encoded);
    new DataView(host.memory.buffer).setUint32(outLenPtr, encoded.length, true);
    return ptr;
  };
  return {
    roc_ui_http_send: typeof WebAssembly.Suspending === "function"
      ? new WebAssembly.Suspending(execute)
      : () => { throw new Error("HTTP effects require WebAssembly JSPI"); },
  };
}

function validateHeaders(headers) {
  if (!Array.isArray(headers) || headers.length > HttpEffectLimits.headers) {
    throw new HttpEffectError("TooLarge", "HTTP header count exceeds 256");
  }
  let bytes = 0;
  const encoder = new TextEncoder();
  for (const pair of headers) {
    if (!Array.isArray(pair) || pair.length !== 2 || pair.some(value => typeof value !== "string")) {
      throw new HttpEffectError("InvalidRequest", "HTTP headers must be name/value text pairs");
    }
    bytes += encoder.encode(pair[0]).length + encoder.encode(pair[1]).length;
    if (bytes > HttpEffectLimits.headerBytes) throw new HttpEffectError("TooLarge", "HTTP headers exceed 65536 bytes");
  }
}

async function responseBytes(response) {
  if (response.body === null) return new Uint8Array();
  const reader = response.body.getReader();
  let buffer = new Uint8Array(0);
  let length = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      const nextLength = length + value.byteLength;
      if (nextLength > HttpEffectLimits.bodyBytes) {
        await reader.cancel();
        throw new HttpEffectError("TooLarge", "HTTP response body exceeds 8 MiB");
      }
      if (nextLength > buffer.length) {
        const grown = new Uint8Array(Math.min(HttpEffectLimits.bodyBytes, Math.max(nextLength, 65536, buffer.length * 2)));
        grown.set(buffer.subarray(0, length));
        buffer = grown;
      }
      buffer.set(value, length);
      length = nextLength;
    }
  } finally {
    reader.releaseLock();
  }
  return buffer.slice(0, length);
}

export async function fetchHttpEffect(request, { fetchImpl = globalThis.fetch, signal } = {}) {
  if (signal?.aborted) throw new HttpEffectError("Unavailable", "HTTP executor shut down");
  if (typeof fetchImpl !== "function") throw new HttpEffectError("Unavailable", "fetch is unavailable");
  if (typeof request.method !== "string" || typeof request.uri !== "string" || !(request.body instanceof Uint8Array)) {
    throw new HttpEffectError("InvalidRequest", "HTTP request has invalid primitive fields");
  }
  if (request.body.byteLength > HttpEffectLimits.bodyBytes) throw new HttpEffectError("TooLarge", "HTTP request body exceeds 8 MiB");
  validateHeaders(request.headers);
  if (request.timeoutMs !== null && (!Number.isSafeInteger(request.timeoutMs) || request.timeoutMs < 0 || request.timeoutMs > 2147483647)) {
    throw new HttpEffectError("InvalidRequest", "HTTP timeout exceeds the browser timer range");
  }
  const controller = new AbortController();
  const abort = () => controller.abort();
  if (signal?.aborted) abort();
  else signal?.addEventListener("abort", abort, { once: true });
  let timedOut = false;
  const timer = request.timeoutMs === null ? null : setTimeout(() => {
    timedOut = true;
    controller.abort();
  }, request.timeoutMs);
  try {
    const response = await fetchImpl(request.uri, {
      method: request.method,
      headers: request.headers,
      body: request.body.length ? request.body : undefined,
      signal: controller.signal,
    });
    const headers = [...response.headers.entries()];
    validateHeaders(headers);
    const body = await responseBytes(response);
    return { status: response.status, headers, body };
  } catch (error) {
    if (error instanceof HttpEffectError) throw error;
    if (timedOut) throw new HttpEffectError("Timeout", "HTTP request timed out");
    if (signal?.aborted) throw new HttpEffectError("Unavailable", "HTTP executor shut down");
    throw new HttpEffectError("Network", String(error?.message ?? error));
  } finally {
    controller.abort();
    if (timer !== null) clearTimeout(timer);
    signal?.removeEventListener("abort", abort);
  }
}
