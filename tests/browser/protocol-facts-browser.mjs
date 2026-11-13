// Required metadata is validated before init, and mounts keep separate bindings.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";
import { protocolFixtureSection } from "./protocol-fixture.mjs";
const options = parseArgs(process.argv.slice(2));
const files = runtimeFiles(options.runtime);
const server = http.createServer((request, response) => {
  const file = files[path.basename(new URL(request.url, "http://x").pathname)];
  response.writeHead(200, { "content-type": file ? "text/javascript" : "text/html" });
  response.end(file ? fs.readFileSync(file) : "<!doctype html>");
});
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
const browser = await launch({ executablePath: options.chrome });
try {
  const page = await browser.newPage();
  await page.goto(`http://127.0.0.1:${server.address().port}/`);
  const checks = await page.evaluate(async fixture => {
    const { RocEngineRuntime, readDeclarations } = await import("/runtime.mjs");
    const word = n => [n & 255, (n >>> 8) & 255, (n >>> 16) & 255, n >>> 24];
    const text = value => { const bytes = [...new TextEncoder().encode(value)]; return [...word(bytes.length), ...bytes]; };
    const section = (tag, body) => [tag, ...word(body.length), ...body];
    const prefix = [section(2, word(0)), section(5, word(0)), section(6, word(0)), section(10, [110, 1]), section(11, word(0))].flat();
    const body = fixture.slice(5), fields = [];
    for (let at = 0; at < body.length;) {
      const n = new DataView(Uint8Array.from(body.slice(at + 1, at + 5)).buffer).getUint32(0, true);
      fields.push(body.slice(at + 5, at + 5 + n)); at += 5 + n;
    }
    const encode = values => section(12, values.flatMap((value, i) => section(i + 1, value)));
    const make = declarations => {
      const memory = new WebAssembly.Memory({ initial: 2 }); let length = 0, initCalls = 0;
      const root = document.createElement("div"); document.body.append(root);
      const x = { memory, protocol_version: () => 17,
        boot_keys() { new Uint8Array(memory.buffer).set(declarations); length = declarations.length; },
        cmd_ptr: () => 0, cmd_len: () => length, payload_reserve: () => 65536,
        init() { initCalls++; new Uint8Array(memory.buffer)[0] = 0; length = 1; },
        files_released: () => 0, fault: () => 0, work_len: () => 0, metric: () => 0n, drop() {},
      };
      const runtime = new RocEngineRuntime(x, root, { manualEffects: true });
      return { runtime, root, get initCalls() { return initCalls; }, raw(bytes) { new Uint8Array(memory.buffer).set(bytes); length = bytes.length; runtime.apply(); }, end() { runtime.unmount(); root.remove(); } };
    };
    const checks = [], check = (name, ok) => { checks.push([name, !!ok]); };
    const reject = (name, item, detail = null) => {
      const fixture = make(Uint8Array.from([...prefix, ...item]));
      let refused = false; try { fixture.runtime.mount(); } catch (error) { refused = error.message.includes("declaration section 12 (protocol)") && (detail === null || error.message.includes(detail)); }
      check(name, refused && fixture.initCalls === 0); fixture.root.remove();
    };
    reject("missing facts refuses before init", []);
    reject("truncated facts refuses before init", fixture.slice(0, -1));
    reject("unknown field refuses before init", section(12, [10, ...body.slice(1)]));
    reject("duplicate field refuses before init", section(12, [...section(1, fields[0]), ...body]));
    reject("trailing facts refuses before init", section(12, [...body, 0]));
    const duplicate = fields.map((value, i) => i === 6 ? [...word(2), ...text("open"), ...text("open")] : value);
    reject("duplicate vocabulary name refuses before init", encode(duplicate));
    const invalidUtf8 = fields.map((value, i) => i === 6 ? [...word(1), ...word(1), 255] : value);
    reject("invalid UTF-8 refuses before init", encode(invalidUtf8));
    const unknownProperty = fields.map((value, i) => i === 3 ? [...value.slice(0, 5), ...text("unknown"), ...value.slice(14)] : value);
    reject("unsupported property implementation refuses before init", encode(unknownProperty));
    const unknownOpcode = fields.map((value, i) => i === 0 ? [...value.slice(0, -10), 25, ...text("BOGUS")] : value);
    reject("unknown opcode name refuses before init", encode(unknownOpcode), 'unknown opcode name "BOGUS"');
    const missingOpcode = fields.map((value, i) => i === 0 ? [...word(24), ...value.slice(4, -10)] : value);
    reject("missing opcode name refuses before init", encode(missingOpcode), 'missing opcode name "GUARD"');
    const unknownPolicy = fields.map((value, i) => i === 2 ? [...value.slice(0, -13), ...word(32), ...text("BOGUS")] : value);
    reject("unknown policy name refuses before init", encode(unknownPolicy), 'unknown policy name "BOGUS"');
    const missingPolicy = fields.map((value, i) => i === 2 ? [...word(5), ...value.slice(4, -13)] : value);
    reject("missing policy name refuses before init", encode(missingPolicy), 'missing policy name "AHEAD"');
    const metadataOnly = make(Uint8Array.from([...prefix, ...fixture]));
    const createElement = document.createElement;
    const objectKinds = ["Blob", "File", "Worker", "MutationObserver", "ResizeObserver", "IntersectionObserver"];
    const constructors = new Map(objectKinds.map(name => [name, globalThis[name]]));
    let browserObjects = 0, bindings;
    try {
      document.createElement = () => { browserObjects++; throw new Error("metadata binding created a DOM node"); };
      for (const name of objectKinds) globalThis[name] = class { constructor() { browserObjects++; throw new Error(`metadata binding created ${name}`); } };
      bindings = readDeclarations(metadataOnly.runtime.x).bindings;
    } finally {
      document.createElement = createElement;
      for (const [name, constructor] of constructors) globalThis[name] = constructor;
    }
    check("declaration binding creates no DOM/browser objects and never initializes the app", browserObjects === 0 && metadataOnly.initCalls === 0 && typeof bindings.COMMANDS[1] === "function");
    metadataOnly.root.remove();
    const first = make(Uint8Array.from([...prefix, ...fixture])); first.runtime.mount();
    // Exchange the ELEM and TEXTNODE names, retaining the independently owned
    // numeric row codes. Both operand layouts are node,parent,before,string.
    const opNames = ["INST", "TEXT", "HATTR", "MOVE", "REMOVE", "CLEAR", "TEMPLATE", "TEXTNODE", "ATTR", "ELEM", "LISTEN", "SETTEXT", "FX", "CANCEL", "NAV", "STORAGE", "TITLE", "REF", "PORT", "SAVE", "PROP", "HPROP", "RELEASE", "TRANSITION", "GUARD"];
    const swapped = fields.map((value, i) => i === 0 ? [...word(opNames.length), ...opNames.flatMap((name, index) => [index + 1, ...text(name)])] : value);
    const second = make(Uint8Array.from([...prefix, ...encode(swapped)])); second.runtime.mount();
    first.raw([0, 8, ...word(1), ...word(0), ...word(0), ...text("div")]);
    second.raw([0, 10, ...word(1), ...word(0), ...word(0), ...text("span")]);
    check("a second mount cannot replace the first module's opcode bindings", first.root.firstChild?.tagName === "DIV" && second.root.firstChild?.tagName === "SPAN");
    check("mounts retain distinct immutable facts and dispatch tables", first.runtime.protocol !== second.runtime.protocol && first.runtime.protocol.PROPS !== second.runtime.protocol.PROPS && Object.isFrozen(first.runtime.protocol.facts.ops));
    first.end(); second.end();
    return checks;
  }, [...protocolFixtureSection]);
  for (const [name, ok] of checks) console.log(`${ok ? "ok  " : "FAIL"} ${name}`);
  if (checks.some(([, ok]) => !ok)) process.exitCode = 1;
} finally { await browser.close(); await new Promise(resolve => server.close(resolve)); }
