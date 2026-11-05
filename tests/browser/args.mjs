// Command-line options shared by the browser tests:
// `--wasm APP.wasm --runtime runtime.mjs --chrome PATH [NAME VALUE ...]`.
export function parseArgs(argv, extra = []) {
  const o = { chrome: process.env.CHROME ?? "chrome" };
  const known = ["wasm", "runtime", "chrome", ...extra];
  for (let i = 0; i < argv.length; i += 2) {
    const k = argv[i].replace(/^--/, "");
    if (!known.includes(k) || i + 1 >= argv.length) throw new Error(`usage: --${known.join(" V --")} V (got ${argv[i]})`);
    o[k] = argv[i + 1];
  }
  for (const k of ["wasm", "runtime"]) if (!o[k]) throw new Error(`--${k} is required`);
  return o;
}
