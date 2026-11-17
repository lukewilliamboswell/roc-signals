// Required metadata is validated before init, and mounts keep separate bindings.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";
import { protocolFixtureSection, protocolFixtureFacts, protocolFixtureSectionOf, encodeProtocolFixture } from "./protocol-fixture.mjs";
// Build malformed metadata independently of the production reader and Roc.
const changed = change => { const facts = structuredClone(protocolFixtureFacts); change(facts); return [...protocolFixtureSectionOf(facts)]; };
const frame = bytes => [12, bytes.length & 255, (bytes.length >>> 8) & 255, (bytes.length >>> 16) & 255, bytes.length >>> 24, ...bytes];
const cases = [
  ["missing facts refuses before init", []],
  ["truncated facts refuses before init", [...protocolFixtureSection.slice(0, -1)]],
  ["unknown field refuses before init", changed(facts => { facts.opsx = facts.ops; delete facts.ops; })],
  ["non-shortest head refuses before init", frame([0xb8, 11, ...protocolFixtureSection.slice(6)])],
  ["indefinite map refuses before init", frame([0xbf, 0xff])],
  ["trailing facts refuses before init", frame([...protocolFixtureSection.slice(5), 0])],
  ["duplicate vocabulary name refuses before init", changed(facts => facts.namespaces[1].name = "HTML")],
  ["unsupported property implementation refuses before init", changed(facts => facts.properties[0].name = "unknown")],
  ["unknown opcode name refuses before init", changed(facts => facts.ops.at(-1).name = "BOGUS"), 'unknown opcode name "BOGUS"'],
  ["a leading BOM cannot disguise an unknown opcode name", changed(facts => facts.ops[0].name = "\uFEFFINST")],
  ["missing opcode name refuses before init", changed(facts => facts.ops.pop()), 'missing opcode name "UNSENT"'],
  ["unknown policy name refuses before init", changed(facts => facts.policies.at(-1).name = "BOGUS"), 'unknown policy name "BOGUS"'],
  ["missing policy name refuses before init", changed(facts => facts.policies.pop()), 'missing policy name "AHEAD"'],
  ["unknown namespace refuses before init", changed(facts => facts.namespaces.at(-1).name = "BOGUS"), 'unknown namespace name "BOGUS"'],
  ["missing namespace refuses before init", changed(facts => facts.namespaces.pop()), 'missing namespace name "URI"'],
  ["unknown template node refuses before init", changed(facts => facts.template_nodes.at(-1).name = "BOGUS"), 'unknown template node name "BOGUS"'],
  ["missing template node refuses before init", changed(facts => facts.template_nodes.pop()), 'missing template node name "COMMENT"'],
  ["unknown child container refuses before init", changed(facts => facts.child_containers[0].name = "BOGUS"), 'unknown child container name "BOGUS"'],
  ["missing child container refuses before init", changed(facts => facts.child_containers.pop()), 'missing child container name "TEMPLATE_CONTENT"'],
  ["text-entry exclusions without checkbox refuse before init", changed(facts => { facts.text_entry_excluded = facts.text_entry_excluded.filter(name => name !== "checkbox"); }), "text-entry exclusions"],
  ["text-entry exclusions with an extra input type refuse before init", changed(facts => facts.text_entry_excluded.push("text")), "text-entry exclusions"],
  ["a payload kind's changed events refuse before init", changed(facts => { facts.kinds[3].events = ["keydown"]; }), "payload kind KEY events"],
  ["a property's changed elements refuse before init", changed(facts => { facts.properties[0].elements = ["input"]; }), "property value elements"],
];
// Duplicate the first root key while keeping eleven fields, and corrupt a text
// byte without using either consumer's metadata decoder to locate it.
const body = [...protocolFixtureSection.slice(5)];
const nestedEmptyEvents = [...body];
const emptyEventsPattern = [...encodeProtocolFixture("events"), 0x80];
const emptyEventsAt = nestedEmptyEvents.findIndex((_, i) => emptyEventsPattern.every((byte, j) => nestedEmptyEvents[i + j] === byte));
if (emptyEventsAt < 0) throw new Error("fixture needs its explicit empty events array");
nestedEmptyEvents[emptyEventsAt + emptyEventsPattern.length - 1] = 0x40;
cases.push(["nested empty byte string refuses before init", frame(nestedEmptyEvents)]);
const firstPair = encodeProtocolFixture("ops").concat(encodeProtocolFixture(protocolFixtureFacts.ops));
const nextPair = encodeProtocolFixture("kinds").concat(encodeProtocolFixture(protocolFixtureFacts.kinds));
cases.push(["duplicate field refuses before init", frame([body[0], ...firstPair, ...firstPair, ...body.slice(1 + firstPair.length + nextPair.length)])]);
const invalid = body.slice(); const inst = Buffer.from(invalid).indexOf(Buffer.from("INST"));
if (inst < 0) throw new Error("fixture lacks independent INST byte witness");
invalid[inst] = 255; cases.push(["invalid UTF-8 refuses before init", frame(invalid)]);
const swapped = changed(facts => { [facts.ops[7].name, facts.ops[9].name] = [facts.ops[9].name, facts.ops[7].name]; });
const options = parseArgs(process.argv.slice(2), [], ["runtime"]);
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
  const checks = await page.evaluate(async ({ fixture, cases, swapped }) => {
    const { RocEngineRuntime, readDeclarations } = await import("/runtime.mjs");
    const word = n => [n & 255, (n >>> 8) & 255, (n >>> 16) & 255, n >>> 24];
    const text = value => { const bytes = [...new TextEncoder().encode(value)]; return [...word(bytes.length), ...bytes]; };
    const section = (tag, body) => [tag, ...word(body.length), ...body];
    const prefix = [section(2, word(0)), section(5, word(0)), section(6, word(0)), section(10, [110, 1]), section(11, word(0))].flat();
    const make = (declarations, version = 21) => {
      const memory = new WebAssembly.Memory({ initial: 2 }); let length = 0, initCalls = 0;
      const root = document.createElement("div"); document.body.append(root);
      const x = { memory, dbg_len: () => 0, dbg_ptr: () => 0, protocol_version: () => version,
        boot_keys() { new Uint8Array(memory.buffer).set(declarations); length = declarations.length; },
        cmd_ptr: () => 0, cmd_len: () => length, payload_reserve: () => 65536,
        init() { initCalls++; new Uint8Array(memory.buffer)[0] = 0; length = 1; return 0; },
        keys_released: () => 0, files_released: () => 0, fault: () => 0, work_len: () => 0, metric: () => 0n, drop() {},
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
    for (const [name, item, detail] of cases) reject(name, item, detail ?? null);
    const oldModule = make(Uint8Array.from([...prefix, ...fixture]), 20);
    let oldRefused = false;
    try { oldModule.runtime.mount(); } catch (error) { oldRefused = error.message.includes("protocol 20 is not the protocol 21"); }
    check("the previous transport version refuses before init", oldRefused && oldModule.initCalls === 0);
    oldModule.root.remove();
    const workerMismatch = await new Promise((resolve, reject) => {
      const worker = new Worker("/worker.mjs", { type: "module" });
      const timer = setTimeout(() => { worker.terminate(); reject(new Error("worker version guard timed out")); }, 5000);
      worker.onmessage = event => { clearTimeout(timer); worker.terminate(); resolve(event.data); };
      worker.onerror = event => { clearTimeout(timer); worker.terminate(); reject(new Error(event.message)); };
      worker.postMessage({ type: "init", module: null, version: 20 });
      // Init intentionally has no failure reply until a job awaits its promise.
      worker.postMessage({ type: "job", mode: "work", payload: new ArrayBuffer(0) });
    });
    check("the worker rejects the previous version before instantiation", workerMismatch.type === "fault" && workerMismatch.code === 0 && workerMismatch.message === "worker could not start: page runtime protocol 20 is not the protocol 21 this worker implements");
    const metadataOnly = make(Uint8Array.from([...prefix, ...fixture]));
    const factories = new Map(["createElement", "createElementNS", "createTextNode", "createComment", "createDocumentFragment"].map(name => [name, document[name]]));
    const objectKinds = ["Blob", "File", "Worker", "MutationObserver", "ResizeObserver", "IntersectionObserver"];
    const constructors = new Map(objectKinds.map(name => [name, globalThis[name]]));
    let browserObjects = 0, bindings;
    try {
      for (const name of factories.keys()) document[name] = () => { browserObjects++; throw new Error(`metadata binding called ${name}`); };
      for (const name of objectKinds) globalThis[name] = class { constructor() { browserObjects++; throw new Error(`metadata binding created ${name}`); } };
      bindings = readDeclarations(metadataOnly.runtime.x).bindings;
    } finally {
      for (const [name, factory] of factories) document[name] = factory;
      for (const [name, constructor] of constructors) globalThis[name] = constructor;
    }
    check("declaration binding creates no DOM/browser objects and never initializes the app", browserObjects === 0 && metadataOnly.initCalls === 0 && typeof bindings.COMMANDS[1] === "function");
    metadataOnly.root.remove();
    const first = make(Uint8Array.from([...prefix, ...fixture])); first.runtime.mount();
    // Exchange the ELEM and TEXTNODE names, retaining the independently owned
    // numeric row codes. Their own semantic handlers still decode the correct
    // distinct layouts, with explicit expanded names on ELEM.
    const second = make(Uint8Array.from([...prefix, ...swapped])); second.runtime.mount();
    first.raw([0, 8, ...word(1), ...word(0), ...word(0), 0, ...text(""), ...text("div"), 0]);
    second.raw([0, 10, ...word(1), ...word(0), ...word(0), 0, ...text(""), ...text("span"), 0]);
    check("a second mount cannot replace the first module's opcode bindings", first.root.firstChild?.tagName === "DIV" && second.root.firstChild?.tagName === "SPAN");
    check("mounts retain distinct immutable facts and dispatch tables", first.runtime.protocol !== second.runtime.protocol && first.runtime.protocol.PROPS !== second.runtime.protocol.PROPS && Object.isFrozen(first.runtime.protocol.facts.ops));
    for (const [id, length] of [[2, 2], [3, 48]]) {
      const name = "\uFEFF" + "a".repeat(length);
      const value = "\uFEFF" + "v".repeat(length);
      const data = "\uFEFF" + "t".repeat(length);
      first.raw([0, 8, ...word(id), ...word(0), ...word(0), 0, ...text(""), ...text(name), 0,
        9, ...word(id), 3, ...text(""), ...text(name), 1, ...text(value),
        10, ...word(id + 10), ...word(id), ...word(0), ...text(data)]);
      const element = first.root.lastElementChild;
      check(`leading U+FEFF survives ${length <= 32 ? "short" : "long"} command names and values`,
        element.localName === name && element.getAttribute(name) === value && element.textContent === data);
    }
    first.end(); second.end();
    return checks;
  }, { fixture: [...protocolFixtureSection], cases, swapped });
  for (const [name, ok] of checks) console.log(`${ok ? "ok  " : "FAIL"} ${name}`);
  if (checks.some(([, ok]) => !ok)) process.exitCode = 1;
} finally { await browser.close(); await new Promise(resolve => server.close(resolve)); }
