import test from "node:test";
import assert from "node:assert/strict";

import { SignalsRuntime } from "../../www/static/signals.mjs";

// Applying a command can re-enter the host: moving DOM focus fires a focus
// listener, which dispatches into Roc, and every host entry point begins by
// clearing the string and dynamic command buffers. Command payloads must
// therefore be snapshotted when the batch is drained, not read lazily during
// apply, or the records still queued in the apply loop read from cleared
// buffers.
//
// Before the snapshot, the dynamic path threw "dynamic render command
// referenced an empty dynamic buffer" and the string path silently decoded
// from address 0.

function runtimeWithBuffers({ strings, dynamic }) {
  const runtime = Object.create(SignalsRuntime.prototype);
  const memory = new WebAssembly.Memory({ initial: 1 });
  const bytes = new Uint8Array(memory.buffer);

  const stringBase = 16;
  const dynamicBase = 1024;
  bytes.set(strings, stringBase);
  bytes.set(dynamic, dynamicBase);

  let cleared = false;
  runtime.commandBuffers = null;
  runtime.commandDecodeStats = null;
  runtime.views = {
    afterHostCall() {},
    get u8() {
      return new Uint8Array(memory.buffer);
    },
  };
  runtime.exports = {
    memory,
    roc_ui_string_buffer_ptr: () => (cleared ? 0 : stringBase),
    roc_ui_string_buffer_len: () => (cleared ? 0 : strings.length),
    roc_ui_dynamic_buffer_ptr: () => (cleared ? 0 : dynamicBase),
    roc_ui_dynamic_buffer_len: () => (cleared ? 0 : dynamic.length),
  };
  return { runtime, clearHostBuffers: () => { cleared = true; } };
}

test("snapshotted string payloads survive a re-entrant host call clearing the buffers", () => {
  const strings = new TextEncoder().encode("hello world");
  const { runtime, clearHostBuffers } = runtimeWithBuffers({ strings, dynamic: new Uint8Array(0) });

  runtime.commandBuffers = runtime.snapshotCommandBuffers();
  clearHostBuffers();

  assert.equal(runtime.readString(0, 5), "hello");
  assert.equal(runtime.readString(6, 5), "world");
});

test("snapshotted dynamic payloads survive a re-entrant host call clearing the buffers", () => {
  const dynamic = new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8]);
  const { runtime, clearHostBuffers } = runtimeWithBuffers({ strings: new Uint8Array(0), dynamic });

  runtime.commandBuffers = runtime.snapshotCommandBuffers();
  clearHostBuffers();

  assert.deepEqual([...runtime.readDynamicBytes(0, 4)], [1, 2, 3, 4]);
  assert.deepEqual([...runtime.readDynamicBytes(4, 4)], [5, 6, 7, 8]);
});

test("without a snapshot a cleared dynamic buffer is reported, not silently misread", () => {
  const dynamic = new Uint8Array([9, 9, 9, 9]);
  const { runtime, clearHostBuffers } = runtimeWithBuffers({ strings: new Uint8Array(0), dynamic });
  clearHostBuffers();

  assert.throws(() => runtime.readDynamicBytes(0, 4), /empty dynamic buffer/);
});

test("without a snapshot a cleared string buffer is reported, not decoded from address 0", () => {
  const strings = new TextEncoder().encode("hello");
  const { runtime, clearHostBuffers } = runtimeWithBuffers({ strings, dynamic: new Uint8Array(0) });
  clearHostBuffers();

  assert.throws(() => runtime.readString(0, 5), /empty string buffer/);
});

test("a snapshot slice beyond the captured payload is rejected", () => {
  const strings = new TextEncoder().encode("abc");
  const { runtime } = runtimeWithBuffers({ strings, dynamic: new Uint8Array([1, 2]) });
  runtime.commandBuffers = runtime.snapshotCommandBuffers();

  assert.throws(() => runtime.readString(2, 99), /exceeds string buffer length/);
  assert.throws(() => runtime.readDynamicBytes(1, 99), /exceeds dynamic buffer length/);
});
