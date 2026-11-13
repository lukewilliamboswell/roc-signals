// Independent raw protocol18 identity/presence/comment contracts. No app Wasm
// or production encoder supplies expected numbers, names or browser facts.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";
import { protocolFixtureSection } from "./protocol-fixture.mjs";
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
  const checks = await page.evaluate(async fixture => {
    const { RocEngineRuntime } = await import("/runtime.mjs");
    const word = n => [n & 255, (n >>> 8) & 255, (n >>> 16) & 255, n >>> 24];
    const text = value => { const bytes = [...new TextEncoder().encode(value)]; return [...word(bytes.length), ...bytes]; };
    const section = (tag, bytes) => [tag, ...word(bytes.length), ...bytes];
    const declarations = [section(2, word(0)), section(5, word(0)), section(6, word(0)), section(10, [110, 1]), section(11, word(0)), fixture].flat();
    const memory = new WebAssembly.Memory({ initial: 2 });
    let length = 0;
    const root = document.createElement("div"); document.body.append(root);
    const exports = { memory, protocol_version: () => 18,
      boot_keys() { new Uint8Array(memory.buffer).set(declarations); length = declarations.length; },
      cmd_ptr: () => 0, cmd_len: () => length, payload_reserve: () => 65536,
      init() { new Uint8Array(memory.buffer)[0] = 0; length = 1; },
      files_released: () => 0, fault: () => 0, work_len: () => 0, metric: () => 0n, drop() {},
    };
    const runtime = new RocEngineRuntime(exports, root, { manualEffects: true });
    runtime.mount();
    const apply = (...commands) => {
      const bytes = [0, ...commands.flat()];
      new Uint8Array(memory.buffer).set(bytes); length = bytes.length; runtime.apply();
      if (runtime.poisoned) throw new Error(runtime.poisoned.message);
    };
    const name = (code, local, prefix = "", uri = "") => [code, ...(code === 4 ? text(uri) : []), ...text(prefix), ...text(local)];
    const element = (id, parent, expanded) => [8, ...word(id), ...word(parent), ...word(0), ...expanded, 0];
    const attr = (id, expanded, value) => [9, ...word(id), ...expanded, ...(value === null ? [0] : [1, ...text(value)])];
    const checks = [], check = (label, ok) => checks.push([label, !!ok]);
    const html = "http://www.w3.org/1999/xhtml", svg = "http://www.w3.org/2000/svg", xlink = "http://www.w3.org/1999/xlink";
    apply(element(1, 0, name(1, "svg")), element(2, 1, name(1, "g")), element(3, 2, name(0, "DIV")), element(4, 2, name(4, "entry", "p", "urn:entry")));
    const [outer] = root.children, group = outer.firstElementChild, exact = group.children[0], custom = group.children[1];
    check("explicit XHTML uppercase under SVG retains exact local and interface", exact.namespaceURI === html && exact.localName === "DIV" && exact.prefix === null && exact.constructor.name === "HTMLUnknownElement");
    check("custom element retains URI prefix and local", custom.namespaceURI === "urn:entry" && custom.prefix === "p" && custom.localName === "entry");
    check("SVG parent and child retain explicit namespaces", outer.namespaceURI === svg && group.namespaceURI === svg);
    apply(attr(3, name(3, "xlink:href"), "raw"), attr(3, name(4, "href", "xlink", xlink), "qualified"));
    check("raw colon attribute and qualified attribute coexist", exact.getAttributeNS(null, "xlink:href") === "raw" && exact.getAttributeNS(xlink, "href") === "qualified");
    apply(attr(3, name(4, "href", "xlink", xlink), null));
    check("qualified removal preserves raw colon attribute", !exact.hasAttributeNS(xlink, "href") && exact.getAttributeNS(null, "xlink:href") === "raw");
    apply(attr(3, name(3, "x:UPPER"), "one"));
    const first = exact.getAttributeNodeNS(null, "x:UPPER");
    apply(attr(3, name(3, "x:UPPER"), "two"));
    const second = exact.getAttributeNodeNS(null, "x:UPPER");
    apply(attr(3, name(3, "x:UPPER"), "three"));
    check("rare exact attribute updates retain the same Attr object", first === second && second === exact.getAttributeNodeNS(null, "x:UPPER") && first.value === "three" && first.prefix === null);
    apply(attr(3, name(3, "x:UPPER"), null));
    check("rare exact attribute removal detaches only that Attr", first.ownerElement === null && !exact.hasAttributeNS(null, "x:UPPER") && exact.hasAttributeNS(null, "xlink:href"));
    apply(attr(3, name(3, "x:UPPER"), "again"));
    const reinserted = exact.getAttributeNodeNS(null, "x:UPPER");
    check("rare exact attribute reinsert creates a new exact Attr", reinserted !== first && reinserted.localName === "x:UPPER" && reinserted.prefix === null && reinserted.namespaceURI === null && reinserted.value === "again");
    apply(attr(3, name(4, "key", "a", "urn:attr"), "first"));
    const namespaced = exact.getAttributeNodeNS("urn:attr", "key");
    apply(attr(3, name(4, "key", "b", "urn:attr"), "second"));
    check("URI/local attribute replacement retains first prefix and identity", exact.getAttributeNodeNS("urn:attr", "key") === namespaced && namespaced.prefix === "a" && namespaced.value === "second");
    apply(attr(3, name(0, "alias-key", "a"), "first"));
    const aliasAttribute = exact.getAttributeNodeNS(html, "alias-key");
    apply(attr(3, name(4, "alias-key", "b", html), "second"));
    check("builtin namespace and explicit URI alias replace one attribute identity", exact.getAttributeNodeNS(html, "alias-key") === aliasAttribute && aliasAttribute.prefix === "a" && aliasAttribute.value === "second");
    apply(attr(3, name(3, "hidden"), "until-found"), attr(3, name(3, "aria-hidden"), "false"));
    check("enumerated and false text values remain present exactly", exact.getAttribute("hidden") === "until-found" && exact.getAttribute("aria-hidden") === "false");
    apply(attr(3, name(3, "hidden"), ""));
    check("explicit empty attribute remains present", exact.hasAttribute("hidden") && exact.getAttribute("hidden") === "");
    apply(attr(3, name(3, "hidden"), null));
    check("only explicit absence removes an attribute", !exact.hasAttribute("hidden") && exact.getAttribute("aria-hidden") === "false");
    apply([26, ...word(5), ...word(3), ...word(0), ...text("author <!-- data -->")], [10, ...word(6), ...word(3), ...word(0), ...text("visible")]);
    check("comment data occupies childNodes without contributing textContent", exact.childNodes.length === 2 && exact.firstChild.nodeType === 8 && exact.firstChild.data === "author <!-- data -->" && exact.textContent === "visible");
    apply(element(7, 0, name(0, "input")), attr(7, name(3, "VALUE"), "exact attribute"),
      element(8, 0, name(0, "dialog")), attr(8, name(3, "OPEN"), ""), attr(8, name(3, "PoPoVeR"), "manual"), [21, ...word(8), 6, ...text("hidden")]);
    check("exact uppercase VALUE is distinct from an input's live value", runtime.lookup(7).getAttributeNS(null, "VALUE") === "exact attribute" && runtime.lookup(7).value === "");
    check("exact uppercase OPEN and mixed-case PoPoVeR do not claim controlled dialog state", runtime.lookup(8).getAttributeNS(null, "OPEN") === "" && runtime.lookup(8).getAttributeNS(null, "PoPoVeR") === "manual" && runtime.lookup(8).open === false && !runtime.lookup(8).hasAttributeNS(null, "open"));
    // These bytes distinguish explicit ordinary children from inert content;
    // neither the raw API nor the executor infers intent from the template tag.
    const elem = (id, parent, expanded, container) => [8, ...word(id), ...word(parent), ...word(0), ...expanded, container];
    apply(elem(20, 0, name(0, "template"), 0), [10, ...word(21), ...word(20), ...word(0), ...text("ordinary")],
      elem(22, 0, name(0, "template"), 1), [26, ...word(23), ...word(22), ...word(0), ...text("inert comment")], [10, ...word(24), ...word(22), ...word(0), ...text("inert")]);
    const ordinary = runtime.lookup(20), inert = runtime.lookup(22);
    check("ordinary template children remain ordinary and content stays empty", ordinary.childNodes.length === 1 && ordinary.textContent === "ordinary" && ordinary.content.childNodes.length === 0);
    check("explicit content children are inert and excluded from ordinary text", inert.childNodes.length === 0 && inert.textContent === "" && inert.content.childNodes.length === 2 && inert.content.textContent === "inert" && !runtime.lookup(24).isConnected);
    const tree = [1, ...name(0, "div"), 0, 0, 1,
      1, ...name(0, "template"), 1, 0, 2,
        3, ...text("clone comment"), 1, ...name(0, "span"), 0, 0, 1, 2, ...text(""),
      4, // text, attribute, command alias and a row-owned inert observation
      1, 3, 0, 0, 1, 1, 0, 0,
      2, 2, 0, 0, 1, 1, ...name(3, "title"),
      5, 1, 0, 0,
      3, 2, 0, 0, 1, 1, 0, ...text("size"), 7, ...word(8)];
    const instance = (id, alias, value) => [1, ...word(id), ...word(0), ...word(0), ...word(0), ...text(value), 1, ...text(value + " title"), ...word(alias)];
    apply([7, ...word(0), ...word(tree.length), ...tree], instance(30, 31, "first"), instance(40, 41, "second"));
    const row = runtime.lookup(30), cloned = runtime.lookup(31), other = runtime.lookup(41), span = cloned.content.lastChild;
    check("inert content observations retain explicit row ownership", runtime.observationOwners.get(row)?.size === 1 && runtime.observations.has(span) && !span.isConnected);
    check("template clone preserves static comments and resolves content hole paths", cloned.childNodes.length === 0 && cloned.content.firstChild.data === "clone comment" && span.textContent === "first" && span.getAttribute("title") === "first title" && other.content.lastChild.textContent === "second");
    apply([2, ...word(30), 0, ...text("changed")], [3, ...word(30), 1, 1, ...text("changed title")], [10, ...word(32), ...word(31), ...word(0), ...text("nested")]);
    check("cloned content target metadata supports hole updates and nested insertion", span.textContent === "changed" && span.getAttribute("title") === "changed title" && cloned.content.lastChild === runtime.lookup(32) && cloned.content.textContent === "changednested");
    apply([4, ...word(30), ...word(0)]);
    check("moving a row preserves exact content nodes and cached hole targets", runtime.lookup(30) === row && runtime.lookup(31) === cloned && cloned.content.firstChild.data === "clone comment" && row.lastChild === cloned);
    apply([23, ...word(30)], [5, ...word(30)]);
    check("removing a row forgets aliases and dynamically inserted content addresses", runtime.lookup(30) === undefined && runtime.lookup(31) === undefined && runtime.lookup(32) === undefined && !row.isConnected);
    check("row RELEASE retires inert registrations and preserves another row's", !runtime.observations.has(span) && !runtime.observationOwners.has(row) && runtime.observationOwners.get(runtime.lookup(40))?.size === 1);
    apply(instance(30, 31, "reused"));
    check("disposed row and alias IDs reopen with fresh content", runtime.lookup(30) !== row && runtime.lookup(31) !== cloned && runtime.lookup(31).content.lastChild.textContent === "reused");
    apply([23, ...word(30)], [6, ...word(31), ...word(99)]);
    check("CLEAR selects explicit content and preserves the owning template", runtime.lookup(31).content.childNodes.length === 0 && runtime.lookup(31).childNodes.length === 0);
    // These names cannot be reconstructed by createElementNS without
    // changing a prefix/local tuple. Only an empty, identity-checked node
    // comes from the selected browser factory; ordinary bytes add its data.
    let factoryId = 100;
    const math = "http://www.w3.org/1998/Math/MathML", xml = "http://www.w3.org/XML/1998/namespace", xmlns = "http://www.w3.org/2000/xmlns/";
    for (const [code, uri, type] of [[1, svg, SVGElement], [2, math, MathMLElement]]) {
      for (const local of ["h:div", "h:é", "h:a=b", "h:a<x", "h:a&b", 'h:a"b', "h:a'b", "h:a:b", "h:a\u000bb"]) {
        const id = factoryId; factoryId += 2;
        apply(element(id, 0, name(code, local)));
        const node = runtime.lookup(id);
        check(`empty ${code === 1 ? "SVG" : "MathML"} colon factory preserves ${JSON.stringify(local)}`, node.namespaceURI === uri && node.prefix === null && node.localName === local && Object.getPrototypeOf(node) === type.prototype && node.attributes.length === 0 && node.childNodes.length === 0 && node.ownerDocument === document);
        apply(attr(id, name(3, "data-factory"), "from command"), [10, ...word(id + 1), ...word(id), ...word(0), ...text("fresh <& data")]);
        check(`foreign colon data comes only from later ordinary commands ${id}`, runtime.lookup(id) === node && node.attributes.length === 1 && node.getAttribute("data-factory") === "from command" && node.childNodes.length === 1 && node.firstChild === runtime.lookup(id + 1) && node.textContent === "fresh <& data");
      }
    }
    for (const uri of ["urn:entry", 'urn:entry?quote="&less=<', "urn:entry\tline\nnext\rend", "urn:entry\u007ftail", "urn:entry😀", svg, math, xmlns]) {
      const id = factoryId; factoryId += 2;
      apply(element(id, 0, name(4, "xmlns", "", uri)));
      const node = runtime.lookup(id), type = uri === svg ? SVGElement : uri === math ? MathMLElement : Element;
      check(`empty xmlns factory retains URI and removes only its declaration ${JSON.stringify(uri)}`, node.namespaceURI === uri && node.prefix === null && node.localName === "xmlns" && Object.getPrototypeOf(node) === type.prototype && node.attributes.length === 0 && node.childNodes.length === 0 && node.ownerDocument === document);
      apply(attr(id, name(3, "title"), "fresh title"), [26, ...word(id + 1), ...word(id), ...word(0), ...text("fresh comment")]);
      check(`xmlns receives exact attributes/comments from ordinary commands ${id}`, runtime.lookup(id) === node && node.attributes.length === 1 && node.getAttribute("title") === "fresh title" && node.firstChild === runtime.lookup(id + 1) && node.firstChild.data === "fresh comment");
    }
    for (const [site, expanded, uri, local, type] of [[3, name(1, "h:row"), svg, "h:row", SVGElement], [4, name(2, "h:row"), math, "h:row", MathMLElement], [5, name(4, "xmlns", "", "urn:row"), "urn:row", "xmlns", Element]]) {
      const body = [1, ...expanded, 0, 1, ...name(3, "title"), ...text("template command"), 2, 2, ...text("row text"), 3, ...text("row comment"), 0];
      const first = factoryId, second = factoryId + 1; factoryId += 2;
      apply([7, ...word(site), ...word(body.length), ...body], [1, ...word(first), ...word(0), ...word(0), ...word(site)], [1, ...word(second), ...word(0), ...word(0), ...word(site)]);
      const row = runtime.lookup(first), another = runtime.lookup(second), child = row.firstChild;
      check(`template factory and clones preserve full identity/data for site ${site}`, row !== another && [row, another].every(node => node.namespaceURI === uri && node.prefix === null && node.localName === local && Object.getPrototypeOf(node) === type.prototype && node.attributes.length === 1 && node.getAttribute("title") === "template command" && node.childNodes.length === 2 && node.firstChild.data === "row text" && node.lastChild.data === "row comment"));
      apply([4, ...word(first), ...word(0)]);
      check(`factory row move preserves element and child identities ${site}`, runtime.lookup(first) === row && row.firstChild === child);
    }
    // Ordinary custom URI elements still accept XML-forbidden URI data when
    // the native factory directly represents it. This is not an XML URI gate.
    apply(element(factoryId, 0, name(4, "entry", "", "urn:ordinary\u0000tail")));
    check("ordinary namespace URI controls remain data through direct construction", runtime.lookup(factoryId).namespaceURI === "urn:ordinary\u0000tail");
    factoryId++;
    // Negative framing uses fresh real mounts, so a poison never serves as
    // permission to continue another case and every malformed operand is reached.
    const fresh = wrapper => {
      const memory = new WebAssembly.Memory({ initial: 2 });
      let length = 0, reserved = 0, initCalls = 0, boot;
      const x = { memory, protocol_version: () => 18,
        boot_keys() { new Uint8Array(memory.buffer).set(declarations); length = declarations.length; },
        cmd_ptr: () => 0, cmd_len: () => length,
        payload_reserve(size) { reserved = size; return 65536; },
        init() { initCalls++; boot = [...new Uint8Array(memory.buffer, 65536, reserved)]; new Uint8Array(memory.buffer)[0] = 0; length = 1; },
        files_released: () => 0, fault: () => 0, work_len: () => 0, metric: () => 0n, drop() {},
      };
      const rt = new RocEngineRuntime(x, wrapper, { manualEffects: true });
      return { rt, get initCalls() { return initCalls; }, get boot() { return boot; }, raw(bytes) { new Uint8Array(memory.buffer).set([0, ...bytes]); length = bytes.length + 1; rt.guard(() => rt.applyBatch()); } };
    };
    const invalid = [
      ["unknown namespace byte", [8, ...word(1), ...word(0), ...word(0), 255, ...text(""), ...text("div"), 0]],
      ["xml prefix with wrong namespace", elem(1, 0, name(1, "entry", "xml"), 0)],
      ["unknown child container", elem(1, 0, name(0, "div"), 2)],
      ["content container on HTML div", elem(1, 0, name(0, "div"), 1)],
      ["content container on SVG template", elem(1, 0, name(1, "template"), 1)],
    ];
    for (const code of [1, 2]) for (const local of ["h:DIV", "H:div", ":x", "é:x", "_x:y"]) invalid.push([`unconstructible foreign colon ${code}/${local}`, element(1, 0, name(code, local))]);
    for (const uri of [xml, "urn:bad\u0000", "urn:bad\u000b", "urn:bad\ufffe", "urn:bad\uffff"]) invalid.push([`unconstructible xmlns URI ${JSON.stringify(uri)}`, element(1, 0, name(4, "xmlns", "", uri))]);
    const badPath = container => [1, ...name(0, "div"), 0, 0, 1, 2, ...text("x"), 1, 1, 1, container, 0];
    for (const [label, code] of [["unknown hole container", 2], ["content path on ordinary element", 1]]) {
      const body = badPath(code); invalid.push([label, [7, ...word(0), ...word(body.length), ...body]]);
    }
    for (const [label, bytes] of invalid) {
      const wrapper = document.createElement("div"); document.body.append(wrapper);
      const f = fresh(wrapper); f.rt.mount(); f.raw(bytes);
      check(`${label} is an executor fault before publication`, f.rt.poisoned?.class === "executor" && wrapper.childNodes.length === 0);
      f.rt.unmount(); wrapper.remove();
    }
    // Independently damage the browser result. A helper may return only the
    // exact empty node, never discard arbitrary parser data to make it fit.
    for (const mutation of ["attribute", "child", "identity", "import"]) {
      const wrapper = document.createElement("div"); document.body.append(wrapper);
      const f = fresh(wrapper); f.rt.mount();
      const parse = DOMParser.prototype.parseFromString, importNode = Document.prototype.importNode;
      if (mutation === "import") Document.prototype.importNode = function (...args) { const node = importNode.apply(this, args); node.setAttribute("data-injected", "bad"); return node; };
      else DOMParser.prototype.parseFromString = function (...args) {
        const parsed = parse.apply(this, mutation === "identity" ? ['<xmlns xmlns="urn:wrong"/>', "application/xml"] : args);
        if (mutation === "attribute") parsed.documentElement.setAttribute("data-injected", "bad");
        if (mutation === "child") parsed.documentElement.appendChild(parsed.createComment("bad"));
        return parsed;
      };
      try { f.raw(element(1, 0, name(4, "xmlns", "", "urn:expected"))); }
      finally { DOMParser.prototype.parseFromString = parse; Document.prototype.importNode = importNode; }
      check(`empty-node factory refuses injected ${mutation} without publishing a node`, f.rt.poisoned?.class === "executor" && wrapper.childNodes.length === 0);
      f.rt.unmount(); wrapper.remove();
    }
    for (const uri of ["u".repeat(65536), "é".repeat(32768)]) {
      const wrapper = document.createElementNS(uri, "entry"); document.body.append(wrapper);
      const f = fresh(wrapper);
      let refused = false; try { f.rt.mount(); } catch (error) { refused = error.message.includes("65536"); }
      check(`mount-root ${uri[0] === "u" ? "structural" : "UTF-8"} byte bound refuses before init`, f.initCalls === 0 && (refused || f.rt.poisoned?.message.includes("65536")));
      f.rt.unmount(); wrapper.remove();
    }
    const wrapper = document.createElementNS(svg, "s:foreignObject"); document.body.append(wrapper);
    const measured = fresh(wrapper); measured.rt.mount();
    const expectedRoot = [13, ...word(1 + text("s").length + text("foreignObject").length), 1, ...text("s"), ...text("foreignObject")];
    check("boot carries the actual wrapper URI prefix and exact local in engine-only section13", JSON.stringify(measured.boot.slice(-expectedRoot.length)) === JSON.stringify(expectedRoot));
    measured.rt.unmount(); wrapper.remove();
    runtime.unmount(); root.remove();
    return checks;
  }, [...protocolFixtureSection]);
  for (const [name, ok] of checks) console.log(`${ok ? "ok  " : "FAIL"} ${name}`);
  if (checks.some(([, ok]) => !ok)) process.exitCode = 1;
} finally { await browser.close(); await new Promise(resolve => server.close(resolve)); }
