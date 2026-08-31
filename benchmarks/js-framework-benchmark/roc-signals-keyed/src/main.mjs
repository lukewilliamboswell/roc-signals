import { mountSignalsApp } from "./signals.mjs";

const root = document.getElementById("main");

if (root === null) {
  throw new Error("Roc Signals benchmark requires a #main mount element");
}

await mountSignalsApp({
  wasmUrl: new URL("./app.wasm", import.meta.url),
  root,
});
