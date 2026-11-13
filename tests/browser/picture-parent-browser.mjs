// Explicit non-HTML picture inert owners. The real mount root never changes;
// independent wire fixtures exercise loading, containment and ordinary focus.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";
import { pictureHostModule, pictureDeclarations } from "./picture-host-fixture.mjs";
const options = parseArgs(process.argv.slice(2), [], ["runtime"]), files = runtimeFiles(options.runtime), moduleBytes = pictureHostModule();
const waiting = new Map();
const server = http.createServer((request, response) => {
  const url = new URL(request.url, "http://x"), route = url.pathname;
  if (route === "/missing.wasm") { response.writeHead(404); response.end(); return; }
  if (route === "/delay.wasm") { waiting.set(url.searchParams.get("id"), response); return; }
  if (route === "/release") { const pending = waiting.get(url.searchParams.get("id")); if (!pending) { response.writeHead(409); response.end(); return; } waiting.delete(url.searchParams.get("id")); pending.writeHead(200); pending.end(moduleBytes); response.end("released"); return; }
  if (route === "/pending") { response.end(waiting.has(url.searchParams.get("id")) ? "yes" : "no"); return; }
  if (route === "/fresh.wasm") { response.writeHead(200); response.end(moduleBytes); return; }
  const file = files[path.basename(route)]; response.writeHead(200, { "content-type": file ? "text/javascript" : "text/html" }); response.end(file ? fs.readFileSync(file) : "<!doctype html>");
});
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
const browser = await launch({ executablePath: options.chrome });
try {
  console.log(JSON.stringify(await browser.conn.send("Browser.getVersion")));
  const page = await browser.newPage(); await page.goto(`http://127.0.0.1:${server.address().port}/`);
  const checks = await page.evaluate(async declarations => {
    const { RocEngineRuntime, mountRocEngineApp } = await import("/runtime.mjs");
    const html = "http://www.w3.org/1999/xhtml", svg = "http://www.w3.org/2000/svg", math = "http://www.w3.org/1998/Math/MathML";
    const word = n => [n & 255, n >>> 8 & 255, n >>> 16 & 255, n >>> 24], text = value => { const b = [...new TextEncoder().encode(value)]; return [...word(b.length), ...b]; };
    const checks = [], check = (label, ok) => checks.push([label, !!ok]);
    const make = (kind, { marker = "", authored = null, produced = false, descriptor = false, init = () => {}, drop = () => {} } = {}) => {
      const wrapper = document.createElement("section"), parent = document.createElement("div"); parent.setAttributeNS(null, "data-roc-picture-inert-parent", "");
      const namespace = { html, svg, math, custom: "urn:entry", none: null }[kind], root = document.createElementNS(namespace, { html: "div", svg: "svg", math: "math", custom: "entry", none: "entry" }[kind]);
      if (marker !== null) root.setAttributeNS(null, "data-roc-picture", marker);
      let target = root;
      if (kind === "svg") { root.setAttribute("width", "300"); root.setAttribute("height", "80"); target = document.createElementNS(svg, "foreignObject"); target.setAttribute("width", "300"); target.setAttribute("height", "80"); root.append(target); }
      if (kind === "math") { target = document.createElementNS(math, "mtext"); root.append(target); }
      const old = document.createElement("input"); old.style.setProperty("interactivity", "auto", "important"); target.append(old); parent.append(root); wrapper.append(parent); document.body.append(wrapper);
      let script = null; if (descriptor) { script = document.createElement("script"); script.type = "application/json"; script.setAttributeNS(null, "data-roc-picture-envelope", "1"); script.textContent = "[]"; parent.append(script); }
      const owner = kind === "html" ? root : parent;
      owner.style.setProperty("interactivity", "auto", "important");
      if (authored !== null) owner.setAttributeNS(null, "inert", authored);
      if (produced) { owner.setAttributeNS(null, "inert", ""); owner.setAttributeNS(null, "data-roc-picture-inert", "added"); }
      const memory = new WebAssembly.Memory({ initial: 2 }); let length = 0, calls = 0, faults = [];
      const write = bytes => { new Uint8Array(memory.buffer).set(bytes); length = bytes.length; };
      const x = { memory, protocol_version: () => 18, boot_keys() { write(declarations); }, cmd_ptr: () => 0, cmd_len: () => length, payload_reserve: () => 65536,
        init() { calls++; init(); const ns = kind === "svg" ? 1 : kind === "math" ? 2 : 0, tag = kind === "svg" ? "foreignObject" : kind === "math" ? "mtext" : "div";
          const attribute = (id, key, value) => [9, ...word(id), 3, ...text(""), ...text(key), 1, ...text(value)];
          write([0, 8, ...word(1), ...word(0), ...word(0), ns, ...text(""), ...text(tag), 0,
            ...(kind === "svg" ? [...attribute(1, "width", "300"), ...attribute(1, "height", "80")] : []),
            8, ...word(2), ...word(1), ...word(0), 0, ...text(""), ...text("input"), 0, ...attribute(2, "style", "interactivity:auto!important"), 18, 1, ...word(2)]); },
        files_released: () => 0, fault: () => 0, work_len: () => 0, metric: () => 0n, drop,
      };
      return { kind, wrapper, parent, root, old, script, owner, x, faults, get calls() { return calls; }, runtime() { return new RocEngineRuntime(x, root, { manualEffects: true, onFault: fault => faults.push(fault) }); }, cleanup(rt) { if (rt) rt.unmount(); wrapper.remove(); } };
    };
    for (const kind of ["html", "svg", "math", "custom", "none"]) {
      const f = make(kind, { produced: true }); const rt = f.runtime();
      f.old.focus(); check(`${kind} picture uses its exact native HTML inert owner`, f.owner.namespaceURI === html && f.owner.hasAttributeNS(null, "inert") && document.activeElement !== f.old && (kind === "html" || !f.root.hasAttributeNS(null, "inert")));
      rt.mount(); const live = rt.lookup(2);
      check(`${kind} first batch preserves mount root and restores owner before FOCUS`, !rt.poisoned && rt.root === f.root && live === document.activeElement && !f.owner.hasAttributeNS(null, "inert") && !f.owner.hasAttributeNS(null, "data-roc-picture-inert") && (kind === "html" || f.parent.getAttributeNS(null, "data-roc-picture-inert-parent") === "")); f.cleanup(rt);
    }
    for (const kind of ["html", "svg"]) {
      const f = make(kind, { authored: "author inert text" }), rt = f.runtime(); rt.mount();
      check(`${kind} authored owner inert value remains through successful mount`, f.owner.getAttributeNS(null, "inert") === "author inert text" && document.activeElement !== rt.lookup(2)); f.cleanup(rt);
    }
    const htmlRoot = make("html"); htmlRoot.parent.removeAttributeNS(null, "data-roc-picture-inert-parent"); htmlRoot.parent.append(document.createElement("button")); const htmlRt = htmlRoot.runtime(); htmlRt.mount();
    check("HTML root ignores parent marker and unrelated parent siblings", !htmlRt.poisoned && !htmlRoot.parent.hasAttributeNS(null, "inert") && htmlRoot.parent.children.length === 2); htmlRoot.cleanup(htmlRt);
    const withDescriptor = make("svg", { marker: "19:1", descriptor: true }), descriptorRt = withDescriptor.runtime(); withDescriptor.parent.insertBefore(document.createComment("author comment"), withDescriptor.root); withDescriptor.parent.append(document.createTextNode("authored text")); descriptorRt.mount();
    check("owner allows exact descriptor plus text/comments without retargeting root", !descriptorRt.poisoned && withDescriptor.script.parentNode === withDescriptor.parent && descriptorRt.root === withDescriptor.root); withDescriptor.cleanup(descriptorRt);
    const bounded = make("svg"); Object.defineProperty(bounded.parent, "children", { get() { throw new Error("must not enumerate the parent collection"); } }); const boundedRt = bounded.runtime(); boundedRt.mount();
    check("owner association uses only fixed sibling edges without collection enumeration", !boundedRt.poisoned); bounded.cleanup(boundedRt);
    const malformedMarker = make("svg", { marker: "wrong", descriptor: true }), malformedRt = malformedMarker.runtime(); malformedRt.mount();
    check("owner association does not reinterpret descriptor version semantics", !malformedRt.poisoned); malformedMarker.cleanup(malformedRt);
    for (const [label, mutate] of [
      ["missing parent marker", f => f.parent.removeAttributeNS(null, "data-roc-picture-inert-parent")],
      ["nonempty parent marker", f => f.parent.setAttributeNS(null, "data-roc-picture-inert-parent", "19:1")],
      ["namespaced parent marker", f => { f.parent.removeAttributeNS(null, "data-roc-picture-inert-parent"); f.parent.setAttributeNS("urn:author", "data-roc-picture-inert-parent", ""); }],
      ["unrelated sibling", f => f.parent.append(document.createElement("button"))],
      ["root is not first", f => f.parent.insertBefore(document.createElement("span"), f.root)],
      ["two roots", f => f.parent.append(document.createElementNS(svg, "svg"))],
      ["descriptor with wrong type", f => { const s = document.createElement("script"); s.type = "text/plain"; s.setAttribute("data-roc-picture-envelope", "1"); f.parent.append(s); }],
      ["template content is not ordinary parent", f => { const template = document.createElement("template"); template.setAttribute("data-roc-picture-inert-parent", ""); f.wrapper.append(template); template.content.append(f.root); }],
      ["foreign immediate parent", f => { const p = document.createElementNS(svg, "g"); p.setAttribute("data-roc-picture-inert-parent", ""); f.wrapper.append(p); p.append(f.root); }],
    ]) {
      const f = make("svg"); mutate(f); let fetches = 0, faults = 0, rejected = false; const fetch = globalThis.fetch; globalThis.fetch = (...args) => { fetches++; return fetch(...args); };
      try { await mountRocEngineApp({ wasmUrl: "/fresh.wasm", root: f.root, onFault: () => { faults++; } }); } catch (_) { rejected = true; } finally { globalThis.fetch = fetch; }
      check(`${label} fails before fetch with one contained root fault`, rejected && fetches === 0 && faults === 1 && f.root.hasAttributeNS(null, "data-roc-failed") && f.root.contains(f.old) && !f.parent.hasAttributeNS(null, "inert")); f.cleanup();
    }
    let moved; const moving = make("svg", { init() { moved.append(moving.root); } }); moved = document.createElement("div"); moved.setAttribute("data-roc-picture-inert-parent", ""); moved.setAttribute("inert", "new owner authored"); moving.wrapper.append(moved); const movingRt = moving.runtime(); movingRt.mount();
    check("init-time root move is refused without selecting a new owner", movingRt.poisoned?.class === "executor" && moving.faults.length === 1 && moving.parent.hasAttribute("inert") && moved.getAttribute("inert") === "new owner authored" && moving.root.contains(moving.old));
    movingRt.unmount(); check("moved-root unmount restores only the originally recorded owner", !moving.parent.hasAttribute("inert") && moved.getAttribute("inert") === "new owner authored" && moving.root.childNodes.length === 0 && !moving.root.hasAttribute("data-roc-picture")); moving.cleanup();
    const failed = make("svg", { produced: true, init() { throw new Error("init trap"); } }), failedRt = failed.runtime(); failedRt.mount();
    check("pre-init failure preserves parent hold, producer fact and original picture", failed.parent.hasAttribute("inert") && failed.parent.getAttribute("data-roc-picture-inert") === "added" && failed.root.contains(failed.old) && failed.faults.length === 1);
    failedRt.module = await WebAssembly.compile(await (await fetch("/fresh.wasm")).arrayBuffer()); await failedRt.recover();
    check("recovery makes a fresh normal mount and restores parent ownership", !failedRt.poisoned && !failed.parent.hasAttribute("inert") && !failed.parent.hasAttribute("data-roc-picture-inert") && failed.parent.hasAttribute("data-roc-picture-inert-parent") && failed.root.childNodes.length === 0); failed.cleanup(failedRt);
    let recoveredParent; const movedRecovery = make("svg", { produced: true, init() { recoveredParent.append(movedRecovery.root); } }); recoveredParent = document.createElement("div"); recoveredParent.setAttribute("data-roc-picture-inert-parent", ""); recoveredParent.setAttribute("inert", "new parent authored"); movedRecovery.wrapper.append(recoveredParent); const movedRecoveryRt = movedRecovery.runtime(); movedRecoveryRt.mount(); movedRecoveryRt.module = await WebAssembly.compile(await (await fetch("/fresh.wasm")).arrayBuffer()); await movedRecoveryRt.recover();
    check("moved-root recovery restores only its original owner", !movedRecoveryRt.poisoned && !movedRecovery.parent.hasAttributeNS(null, "inert") && recoveredParent.getAttributeNS(null, "inert") === "new parent authored" && !movedRecovery.root.hasAttributeNS(null, "data-roc-picture")); movedRecovery.cleanup(movedRecoveryRt);
    const dropping = make("svg", { produced: true, init() { throw new Error("init trap"); }, drop() { throw new Error("drop trap"); } }), droppingRt = dropping.runtime(); droppingRt.mount(); let dropError = false; try { droppingRt.unmount(); } catch (_) { dropError = true; }
    check("even a throwing drop performs explicit owner teardown", dropError && !dropping.parent.hasAttribute("inert") && !dropping.parent.hasAttribute("data-roc-picture-inert") && dropping.parent.hasAttribute("data-roc-picture-inert-parent") && dropping.root.childNodes.length === 0 && !dropping.root.hasAttribute("data-roc-failed")); dropping.cleanup();
    for (const authored of [null, "authored retry inert"]) {
      const f = make("svg", { authored }); let faults = 0; try { await mountRocEngineApp({ wasmUrl: "/missing.wasm", root: f.root, onFault: () => { faults++; } }); } catch (_) { /* retry below */ }
      const same = f.root.contains(f.old) && f.parent.hasAttribute("inert") && faults === 1;
      const rt = await mountRocEngineApp({ wasmUrl: "/fresh.wasm", root: f.root, manualEffects: true });
      check(`same-root parent retry restores original ${authored === null ? "absence" : "authored value"}`, same && f.parent.getAttributeNS(null, "inert") === authored && f.parent.hasAttribute("data-roc-picture-inert-parent") && !f.root.hasAttribute("data-roc-failed")); f.cleanup(rt);
    }
    const qualified = make("svg", { produced: true }); qualified.parent.setAttributeNS("urn:author", "inert", "qualified inert"); qualified.parent.setAttributeNS("urn:author", "data-roc-picture-inert", "qualified fact"); qualified.root.setAttributeNS(null, "data-roc-picture-inert", "root authored non-owner fact"); const qualifiedRt = qualified.runtime(); qualifiedRt.mount();
    check("cleanup uses exact NoNS owner facts and preserves non-owner/qualified attributes", !qualified.parent.hasAttributeNS(null, "inert") && qualified.parent.getAttributeNS("urn:author", "inert") === "qualified inert" && qualified.parent.getAttributeNS("urn:author", "data-roc-picture-inert") === "qualified fact" && qualified.root.getAttributeNS(null, "data-roc-picture-inert") === "root authored non-owner fact" && document.activeElement === qualifiedRt.lookup(2)); qualified.cleanup(qualifiedRt);
    const live = make("svg", { marker: null }); live.parent.removeAttributeNS(null, "data-roc-picture-inert-parent"); const liveRt = live.runtime(); liveRt.mount(); check("unmarked non-HTML live roots retain their existing API", !liveRt.poisoned && !live.parent.hasAttribute("inert")); live.cleanup(liveRt);
    const namespaced = make("svg", { marker: null }); namespaced.root.setAttributeNS("urn:author", "data-roc-picture", ""); namespaced.parent.removeAttributeNS(null, "data-roc-picture-inert-parent"); const namespacedRt = namespaced.runtime(); namespacedRt.mount();
    check("namespaced author marker is not a picture bootstrap opt-in", !namespacedRt.poisoned && !namespaced.parent.hasAttributeNS(null, "inert") && namespaced.root.getAttributeNS("urn:author", "data-roc-picture") === ""); namespaced.cleanup(namespacedRt);
    const callback = make("svg"); callback.parent.removeAttribute("data-roc-picture-inert-parent"); let callbackCalls = 0; try { await mountRocEngineApp({ wasmUrl: "/fresh.wasm", root: callback.root, onFault() { callbackCalls++; throw new Error("observer failed"); } }); } catch (_) { /* observer failure never retries ownership resolution */ }
    check("a throwing fault observer is called once after invalid-parent containment", callbackCalls === 1 && callback.root.hasAttributeNS(null, "data-roc-failed") && !callback.parent.hasAttributeNS(null, "inert")); callback.cleanup();
    window.__pictureParentMake = make; window.__pictureParentLoader = mountRocEngineApp;
    return checks;
  }, pictureDeclarations);
  // Native browser interaction, including CSS important declarations on both
  // the HTML owner and its input. No synthetic event stands in for hit-testing.
  for (const kind of ["html", "svg", "math", "custom", "none"]) {
    await page.evaluate(kind => {
      const f = window.__pictureParentMake(kind), before = document.createElement("button"), after = document.createElement("button");
      before.textContent = "before"; after.textContent = "after"; f.wrapper.prepend(before); f.wrapper.append(after);
      const state = { f, before, after, current: f.old, clicks: 0, rt: null };
      state.current.addEventListener("click", event => { if (event.isTrusted) state.clicks++; }); window.__pictureParentUI = state;
    }, kind);
    const phases = {};
    for (const phase of ["before", "held", "mounted"]) {
      if (phase === "held") await page.evaluate(() => { const s = window.__pictureParentUI; s.rt = s.f.runtime(); });
      if (phase === "mounted") await page.evaluate(() => { const s = window.__pictureParentUI; s.rt.mount(); s.current = s.rt.lookup(2); s.current.addEventListener("click", event => { if (event.isTrusted) s.clicks++; }); });
      const initial = await page.evaluate(() => {
        const s = window.__pictureParentUI; s.before.focus(); const outside = document.activeElement === s.before; s.current.focus(); const focus = document.activeElement === s.current; s.current.blur();
        const r = s.current.getBoundingClientRect(); return { outside, focus, clicks: s.clicks, x: r.x + 5, y: r.y + 5, visibleBox: r.width > 10 && r.height > 10 };
      });
      await page.clickAt({ x: initial.x, y: initial.y });
      const pointer = await page.evaluate(() => { const s = window.__pictureParentUI; return s.clicks; });
      await page.evaluate(() => window.__pictureParentUI.before.focus());
      const sequence = [];
      for (let step = 0; step < 3; step++) {
        await page.keyboard.press("Tab");
        const target = await page.evaluate(() => { const s = window.__pictureParentUI; return document.activeElement === s.current ? "input" : document.activeElement === s.after ? "after" : document.activeElement === s.f.root ? "root" : `other:${document.activeElement?.localName}`; });
        sequence.push(target); if (target === "input" || target === "after") break;
      }
      phases[phase] = { ...initial, pointer: pointer - initial.clicks, tab: sequence[0], sequence };
    }
    checks.push([`${kind} native owner blocks trusted pointer, Tab and focus despite auto!important`, phases.before.visibleBox && phases.before.focus && phases.before.pointer === 1 && phases.before.tab === "input" && phases.held.visibleBox && phases.held.outside && !phases.held.focus && phases.held.pointer === 0 && phases.held.tab === "after"]);
    checks.push([`${kind} restored owner permits ordinary trusted interaction`, phases.mounted.visibleBox && phases.mounted.outside && phases.mounted.focus && phases.mounted.pointer === 1 && phases.mounted.sequence.at(-1) === "input"]);
    await page.evaluate(() => { const s = window.__pictureParentUI; s.f.cleanup(s.rt); delete window.__pictureParentUI; });
    await page.evaluate(kind => {
      const f = window.__pictureParentMake(kind, { marker: null }), before = document.createElement("button"), after = document.createElement("button"); before.textContent = "before"; after.textContent = "after"; f.wrapper.prepend(before); f.wrapper.append(after); f.root.replaceChildren(); const rt = f.runtime(); rt.mount(); window.__pictureParentUI = { f, before, after, current: rt.lookup(2), rt }; before.focus();
    }, kind);
    const fresh = [];
    for (let step = 0; step < 3; step++) {
      await page.keyboard.press("Tab"); const target = await page.evaluate(() => { const s = window.__pictureParentUI; return document.activeElement === s.current ? "input" : document.activeElement === s.after ? "after" : document.activeElement === s.f.root ? "root" : `other:${document.activeElement?.localName}`; }); fresh.push(target); if (target === "input" || target === "after") break;
    }
    checks.push([`${kind} restored keyboard order equals an ordinary fresh mount`, JSON.stringify(phases.mounted.sequence) === JSON.stringify(fresh)]);
    await page.evaluate(() => { const s = window.__pictureParentUI; s.f.cleanup(s.rt); delete window.__pictureParentUI; });
  }
  // Actual asynchronous fetch/compile boundary: the valid new parent must not
  // steal the first owner's hold while a real Wasm module is being loaded.
  const moved = await page.evaluate(async () => {
    const f = window.__pictureParentMake("svg"); let faults = 0; const instances = [], instantiate = WebAssembly.instantiate;
    WebAssembly.instantiate = async (...args) => { const result = await instantiate(...args); instances.push(result); return result; };
    const promise = window.__pictureParentLoader({ wasmUrl: "/delay.wasm?id=move", root: f.root, onFault: () => { faults++; } }).then(value => ({ value }), error => ({ error }));
    const deadline = performance.now() + 10000;
    while (await (await fetch("/pending?id=move")).text() !== "yes") {
      if (performance.now() > deadline) throw new Error("delayed fixture fetch did not start");
      await new Promise(resolve => setTimeout(resolve, 1));
    }
    const before = f.parent.hasAttribute("inert") && f.root.contains(f.old), next = document.createElement("div"); next.setAttribute("data-roc-picture-inert-parent", ""); f.wrapper.append(next); next.append(f.root);
    await fetch("/release?id=move"); const outcome = await promise; WebAssembly.instantiate = instantiate;
    const failed = !!outcome.error && faults === 1 && instances[0].exports.init_calls() === 0 && f.parent.hasAttribute("inert") && !next.hasAttribute("inert") && f.root.contains(f.old);
    let fetches = 0; const originalFetch = fetch; globalThis.fetch = (...args) => { fetches++; return originalFetch(...args); }; let retryFailed = false; try { await window.__pictureParentLoader({ wasmUrl: "/fresh.wasm", root: f.root }); } catch (_) { retryFailed = true; } finally { globalThis.fetch = originalFetch; }
    const still = retryFailed && fetches === 0 && !next.hasAttribute("inert"); f.parent.append(f.root);
    const rt = await window.__pictureParentLoader({ wasmUrl: "/fresh.wasm", root: f.root, manualEffects: true }); const restored = !f.parent.hasAttribute("inert") && !next.hasAttribute("inert") && !f.root.hasAttribute("data-roc-failed"); rt.unmount(); f.cleanup();
    return [["fetch boundary holds the original exact parent before loading", before], ["fetch-time move faults once before Wasm init without retargeting", failed], ["retry while moved refuses before fetch without taking the new parent", still], ["retry after restoring the declared edge releases the original owner", restored]];
  });
  checks.push(...moved);
  for (const [name, ok] of checks) console.log(`${ok ? "ok  " : "FAIL"} ${name}`);
  if (checks.some(([, ok]) => !ok)) process.exitCode = 1;
} finally { await browser.close(); for (const response of waiting.values()) response.end(); await new Promise(resolve => server.close(resolve)); }
