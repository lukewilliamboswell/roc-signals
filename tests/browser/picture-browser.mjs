// Independent protocol18 replacement contracts for an explicitly marked picture.
// This stage does not claim adoption or protocol19 support.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";
import { protocolFixtureSection } from "./protocol-fixture.mjs";
const options = parseArgs(process.argv.slice(2), [], ["runtime"]);
const files = runtimeFiles(options.runtime);
const word = n => [n & 255, (n >>> 8) & 255, (n >>> 16) & 255, n >>> 24];
const string = value => { const bytes = [...new TextEncoder().encode(value)]; return [...word(bytes.length), ...bytes]; };
const section = (tag, bytes) => [tag, ...word(bytes.length), ...bytes];
const declarations = [section(2, word(0)), section(5, word(0)), section(6, word(0)), section(10, [110, 1]), section(11, word(0)), [...protocolFixtureSection]].flat();
// A tiny test-owned real module gives recovery a fresh instance. The module
// exposes fixed declaration and empty mount buffers; no app/compiler is used.
const leb = n => { const out = []; do { const b = n & 127; n >>>= 7; out.push(b | (n ? 128 : 0)); } while (n); return out; };
const wasmString = value => { const bytes = [...new TextEncoder().encode(value)]; return [...leb(bytes.length), ...bytes]; };
const wasmSection = (tag, bytes) => [tag, ...leb(bytes.length), ...bytes];
const vector = entries => [...leb(entries.length), ...entries.flat()];
const moduleBytes = (() => {
  const names = ["protocol_version", "boot_keys", "cmd_ptr", "cmd_len", "payload_reserve", "init", "files_released", "fault", "work_len", "metric", "drop"];
  const bodies = [
    [0x41, 18],
    [0x41, 0, 0x24, 0, 0x41, ...leb(declarations.length), 0x24, 1],
    [0x23, 0], [0x23, 1], [0x41, ...leb(65536)],
    [0x41, ...leb(16384), 0x24, 0, 0x41, 1, 0x24, 1],
    [0x41, 0], [0x41, 0], [0x41, 0], [0x42, 0], [],
  ].map(code => { const body = [0, ...code, 0x0b]; return [...leb(body.length), ...body]; });
  return Uint8Array.from([0, 97, 115, 109, 1, 0, 0, 0,
    ...wasmSection(1, vector([[0x60, 0, 1, 0x7f], [0x60, 0, 0], [0x60, 1, 0x7f, 1, 0x7f], [0x60, 0, 1, 0x7e]])),
    ...wasmSection(3, vector([0, 1, 0, 0, 2, 1, 0, 0, 0, 3, 1].map(i => [i]))),
    ...wasmSection(5, [1, 0, 2]),
    ...wasmSection(6, vector([[0x7f, 1, 0x41, 0, 0x0b], [0x7f, 1, 0x41, 0, 0x0b]])),
    ...wasmSection(7, vector([...names.map((name, i) => [...wasmString(name), 0, ...leb(i)]), [...wasmString("memory"), 2, 0]])),
    ...wasmSection(10, vector(bodies)),
    ...wasmSection(11, [1, 0, 0x41, 0, 0x0b, ...leb(declarations.length), ...declarations]),
  ]);
})();
if (!WebAssembly.validate(moduleBytes)) throw new Error("test-owned recovery module is invalid");
const server = http.createServer((request, response) => {
  const route = new URL(request.url, "http://x").pathname;
  if (route === "/missing.wasm") { response.writeHead(404); response.end(); return; }
  if (route === "/bad.wasm") { response.writeHead(200); response.end("not wasm"); return; }
  if (route === "/instantiate.wasm") {
    // Valid module, unconditional start-function trap: compile succeeds.
    response.writeHead(200, { "content-type": "application/wasm" });
    response.end(Buffer.from([0,97,115,109,1,0,0,0,1,4,1,96,0,0,3,2,1,0,8,1,0,10,5,1,3,0,0,11])); return;
  }
  if (route === "/fresh.wasm") { response.writeHead(200, { "content-type": "application/wasm" }); response.end(moduleBytes); return; }
  const file = files[path.basename(route)];
  response.writeHead(200, { "content-type": file ? "text/javascript" : "text/html" });
  response.end(file ? fs.readFileSync(file) : "<!doctype html>");
});
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
const browser = await launch({ executablePath: options.chrome });
try {
  const page = await browser.newPage();
  await page.goto(`http://127.0.0.1:${server.address().port}/`);
  const checks = await page.evaluate(async declarations => {
    const { RocEngineRuntime, mountRocEngineApp } = await import("/runtime.mjs");
    const word = n => [n & 255, (n >>> 8) & 255, (n >>> 16) & 255, n >>> 24];
    const text = value => { const bytes = [...new TextEncoder().encode(value)]; return [...word(bytes.length), ...bytes]; };
    const checks = [], check = (name, ok) => checks.push([name, !!ok]);
    const fixture = ({ marked = true, batch = [0], version = 18, trap = false, authoredInert = null, beforeInit = () => {} } = {}) => {
      const root = document.createElement("div");
      if (marked) root.setAttribute("data-roc-picture", "");
      if (authoredInert !== null) root.setAttribute("inert", authoredInert);
      const old = document.createElement("input"), comment = document.createComment("picture"), oldText = document.createTextNode("picture text");
      root.append(old, comment, oldText); document.body.append(root);
      const memory = new WebAssembly.Memory({ initial: 2 });
      let length = 0, events = 0, initCalls = 0;
      const faults = [];
      const write = bytes => { new Uint8Array(memory.buffer).set(bytes); length = bytes.length; };
      const x = { memory, protocol_version: () => version,
        boot_keys() { write(declarations); }, cmd_ptr: () => 0, cmd_len: () => length, payload_reserve: () => 65536,
        init() { initCalls++; beforeInit(root, old); if (trap) throw new Error("init trap"); write(batch); },
        event() { events++; write([0]); }, files_released: () => 0, fault: () => 0, work_len: () => 0, metric: () => 0n, drop() {},
      };
      const runtime = new RocEngineRuntime(x, root, { manualEffects: true, onFault: fault => faults.push(fault) });
      return { root, old, comment, oldText, runtime, faults, get events() { return events; }, get initCalls() { return initCalls; }, cleanup() { runtime.unmount(); root.remove(); } };
    };
    const elem = [8, ...word(1), ...word(0), ...word(0), 0, ...text(""), ...text("input"), 0];
    const prop = [21, ...word(1), 1, ...text("mounted")];
    const listen = [11, ...word(1), ...word(7), ...text("click"), 1, ...word(0)];
    const focus = [18, 1, ...word(1)];
    let initFacts;
    const mounted = fixture({ batch: [0, ...elem, ...prop, ...listen, ...focus], beforeInit(root, old) {
      old.__rn = 1;
      old.__h = { click: { h: 7, kind: 1, policies: 0 } };
      mounted.runtime.listen("click");
      mounted.runtime.registerDocumentKey(old, "keydown", { h: 8, kind: 4, policies: 16 });
      document.dispatchEvent(new KeyboardEvent("keydown", { key: "a", bubbles: true }));
      old.dispatchEvent(new Event("compositionstart", { bubbles: true }));
      old.dispatchEvent(new MouseEvent("click", { bubbles: true }));
      initFacts = { same: root.firstChild === old, inert: root.inert, composing: old.__composing };
    } });
    check("marked constructor retains all picture nodes and holds input", mounted.root.firstChild === mounted.old && mounted.root.childNodes[1] === mounted.comment && mounted.root.childNodes[2] === mounted.oldText && mounted.root.inert);
    mounted.runtime.dispatch(1, 7, new Uint8Array(), mounted.old);
    mounted.runtime.mount();
    const fresh = mounted.root.firstChild;
    check("init observes the original inert picture without queued interaction", initFacts.same && initFacts.inert && initFacts.composing === undefined && mounted.events === 0 && mounted.runtime.queue.length === 0);
    check("ordinary first mount replaces rather than mutates the picture", !mounted.runtime.poisoned && !mounted.old.isConnected && !mounted.comment.isConnected && !mounted.oldText.isConnected && fresh !== mounted.old && fresh.value === "mounted" && mounted.root.childNodes.length === 1);
    check("picture is released before FOCUS effects", document.activeElement === fresh && !mounted.root.inert && !mounted.root.hasAttribute("data-roc-picture") && !mounted.root.hasAttribute("data-roc-failed"));
    fresh.click();
    check("post-mount input uses the normal event turn", mounted.events === 1);
    mounted.cleanup();
    const template = [1, 0, ...text(""), ...text("div"), 0, 0, 1, 2, ...text(""), 1, 1, 1, 0, 0];
    const row = fixture({ batch: [0, 7, ...word(0), ...word(template.length), ...template, 1, ...word(1), ...word(0), ...word(0), ...word(0), ...text("prepared row")] }); row.runtime.mount();
    check("first-batch pure preflight validates template shapes before construction", !row.runtime.poisoned && row.root.firstChild?.textContent === "prepared row" && row.runtime.templates[0]?.holes.length === 1); row.cleanup();
    let timingRoot, trace = [];
    customElements.define("picture-timing", class extends HTMLElement {
      constructor() { super(); trace.push(["construct", this.parentNode === null, timingRoot.childNodes.length, timingRoot.firstChild?.getAttribute?.("title") ?? null]); }
      connectedCallback() { trace.push(["connected", this.parentNode === timingRoot, timingRoot.childNodes.length, timingRoot.firstChild?.getAttribute?.("title") ?? null]); }
    });
    const first = [8, ...word(1), ...word(0), ...word(0), 0, ...text(""), ...text("span"), 0];
    const attribute = value => [9, ...word(1), 3, ...text(""), ...text("title"), 1, ...text(value)];
    const ceTemplate = [1, 0, ...text(""), ...text("picture-timing"), 0, 0, 0, 0];
    const ceCommands = [...first, ...attribute("before"), 7, ...word(0), ...word(ceTemplate.length), ...ceTemplate, 1, ...word(2), ...word(0), ...word(0), ...word(0), ...attribute("after"), 8, ...word(3), ...word(0), ...word(0), 0, ...text(""), ...text("p"), 0];
    const normalCE = fixture({ marked: false, batch: [0, ...ceCommands] }); normalCE.root.replaceChildren(); timingRoot = normalCE.root; normalCE.runtime.mount(); const normalTrace = trace; trace = []; normalCE.cleanup();
    const pictureCE = fixture({ batch: [0, ...ceCommands] }); timingRoot = pictureCE.root; pictureCE.runtime.mount();
    check("custom constructors and connected callbacks retain ordinary command timing", !pictureCE.runtime.poisoned && normalTrace.length === 3 && JSON.stringify(trace) === JSON.stringify(normalTrace) && trace[0][2] === 1 && trace[0][3] === "before" && trace[2][0] === "connected" && trace[2][2] === 2 && trace[2][3] === "before"); pictureCE.cleanup(); trace = [];
    const malformedCE = fixture({ batch: [0, ...ceCommands, 255] }); timingRoot = malformedCE.root; malformedCE.runtime.mount();
    check("malformed first batch runs no custom constructor or connected callback", trace.length === 0 && malformedCE.root.firstChild === malformedCE.old && malformedCE.runtime.poisoned?.class === "executor"); malformedCE.cleanup();
    let slices = 0;
    const file = new File(["abcdef"], "source.txt"); const slice = file.slice.bind(file); file.slice = (...args) => { slices++; return slice(...args); };
    const save = [20, ...word(1), ...word(0), ...word(1), ...word(0), ...word(2), ...word(0), ...text("saved.txt")];
    const malformedFile = fixture({ batch: [0, ...save, 255] }); malformedFile.runtime.files.set(1, file); malformedFile.runtime.mount();
    check("pure preflight does not resolve file slices or stage effects", slices === 0 && malformedFile.runtime.fxOut.length === 0 && malformedFile.root.firstChild === malformedFile.old && malformedFile.runtime.poisoned?.class === "executor"); malformedFile.cleanup();
    const portFile = [19, ...text("any"), ...text("null"), ...word(0), ...word(1), ...word(1), ...word(0), ...word(1), ...word(0), ...word(2), ...word(0)];
    const malformedPort = fixture({ batch: [0, ...portFile, 255] }); malformedPort.runtime.files.set(1, file); malformedPort.runtime.mount();
    check("pure preflight does not materialize port files", slices === 0 && malformedPort.runtime.fxOut.length === 0 && malformedPort.root.firstChild === malformedPort.old && malformedPort.runtime.poisoned?.class === "executor"); malformedPort.cleanup();
    for (const [label, command] of [
      ["port blob", [19, ...text("any"), ...text("null"), ...word(1), ...word(4), 1, 2, 3, 4, ...word(0)]],
      ["prepared work input", [13, ...word(1), 8, ...text("job"), ...word(4), 1, 2, 3, 4, ...word(0), ...word(0), 1, 1, ...text("prepared"), ...word(2), ...word(0)]],
    ]) {
      const f = fixture({ batch: [0, ...command, 255] }); let copies = 0;
      const original = Uint8Array.prototype.slice;
      Uint8Array.prototype.slice = function (...args) { if (this.buffer === f.runtime.x.memory.buffer) copies++; return original.apply(this, args); };
      try { f.runtime.mount(); } finally { Uint8Array.prototype.slice = original; }
      check(`pure preflight bounds-checks ${label} without copying payload bytes`, copies === 0 && f.root.firstChild === f.old && f.runtime.poisoned?.class === "executor"); f.cleanup();
    }
    const scalar = (low, high = 0) => [...word(low), ...word(high)];
    for (const [label, range] of [
      ["token", [...scalar(0, 0x200000), ...scalar(0), ...scalar(1)]],
      ["start", [...scalar(1), ...scalar(0, 0x200000), ...scalar(1)]],
      ["length", [...scalar(1), ...scalar(0), ...scalar(0, 0x200000)]],
      ["end", [...scalar(1), ...scalar(0xffffffff, 0x1fffff), ...scalar(1)]],
    ]) {
      const f = fixture({ batch: [0, 20, ...range, ...text("invalid.txt")] }); let lookups = 0;
      f.runtime.files.set(1, file); const get = f.runtime.files.get.bind(f.runtime.files); f.runtime.files.get = key => { lookups++; return get(key); };
      f.runtime.mount();
      check(`unsafe file ${label} is refused before lookup and picture replacement`, lookups === 0 && slices === 0 && f.root.firstChild === f.old && f.runtime.poisoned?.message.includes("safe integer")); f.cleanup();
    }
    let titleAtFocus = null;
    const onFocus = () => { titleAtFocus = document.title; };
    document.addEventListener("focusin", onFocus);
    const ordered = fixture({ batch: [0, ...elem, 17, ...text("before focus"), ...focus, 17, ...text("after focus")] }); ordered.runtime.mount();
    document.removeEventListener("focusin", onFocus);
    check("preflight preserves service and reference effect order without duplicates", titleAtFocus === "before focus" && document.title === "after focus" && ordered.runtime.fxOut.length === 0 && !ordered.runtime.poisoned); ordered.cleanup();
    const empty = fixture({ batch: [] }); empty.runtime.mount();
    check("empty mount still replaces and releases the picture", empty.root.childNodes.length === 0 && !empty.root.inert && !empty.runtime.poisoned); empty.cleanup();
    const ordinary = fixture({ marked: false }); ordinary.root.inert = true; ordinary.runtime.mount();
    check("unmarked mount preserves existing children and embedder inertness", ordinary.root.firstChild === ordinary.old && ordinary.root.inert && !ordinary.root.hasAttribute("data-roc-failed")); ordinary.cleanup();
    for (const [name, args] of [["init trap", { trap: true }], ["marked first batch", { batch: [1] }], ["protocol mismatch", { version: 0 }], ["truncated ELEM", { batch: [0, 8, 1] }], ["truncated tail after valid ELEM", { batch: [0, ...elem, 10, 2] }], ["unknown command after valid ELEM", { batch: [0, ...elem, 255] }], ["truncated REF", { batch: [0, ...elem, 18, 1] }], ["unknown LISTEN payload", { batch: [0, ...elem, 11, ...word(1), ...word(7), ...text("click"), 255, ...word(0)] }], ["invalid property code", { batch: [0, ...elem, 21, ...word(1), 255, ...text("bad")] }]]) {
      const f = fixture(args); let thrown = false; try { f.runtime.mount(); } catch (_) { thrown = true; }
      check(`${name} retains the exact fallback and reports one styled fault`, (thrown || f.runtime.poisoned) && f.root.firstChild === f.old && f.root.childNodes[1] === f.comment && f.root.childNodes[2] === f.oldText && f.root.inert && f.root.hasAttribute("data-roc-failed") && f.faults.length === 1 && f.faults[0].class === "executor");
      check(`${name} removes runtime registrations and queued work`, f.runtime.listening.size === 0 && f.runtime.internal.length === 0 && f.runtime.documentListeners.size === 0 && f.runtime.live.size === 0 && f.events === 0);
      f.cleanup();
    }
    for (const url of ["/missing.wasm", "/bad.wasm", "/instantiate.wasm"]) {
      const root = document.createElement("div"); root.setAttribute("data-roc-picture", ""); const old = document.createElement("input"); root.append(old); document.body.append(root);
      const faults = []; const promise = mountRocEngineApp({ wasmUrl: url, root, onFault: fault => faults.push(fault) });
      check(`${url} holds the same picture before fetch settles`, root.firstChild === old && root.inert);
      let rejected = false; try { await promise; } catch (_) { rejected = true; }
      check(`${url} rejection preserves the picture with one classified fault`, rejected && root.firstChild === old && root.inert && root.hasAttribute("data-roc-failed") && faults.length === 1 && faults[0].class === "executor"); root.remove();
    }
    const authored = fixture({ authoredInert: "author", batch: [0, ...elem, ...focus] });
    check("holding a direct picture preserves authored inert text", authored.root.getAttribute("inert") === "author"); authored.runtime.mount();
    check("direct marked mount restores authored inert before effects", authored.root.getAttribute("inert") === "author" && document.activeElement !== authored.root.firstChild && !authored.runtime.picturePending);
    authored.cleanup();
    const inertRoot = document.createElement("div"); inertRoot.setAttribute("data-roc-picture", ""); inertRoot.setAttribute("inert", "author loader"); inertRoot.append(document.createElement("input")); document.body.append(inertRoot);
    const inertRuntime = await mountRocEngineApp({ wasmUrl: "/fresh.wasm", root: inertRoot, manualEffects: true });
    check("loader captures authored inert before holding the picture", inertRoot.getAttribute("inert") === "author loader" && !inertRuntime.picturePending);
    inertRuntime.contain(new Error("later inert fault"), "executor"); await inertRuntime.recover();
    check("recovery preserves authored inert after successful replacement", inertRoot.getAttribute("inert") === "author loader" && !inertRuntime.poisoned);
    inertRuntime.unmount(); inertRoot.remove();
    for (const authored of [null, "author retry"]) {
      const retryRoot = document.createElement("div"); retryRoot.setAttribute("data-roc-picture", ""); if (authored !== null) retryRoot.setAttribute("inert", authored);
      const old = document.createElement("input"); retryRoot.append(old); document.body.append(retryRoot); const symbols = Object.getOwnPropertySymbols(retryRoot).length;
      const faults = []; const first = mountRocEngineApp({ wasmUrl: "/missing.wasm", root: retryRoot, onFault: fault => faults.push(fault) });
      check(`prefetch hold preserves ${authored === null ? "absent" : "authored"} inert state without changing authored text`, retryRoot.firstChild === old && retryRoot.getAttribute("inert") === (authored ?? ""));
      try { await first; } catch (_) { /* the preserved fallback is retried below */ }
      const same = retryRoot.firstChild === old && retryRoot.inert && faults.length === 1;
      const retried = await mountRocEngineApp({ wasmUrl: "/fresh.wasm", root: retryRoot, manualEffects: true });
      check(`fetch failure then same-root retry restores original ${authored === null ? "absence" : "value"}`, same && !retried.poisoned && !old.isConnected && retryRoot.getAttribute("inert") === authored && Object.getOwnPropertySymbols(retryRoot).length === symbols);
      retried.unmount(); retryRoot.remove();
    }
    const failedInert = fixture({ authoredInert: "author failed", trap: true }); failedInert.runtime.mount();
    failedInert.runtime.module = await WebAssembly.compile(await (await fetch("/fresh.wasm")).arrayBuffer()); await failedInert.runtime.recover();
    check("pre-init recovery restores authored inert from the same hold", failedInert.root.getAttribute("inert") === "author failed" && !failedInert.runtime.poisoned);
    failedInert.cleanup();
    const failed = fixture({ trap: true }); failed.runtime.mount();
    failed.runtime.module = await WebAssembly.compile(await (await fetch("/fresh.wasm")).arrayBuffer());
    await failed.runtime.recover();
    check("recovery from pre-init failure uses a fresh normal instance", !failed.runtime.poisoned && failed.root.childNodes.length === 0 && !failed.old.isConnected && !failed.root.inert && !failed.root.hasAttribute("data-roc-picture") && !failed.root.hasAttribute("data-roc-failed"));
    failed.cleanup();
    const root = document.createElement("div"); root.setAttribute("data-roc-picture", ""); root.innerHTML = "<input>"; document.body.append(root);
    const recovered = await mountRocEngineApp({ wasmUrl: "/fresh.wasm", root, manualEffects: true });
    check("real module loader completes ordinary empty replacement", !recovered.poisoned && root.childNodes.length === 0 && !root.inert);
    root.innerHTML = "<input>"; const stale = root.firstChild; recovered.contain(new Error("later fault"), "executor"); await recovered.recover();
    check("recover starts a fresh normal mount without picture metadata", !recovered.poisoned && !stale.isConnected && root.childNodes.length === 0 && !root.inert && !root.hasAttribute("data-roc-picture") && !root.hasAttribute("data-roc-failed"));
    recovered.unmount(); root.remove();
    return checks;
  }, declarations);
  for (const [name, ok] of checks) console.log(`${ok ? "ok  " : "FAIL"} ${name}`);
  if (checks.some(([, ok]) => !ok)) process.exitCode = 1;
} finally { await browser.close(); await new Promise(resolve => server.close(resolve)); }
