import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("linked Wasm panic poisons the host and clears publication allocation-free", async () => {
  const bytes = await readFile(".test-out/oom/host-fixture.wasm");
  const { instance } = await WebAssembly.instantiate(bytes, { env: { roc_ui_init: () => 0 } });
  const host = instance.exports;

  assert.throws(() => host.roc_ui_debug_panic(), WebAssembly.RuntimeError);
  assert.equal(host.roc_ui_is_poisoned(), 1);
  assert.equal(host.roc_ui_command_buffer_len(), 0);
  assert.equal(host.roc_ui_string_buffer_len(), 0);
  assert.equal(host.roc_ui_dynamic_buffer_len(), 0);

  const ptr = host.roc_ui_last_error_ptr();
  const len = host.roc_ui_last_error_len();
  const diagnostic = new TextDecoder().decode(new Uint8Array(host.memory.buffer, ptr, len));
  assert.match(diagnostic, /panicked after entering a transaction/);
  assert.throws(() => host.roc_ui_mount(), WebAssembly.RuntimeError);

  // Poison containment remains callable and does not attempt allocation.
  host.roc_ui_unmount();
  assert.equal(host.roc_ui_debug_allocation_attempts(), 0);
});
