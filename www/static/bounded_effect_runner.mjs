// A frame-free Wasm trampoline. All imports must be actual Wasm exports:
// suspension may not cross an ordinary JavaScript frame. Bounds are switched
// before the pointer, and no stack-using call occurs between those operations.
const string = value => [value.length, ...new TextEncoder().encode(value)];
const section = (id, bytes) => [id, ...uleb(bytes.length), ...bytes];
function uleb(value) {
  const bytes = [];
  do {
    const next = value & 127;
    value >>>= 7;
    bytes.push(next | (value ? 128 : 0));
  } while (value);
  return bytes;
}
const imported = (name, type) => [...string("env"), ...string(name), 0, type];
const body = [
  1, 3, 0x7f, // saved main pointer, effect top, effect bottom
  0x23, 0, 0x21, 1,
  0x20, 1, 0x10, 2, // set_main(saved)
  0x20, 0, 0x10, 0, 0x21, 2, // top(token)
  0x20, 0, 0x10, 1, 0x21, 3, // bottom(token)
  0x20, 2, 0x20, 3, 0x10, 3, // set_limits(top, bottom)
  0x20, 2, 0x24, 0,
  0x20, 0, 0x10, 4, // run(token)
  0x20, 1, 0x41, 0, 0x10, 3, // set_limits(saved, 0)
  0x20, 1, 0x24, 0,
  0x0b,
];
const bytes = new Uint8Array([
  0, 97, 115, 109, 1, 0, 0, 0,
  ...section(1, [
    3,
    0x60, 1, 0x7f, 1, 0x7f,
    0x60, 1, 0x7f, 0,
    0x60, 2, 0x7f, 0x7f, 0,
  ]),
  ...section(2, [
    6, ...string("env"), ...string("stack_pointer"), 3, 0x7f, 1,
    ...imported("stack_top", 0), ...imported("stack_bottom", 0),
    ...imported("set_main", 1), ...imported("set_limits", 2),
    ...imported("run", 1),
  ]),
  ...section(3, [1, 1]),
  ...section(7, [1, ...string("run"), 0, 5]),
  ...section(10, [1, ...uleb(body.length), ...body]),
]);

export function createBoundedEffectRunner(imports) {
  if (typeof WebAssembly.promising !== "function") {
    throw new Error("Signals action effects require WebAssembly JavaScript Promise Integration (JSPI)");
  }
  const instance = new WebAssembly.Instance(new WebAssembly.Module(bytes), { env: imports });
  return WebAssembly.promising(instance.exports.run);
}
