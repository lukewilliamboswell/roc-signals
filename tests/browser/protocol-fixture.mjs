// Independent test-owned protocol19 declarations. Raw command contracts keep
// their own numbers; neither production facts nor the Roc encoder is imported.
const word = n => [n & 255, (n >>> 8) & 255, (n >>> 16) & 255, n >>> 24];
const utf8 = new TextEncoder();
export const cborFixtureHead = (major, size) => {
  if (!Number.isInteger(size) || size < 0 || size > 0xffffffff) throw new Error("fixture integer bound");
  if (size < 24) return [major * 32 + size];
  if (size <= 255) return [major * 32 + 24, size];
  if (size <= 65535) return [major * 32 + 25, size >>> 8, size & 255];
  return [major * 32 + 26, size >>> 24, (size >>> 16) & 255, (size >>> 8) & 255, size & 255];
};
const compareBytes = (left, right) => {
  for (let i = 0; i < Math.min(left.length, right.length); i++) if (left[i] !== right[i]) return left[i] - right[i];
  return left.length - right.length;
};
export const encodeProtocolFixture = value => {
  if (typeof value === "number") return cborFixtureHead(0, value);
  if (typeof value === "string") { const bytes = [...utf8.encode(value)]; return [...cborFixtureHead(3, bytes.length), ...bytes]; }
  if (Array.isArray(value)) return [...cborFixtureHead(4, value.length), ...value.flatMap(encodeProtocolFixture)];
  const pairs = Object.entries(value).map(([key, item]) => ({ key: encodeProtocolFixture(key), value: item })).sort((left, right) => compareBytes(left.key, right.key));
  return [...cborFixtureHead(5, pairs.length), ...pairs.flatMap(pair => [...pair.key, ...encodeProtocolFixture(pair.value)])];
};
export const protocolFixtureSectionOf = facts => {
  const body = encodeProtocolFixture(facts);
  return Uint8Array.from([12, ...word(body.length), ...body]);
};
const codes = (values, first = 1) => values.map((name, i) => ({ code: i + first, name }));
export const protocolFixtureFacts = {
  ops: codes(["INST", "TEXT", "HATTR", "MOVE", "REMOVE", "CLEAR", "TEMPLATE", "ELEM", "ATTR", "TEXTNODE", "LISTEN", "SETTEXT", "FX", "CANCEL", "NAV", "STORAGE", "TITLE", "REF", "PORT", "SAVE", "PROP", "HPROP", "RELEASE", "TRANSITION", "GUARD", "COMMENT", "UNSENT"]),
  kinds: [
    ["TEXT", []], ["FILES", ["change", "drop", "paste"]], ["POINTER", ["pointerdown", "pointermove", "pointerup", "pointercancel"]],
    ["KEY", ["keydown", "keyup"]], ["OPEN_STATE", ["close", "toggle", "change"]], ["SCROLL", ["scroll"]], ["SIZE", ["size"]], ["SEEN", ["seen"]], ["PASTE", ["paste"]],
  ].map(([name, events], i) => ({ code: i + 1, name, events })),
  policies: ["PREVENT", "STOP", "CAPTURE", "PACED", "DOCUMENT", "AHEAD"].map((name, i) => ({ bit: 1 << i, name })),
  properties: [
    ["value", ["input", "textarea", "select", "option"]], ["checked", ["input"]], ["pointer_zone", []], ["keymap_down", []], ["keymap_up", []], ["shown", ["dialog"]], ["popover_shown", []],
  ].map(([name, elements], i) => ({ index: i + 1, name, elements })),
  http_cache: codes(["default", "no-store", "reload", "no-cache", "force-cache"]), http_credentials: codes(["same-origin", "include"]),
  namespaces: codes(["HTML", "SVG", "MATHML", "NONE", "URI"], 0),
  text_entry_excluded: ["button", "submit", "reset", "checkbox", "radio", "file", "hidden", "range", "color", "image"],
  fault_classes: ["none", "contract", "resource_limit", "out_of_memory", "app_crash", "expect_failed", "unavailable", "executor"],
  template_nodes: codes(["ELEMENT", "TEXT", "COMMENT"]), child_containers: codes(["CHILDREN", "TEMPLATE_CONTENT"], 0),
};
export const protocolFixtureSection = protocolFixtureSectionOf(protocolFixtureFacts);

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
        memory, dbg_len: () => 0, dbg_ptr: () => 0, protocol_version: () => 20,
        boot_keys() { new Uint8Array(memory.buffer).set(declarations); length = declarations.length; },
        cmd_ptr: () => 0, cmd_len: () => length, payload_reserve: () => 65536,
        init() { new Uint8Array(memory.buffer)[0] = 0; length = 1; return 0; },
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
