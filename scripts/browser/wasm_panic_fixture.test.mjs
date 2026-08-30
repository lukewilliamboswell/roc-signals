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

async function instantiateHostFixture() {
  const bytes = await readFile(".test-out/oom/host-fixture.wasm");
  return (await WebAssembly.instantiate(bytes, { env: { roc_ui_init: () => 0 } })).instance.exports;
}

function hostDiagnostic(host) {
  return new TextDecoder().decode(new Uint8Array(
    host.memory.buffer,
    host.roc_ui_last_error_ptr(),
    host.roc_ui_last_error_len(),
  ));
}

test("Wasm roc_alloc OOM poisons and traps instead of returning null", async () => {
  for (const failureNumber of [1, 2, 3]) {
    const host = await instantiateHostFixture();
    host.roc_ui_debug_fail_allocation(failureNumber);
    assert.throws(() => host.roc_alloc(32, 8), WebAssembly.RuntimeError);
    assert.equal(host.roc_ui_is_poisoned(), 1);
    assert.equal(hostDiagnostic(host), "Roc allocation failed");
    assert.equal(host.roc_ui_debug_live_allocation_count(), 0);
    assert.equal(host.roc_ui_command_buffer_len(), 0);
    assert.equal(host.roc_ui_string_buffer_len(), 0);
    assert.equal(host.roc_ui_dynamic_buffer_len(), 0);
    assert.throws(() => host.roc_alloc(8, 8), WebAssembly.RuntimeError);
    assert.throws(() => host.roc_ui_mount(), WebAssembly.RuntimeError);
  }
});

test("Wasm roc_realloc OOM preserves the old ledger entry then poisons", async () => {
  const host = await instantiateHostFixture();
  const original = host.roc_alloc(32, 8);
  assert.notEqual(original, 0);
  assert.equal(host.roc_ui_debug_live_allocation_count(), 1);

  host.roc_ui_debug_fail_allocation(1);
  assert.throws(() => host.roc_realloc(original, 64, 8), WebAssembly.RuntimeError);
  assert.equal(host.roc_ui_is_poisoned(), 1);
  assert.equal(hostDiagnostic(host), "Roc reallocation failed");
  assert.equal(host.roc_ui_debug_live_allocation_count(), 1);
  assert.equal(host.roc_ui_debug_live_allocation_size(0), 32);
  assert.equal(host.roc_ui_command_buffer_len(), 0);
  assert.equal(host.roc_ui_string_buffer_len(), 0);
  assert.equal(host.roc_ui_dynamic_buffer_len(), 0);
  assert.throws(() => host.roc_realloc(original, 96, 8), WebAssembly.RuntimeError);
  assert.throws(() => host.roc_ui_mount(), WebAssembly.RuntimeError);
});

test("successful Wasm Roc allocation lifecycle never scans the live ledger", async () => {
  const host = await instantiateHostFixture();
  const pointers = Array.from({ length: 1024 }, () => host.roc_alloc(8, 8));

  for (let index = 0; index < pointers.length; index += 2) {
    pointers[index] = host.roc_realloc(pointers[index], 16, 8);
  }
  for (const pointer of pointers) host.roc_dealloc(pointer, 8);

  assert.equal(host.roc_ui_debug_live_allocation_count(), 0);
  assert.equal(host.roc_ui_debug_allocation_diagnostic_scan_entries(), 0n);
});

test("linked Wasm initial mount OOM publishes nothing, diagnoses poison, and retries in a fresh host", async () => {
  const baseline = await instantiateHostFixture();
  baseline.roc_ui_debug_mount_fixture();
  const attempts = baseline.roc_ui_debug_allocation_attempts();
  assert.ok(attempts > 0);
  assert.ok(baseline.roc_ui_command_buffer_len() > 0);
  assert.equal(baseline.roc_ui_is_poisoned(), 0);
  baseline.roc_ui_unmount();

  for (let failureNumber = 1; failureNumber <= attempts; failureNumber += 1) {
    const failed = await instantiateHostFixture();
    failed.roc_ui_debug_fail_allocation(failureNumber);
    assert.throws(() => failed.roc_ui_debug_mount_fixture(), WebAssembly.RuntimeError);
    assert.equal(failed.roc_ui_is_poisoned(), 1);
    assert.match(hostDiagnostic(failed), /out of memory (preparing initial root|while reserving render command storage)/);
    assert.equal(failed.roc_ui_command_buffer_len(), 0);
    assert.equal(failed.roc_ui_string_buffer_len(), 0);
    assert.equal(failed.roc_ui_dynamic_buffer_len(), 0);
    assert.throws(() => failed.roc_ui_debug_mount_fixture(), WebAssembly.RuntimeError);

    const retry = await instantiateHostFixture();
    retry.roc_ui_debug_mount_fixture();
    assert.equal(retry.roc_ui_is_poisoned(), 0);
    assert.ok(retry.roc_ui_command_buffer_len() > 0);
    retry.roc_ui_unmount();
  }
});

test("populated linked Wasm unmount is allocation-free and idempotent", async () => {
  const host = await instantiateHostFixture();
  host.roc_ui_debug_mount_fixture();
  assert.ok(host.roc_ui_command_buffer_len() > 0);

  host.roc_ui_debug_fail_allocation(1);
  host.roc_ui_unmount();
  assert.equal(host.roc_ui_debug_allocation_attempts(), 0);
  assert.equal(host.roc_ui_live_host_values(), 0);
  assert.equal(host.roc_ui_is_poisoned(), 0);

  host.roc_ui_unmount();
  assert.equal(host.roc_ui_debug_allocation_attempts(), 0);
  assert.equal(host.roc_ui_live_host_values(), 0);
  assert.equal(host.roc_ui_is_poisoned(), 0);
});

test("bounded linked Wasm memory.grow exhaustion enters fatal containment", async () => {
  const bytes = await readFile(".test-out/oom/host-fixture-bounded.wasm");
  const { instance } = await WebAssembly.instantiate(bytes, { env: { roc_ui_init: () => 0 } });
  const host = instance.exports;
  const initialBytes = host.memory.buffer.byteLength;

  assert.equal(initialBytes, 18 * 64 * 1024);
  assert.throws(() => host.roc_alloc(initialBytes, 8), WebAssembly.RuntimeError);
  assert.equal(host.memory.buffer.byteLength, initialBytes);
  assert.equal(host.roc_ui_is_poisoned(), 1);
  assert.equal(hostDiagnostic(host), "Roc allocation failed");
  assert.equal(host.roc_ui_command_buffer_len(), 0);
  assert.equal(host.roc_ui_string_buffer_len(), 0);
  assert.equal(host.roc_ui_dynamic_buffer_len(), 0);
  assert.throws(() => host.roc_alloc(8, 8), WebAssembly.RuntimeError);
  host.roc_ui_unmount();
});
