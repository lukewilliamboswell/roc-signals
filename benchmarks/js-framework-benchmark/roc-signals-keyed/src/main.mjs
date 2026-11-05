import { mountRocEngineApp } from "./runtime.mjs";

const root = document.getElementById("main");

if (root === null) {
  throw new Error("Roc engine benchmark requires a #main mount element");
}

await mountRocEngineApp({
  wasmUrl: new URL("./app.wasm", import.meta.url),
  root,
});
