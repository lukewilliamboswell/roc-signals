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
    apply(attr(3, name(3, "hidden"), "until-found"), attr(3, name(3, "aria-hidden"), "false"));
    check("enumerated and false text values remain present exactly", exact.getAttribute("hidden") === "until-found" && exact.getAttribute("aria-hidden") === "false");
    apply(attr(3, name(3, "hidden"), ""));
    check("explicit empty attribute remains present", exact.hasAttribute("hidden") && exact.getAttribute("hidden") === "");
    apply(attr(3, name(3, "hidden"), null));
    check("only explicit absence removes an attribute", !exact.hasAttribute("hidden") && exact.getAttribute("aria-hidden") === "false");
    apply([26, ...word(5), ...word(3), ...word(0), ...text("author <!-- data -->")], [10, ...word(6), ...word(3), ...word(0), ...text("visible")]);
    check("comment data occupies childNodes without contributing textContent", exact.childNodes.length === 2 && exact.firstChild.nodeType === 8 && exact.firstChild.data === "author <!-- data -->" && exact.textContent === "visible");
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
      3, // three holes: text, attribute, and a command alias for nested insertion
      1, 3, 0, 0, 1, 1, 0, 0,
      2, 2, 0, 0, 1, 1, ...name(3, "title"),
      5, 1, 0, 0];
    const instance = (id, alias, value) => [1, ...word(id), ...word(0), ...word(0), ...word(0), ...text(value), 1, ...text(value + " title"), ...word(alias)];
    apply([7, ...word(0), ...word(tree.length), ...tree], instance(30, 31, "first"), instance(40, 41, "second"));
    const row = runtime.lookup(30), cloned = runtime.lookup(31), other = runtime.lookup(41), span = cloned.content.lastChild;
    check("template clone preserves static comments and resolves content hole paths", cloned.childNodes.length === 0 && cloned.content.firstChild.data === "clone comment" && span.textContent === "first" && span.getAttribute("title") === "first title" && other.content.lastChild.textContent === "second");
    apply([2, ...word(30), 0, ...text("changed")], [3, ...word(30), 1, 1, ...text("changed title")], [10, ...word(32), ...word(31), ...word(0), ...text("nested")]);
    check("cloned content target metadata supports hole updates and nested insertion", span.textContent === "changed" && span.getAttribute("title") === "changed title" && cloned.content.lastChild === runtime.lookup(32) && cloned.content.textContent === "changednested");
    apply([4, ...word(30), ...word(0)]);
    check("moving a row preserves exact content nodes and cached hole targets", runtime.lookup(30) === row && runtime.lookup(31) === cloned && cloned.content.firstChild.data === "clone comment" && row.lastChild === cloned);
    apply([5, ...word(30)]);
    check("removing a row forgets aliases and dynamically inserted content addresses", runtime.lookup(30) === undefined && runtime.lookup(31) === undefined && runtime.lookup(32) === undefined && !row.isConnected);
    apply(instance(30, 31, "reused"));
    check("disposed row and alias IDs reopen with fresh content", runtime.lookup(30) !== row && runtime.lookup(31) !== cloned && runtime.lookup(31).content.lastChild.textContent === "reused");
    apply([6, ...word(31), ...word(99)]);
    check("CLEAR selects explicit content and preserves the owning template", runtime.lookup(31).content.childNodes.length === 0 && runtime.lookup(31).childNodes.length === 0);
    runtime.unmount(); root.remove();
    return checks;
  }, [...protocolFixtureSection]);
  for (const [name, ok] of checks) console.log(`${ok ? "ok  " : "FAIL"} ${name}`);
  if (checks.some(([, ok]) => !ok)) process.exitCode = 1;
} finally { await browser.close(); await new Promise(resolve => server.close(resolve)); }
