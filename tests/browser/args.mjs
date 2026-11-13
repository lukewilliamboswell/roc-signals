import path from "node:path";

// The runtime's files, which a test serves by basename from beside the
// `--runtime` path: the same list as `SpecSuite.runtime_files`.
export const RUNTIME_FILES = ["runtime.mjs", "worker.mjs", "environment.mjs"];

// The file-map entries for every runtime file beside `runtime`.
export function runtimeFiles(runtime) {
  return Object.fromEntries(RUNTIME_FILES.map((f) => [f, path.join(path.dirname(runtime), f)]));
}

// Command-line options shared by the browser tests:
// `--wasm APP.wasm --runtime runtime.mjs --chrome PATH [NAME VALUE ...]`.
// Pure runtime fixtures choose their own required fields rather than supplying
// an unused Wasm path. App tests retain the default module/runtime requirement.
export function parseArgs(argv, extra = [], required = ["wasm", "runtime"]) {
  const o = { chrome: process.env.CHROME ?? "chrome" };
  const known = ["wasm", "runtime", "chrome", ...extra];
  for (let i = 0; i < argv.length; i += 2) {
    const k = argv[i].replace(/^--/, "");
    if (!known.includes(k) || i + 1 >= argv.length) throw new Error(`usage: --${known.join(" V --")} V (got ${argv[i]})`);
    o[k] = argv[i + 1];
  }
  for (const k of required) if (!o[k]) throw new Error(`--${k} is required`);
  return o;
}
