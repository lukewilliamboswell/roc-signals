import { readFile } from "node:fs/promises";

// Compile without instantiating: validate generated code without running the app
// or requiring its browser imports. Compiler exit status alone is insufficient.
const paths = process.argv.slice(2);
if (paths.length === 0) {
  console.error("usage: validate_wasm.mjs <wasm-path> [...wasm-paths]");
  process.exitCode = 2;
}
for (const path of paths) {
  try {
    await WebAssembly.compile(await readFile(path));
  } catch (error) {
    console.error(`Invalid Wasm artifact ${path}: ${error.message}`);
    process.exitCode = 1;
  }
}
