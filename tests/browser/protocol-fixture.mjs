// Independent test-owned protocol 17 declarations. Raw command contracts keep
// their own numbers; no Roc producer metadata is imported to make them agree.
const word = n => [n & 255, (n >>> 8) & 255, (n >>> 16) & 255, n >>> 24];
const text = value => { const bytes = [...new TextEncoder().encode(value)]; return [...word(bytes.length), ...bytes]; };
const list = values => [...word(values.length), ...values.flat()];
const names = values => list(values.map(text));
const codes = values => list(values.map((name, i) => [i + 1, ...text(name)]));
const section = (tag, body) => [tag, ...word(body.length), ...body];
const fields = [
  codes(["INST", "TEXT", "HATTR", "MOVE", "REMOVE", "CLEAR", "TEMPLATE", "ELEM", "ATTR", "TEXTNODE", "LISTEN", "SETTEXT", "FX", "CANCEL", "NAV", "STORAGE", "TITLE", "REF", "PORT", "SAVE", "PROP", "HPROP", "RELEASE", "TRANSITION", "GUARD"]),
  list([
    ["TEXT", []], ["FILES", ["change", "drop", "paste"]], ["POINTER", ["pointerdown", "pointermove", "pointerup", "pointercancel"]],
    ["KEY", ["keydown", "keyup"]], ["OPEN_STATE", ["close", "toggle"]], ["SCROLL", ["scroll"]], ["SIZE", ["size"]], ["SEEN", ["seen"]], ["PASTE", ["paste"]],
  ].map(([name, events], i) => [i + 1, ...text(name), ...names(events)])),
  list(["PREVENT", "STOP", "CAPTURE", "PACED", "DOCUMENT", "AHEAD"].map((name, i) => [...word(1 << i), ...text(name)])),
  list([
    ["value", ["input", "textarea", "select", "option"]], ["checked", ["input"]], ["pointer_zone", []], ["keymap_down", []], ["keymap_up", []], ["shown", ["dialog"]], ["popover_shown", []],
  ].map(([name, elements], i) => [i + 1, ...text(name), ...names(elements)])),
  codes(["default", "no-store", "reload", "no-cache", "force-cache"]), codes(["same-origin", "include"]),
  names(["disabled", "selected", "readonly", "required", "hidden", "multiple", "open"]),
  names(["button", "submit", "reset", "checkbox", "radio", "file", "hidden", "range", "color", "image"]),
  names(["none", "contract", "resource_limit", "out_of_memory", "app_crash", "expect_failed", "unavailable", "executor"]),
];
export const protocolFixtureSection = Uint8Array.from(section(12, fields.flatMap((body, i) => section(i + 1, body))));

// Validate the fixture through ordinary declaration reading and mount. Tests
// that specifically bypass boot can then reuse these validated bindings while
// retaining their original fake host, listeners and independently encoded batch.
// This helper tests runtime command behavior; malformed module tests separately
// exercise refusal before init and must not use the bypass binding shortcut.
export async function installProtocolFixture(page) {
  await page.evaluate(async sectionBytes => {
    const { RocEngineRuntime } = await import("/runtime.mjs");
    const section = Uint8Array.from(sectionBytes);
    const base = [2, 4, 0, 0, 0, 0, 0, 0, 0, 5, 4, 0, 0, 0, 0, 0, 0, 0, 6, 4, 0, 0, 0, 0, 0, 0, 0, 10, 2, 0, 0, 0, 110, 1, 11, 4, 0, 0, 0, 0, 0, 0, 0];
    const declarations = Uint8Array.from([...base, ...section]);
    const byConstructor = new WeakMap();
    const bind = Runtime => {
      if (byConstructor.has(Runtime)) return byConstructor.get(Runtime);
      const memory = new WebAssembly.Memory({ initial: 2 });
      let length = 0;
      const x = {
        memory, protocol_version: () => 17,
        boot_keys() { new Uint8Array(memory.buffer).set(declarations); length = declarations.length; },
        cmd_ptr: () => 0, cmd_len: () => length, payload_reserve: () => 65536,
        init() { new Uint8Array(memory.buffer)[0] = 0; length = 1; },
        files_released: () => 0, metric: () => 0n, work_len: () => 0, fault: () => 0, drop() {},
      };
      const root = document.createElement("div");
      const runtime = new Runtime(x, root, { manualEffects: true });
      runtime.mount();
      if (runtime.poisoned) throw new Error(`protocol fixture failed to mount: ${runtime.poisoned.message}`);
      const bindings = runtime.protocol;
      runtime.unmount();
      byConstructor.set(Runtime, bindings);
      return bindings;
    };
    bind(RocEngineRuntime);
    window.__protocolFixtureSection = section;
    // A relative/absolute URL can instantiate the same runtime source twice.
    // Bind through the fixture's own class so its private fault constructors
    // and the functions that throw them belong to that same module instance.
    window.__bindProtocolFixture = fixture => { fixture.protocol = bind(fixture.constructor); return fixture; };
  }, [...protocolFixtureSection]);
}
