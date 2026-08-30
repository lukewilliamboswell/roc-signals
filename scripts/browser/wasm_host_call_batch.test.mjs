import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

// Wire ops from src/signals/render_commands.zig; the fixture only needs the
// two that bracket a mount batch.
const RESET_DOM = 1;
const SET_DOCUMENT_TITLE = 32;

async function instantiateHostFixture() {
  const bytes = await readFile(".test-out/oom/host-fixture.wasm");
  return (await WebAssembly.instantiate(bytes, { env: { roc_ui_init: () => 0 } })).instance.exports;
}

function publishedRecords(host) {
  const words = host.roc_ui_command_record_words();
  const len = host.roc_ui_command_buffer_len();
  const ptr = host.roc_ui_command_buffer_ptr();
  const raw = new Uint32Array(host.memory.buffer, ptr, len * words);
  const records = [];
  for (let index = 0; index < len; index += 1) {
    const offset = index * words;
    records.push({ op: raw[offset], a: raw[offset + 1], b: raw[offset + 2], c: raw[offset + 3] });
  }
  return records;
}

function publishedString(host, offset, len) {
  const base = host.roc_ui_string_buffer_ptr();
  return new TextDecoder().decode(new Uint8Array(host.memory.buffer, base + offset, len));
}

test("a host call publishes the root transaction and its follow-on commands as one batch", async () => {
  const host = await instantiateHostFixture();
  host.roc_ui_debug_mount_fixture();

  // The fixture renders a root, then emits a command the way a lifecycle
  // callback does after the root's engine transaction sealed. Both belong to
  // the same mount batch: JavaScript reads the buffer once per host call.
  const records = publishedRecords(host);
  assert.ok(records.length >= 2);
  assert.equal(records[0].op, RESET_DOM);
  const title = records[records.length - 1];
  assert.equal(title.op, SET_DOCUMENT_TITLE);
  assert.equal(publishedString(host, title.b, title.c), "mount fixture");

  // The next host call starts a fresh batch; the drained one is gone.
  host.roc_ui_unmount();
  assert.equal(host.roc_ui_command_buffer_len(), 0);
  assert.equal(host.roc_ui_string_buffer_len(), 0);
  assert.equal(host.roc_ui_is_poisoned(), 0);
});
