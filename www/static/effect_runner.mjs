// This wrapper has no compiler-generated linear-memory stack frame. Entering
// the application before switching stacks would leave such a frame shared
// with ordinary events while the effect is suspended.
//
// (func (export "run") (param $token i32) (local $main i32)
//   (local.set $main (global.get $stack_pointer))
//   (global.set $stack_pointer (call $stack_top (local.get $token)))
//   (call $set_main (local.get $main))
//   (call $run (local.get $token))
//   (global.set $stack_pointer (local.get $main)))
const string = value => [value.length, ...new TextEncoder().encode(value)];
const section = (id, bytes) => [id, bytes.length, ...bytes];
const imported = (name, type) => [...string("env"), ...string(name), 0, type];
const body = [
  1, 1, 0x7f, // one i32 local
  0x23, 0, 0x21, 1, // main = stack_pointer
  0x20, 0, 0x10, 0, 0x24, 0, // stack_pointer = stack_top(token)
  0x20, 1, 0x10, 1, // set_main(main)
  0x20, 0, 0x10, 2, // run(token)
  0x20, 1, 0x24, 0, // stack_pointer = main
  0x0b,
];
const bytes = new Uint8Array([
  0, 97, 115, 109, 1, 0, 0, 0,
  ...section(1, [3, 0x60, 0, 1, 0x7f, 0x60, 1, 0x7f, 0, 0x60, 1, 0x7f, 1, 0x7f]),
  ...section(2, [4, ...string("env"), ...string("stack_pointer"), 3, 0x7f, 1, ...imported("stack_top", 2), ...imported("set_main", 1), ...imported("run", 1)]),
  ...section(3, [1, 1]),
  ...section(7, [1, ...string("run"), 0, 3]),
  ...section(10, [1, body.length, ...body]),
]);

// All imports must be actual Wasm exports so suspension never crosses a JS
// frame. The application restores its saved effect stack immediately after
// each suspending service import resumes.
export function createEffectRunner(imports) {
  if (typeof WebAssembly.promising !== "function") {
    throw new Error("Signals action effects require WebAssembly JavaScript Promise Integration (JSPI)");
  }
  const instance = new WebAssembly.Instance(new WebAssembly.Module(bytes), { env: imports });
  return WebAssembly.promising(instance.exports.run);
}
