// Actual Chrome preparation through the production boundary: explicit sibling
// association, bounded descriptor data, and passive measurement. No app Wasm.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";
const options = parseArgs(process.argv.slice(2), [], ["runtime"]);
const files = { ...runtimeFiles(options.runtime), "picture-measurement-cases.mjs": fileURLToPath(new URL("./picture-measurement-cases.mjs", import.meta.url)) };
const server = http.createServer((request, response) => {
  const file = files[path.basename(new URL(request.url, "http://x").pathname)];
  response.writeHead(200, { "content-type": file ? "text/javascript" : "text/html" });
  response.end(file ? fs.readFileSync(file) : "<!doctype html>");
});
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
const browser = await launch({ executablePath: options.chrome });
try {
  console.log(JSON.stringify(await browser.conn.send("Browser.getVersion")));
  const page = await browser.newPage(); await page.goto(`http://127.0.0.1:${server.address().port}/`);
  const checks = await page.evaluate(async () => {
    const { preparePicture } = await import("/runtime.mjs");
    const { measurementEnvelope } = await import("/picture-measurement-cases.mjs");
    const html = "http://www.w3.org/1999/xhtml", svg = "http://www.w3.org/2000/svg";
    const checks = [], check = (label, ok) => checks.push([label, !!ok]);
    const empty = { physicalCount: 0, containers: [[0xffffffff, 0, []]], logical: [], runs: [], bindings: [], scaffolds: [], batch_bytes: 0 };
    const bytes = measurementEnvelope(empty), payload = JSON.stringify([...bytes]);
    const fixture = ({ marker = "19:1", data = payload, envelope = empty, xml = false } = {}) => {
      const doc = xml ? document.implementation.createDocument(null, "parent") : document;
      const parent = xml ? doc.documentElement : doc.createElement("div");
      const root = doc.createElementNS(null, "x"), descriptor = doc.createElementNS(html, xml ? "h:script" : "script");
      if (marker !== null) root.setAttributeNS(null, "data-roc-picture", marker);
      descriptor.setAttributeNS(null, "type", "application/json"); descriptor.setAttributeNS(null, "data-roc-picture-envelope", "1");
      descriptor.appendChild(doc.createTextNode(data)); parent.append(root, descriptor);
      return { root, descriptor, parent, doc, envelope };
    };
    // Guard every production call, including failing paths. Observer callbacks
    // accumulate delivered records so an awaited hash cannot hide a mutation.
    const prepare = async (f, limits) => {
      let mutations = 0; const observer = new MutationObserver(records => { mutations += records.length; });
      observer.observe(f.parent, { subtree: true, attributes: true, childList: true, characterData: true });
      const guards = [
        [Document.prototype, ["createElement", "createElementNS", "createTextNode", "createComment", "createDocumentFragment", "querySelector", "querySelectorAll", "getElementById", "getElementsByTagName", "getElementsByTagNameNS", "getElementsByClassName"]],
        [Element.prototype, ["querySelector", "querySelectorAll", "setAttribute", "setAttributeNS", "removeAttribute", "removeAttributeNS", "replaceChildren"]],
        [Node.prototype, ["appendChild", "insertBefore", "removeChild", "replaceChild"]],
      ];
      const saved = [];
      for (const [target, names] of guards) for (const name of names) {
        saved.push([target, name, Object.getOwnPropertyDescriptor(target, name)]);
        Object.defineProperty(target, name, { configurable: true, value() { throw new Error(`preparation called forbidden DOM ${name}`); } });
      }
      try { return await preparePicture(f.root, limits); }
      finally {
        mutations += observer.takeRecords().length; observer.disconnect();
        for (const [target, name, previous] of saved) if (previous) Object.defineProperty(target, name, previous); else delete target[name];
        if (mutations) throw new Error("preparation changed the picture or descriptor");
      }
    };
    const valid = fixture(), result = await prepare(valid);
    check("exact sibling descriptor returns checked Present facts and identity", result.picture?.measured.length === 32 && result.picture.envelope.length === bytes.length && result.descriptor === valid.descriptor && result.measurement.physical.length === 0 && result.diagnostic === null);
    check("preparation makes no adoption decision on stored digest mismatch", result.picture !== null && !result.picture.measured.every((n, i) => n === result.measurement.envelope.expectedDigest[i]) && !Object.hasOwn(result, "adopt"));
    check("preparation preserves marker, picture, descriptor and their identities", valid.root.parentNode === valid.parent && valid.root.nextElementSibling === valid.descriptor && valid.root.getAttributeNS(null, "data-roc-picture") === "19:1" && valid.descriptor.firstChild.data === payload && !valid.root.hasAttribute("inert"));
    for (const marker of [null, ""]) {
      const f = fixture({ marker }); let siblingReads = 0;
      Object.defineProperty(f.root, "nextElementSibling", { get() { siblingReads++; throw new Error("must not inspect stage1 sibling"); } });
      const answer = await prepare(f);
      check(`${marker === null ? "ordinary" : "stage1 empty"} marker is Absent without sibling lookup`, answer.picture === null && answer.descriptor === null && answer.diagnostic === null && siblingReads === 0);
    }
    for (const marker of ["18:1", "19:2", " 19:1", "19:1 ", "19:01"]) {
      const f = fixture({ marker }), answer = await prepare(f); check(`malformed marker ${JSON.stringify(marker)} is diagnosed Absent`, answer.picture === null && answer.diagnostic?.code === "marker" && answer.descriptor === null && f.descriptor.firstChild.data === payload);
    }
    for (const [label, alter] of [
      ["missing", f => f.descriptor.remove()],
      ["intervening element", f => f.parent.insertBefore(f.doc.createElement("aside"), f.descriptor)],
      ["wrong type case", f => f.descriptor.setAttributeNS(null, "type", "Application/JSON")],
      ["wrong role", f => f.descriptor.setAttributeNS(null, "data-roc-picture-envelope", "01")],
      ["foreign script", f => { const foreign = f.doc.createElementNS(svg, "script"); foreign.setAttribute("type", "application/json"); foreign.setAttribute("data-roc-picture-envelope", "1"); f.parent.insertBefore(foreign, f.descriptor); }],
      ["HTML non-script", f => { const other = f.doc.createElement("div"); other.setAttribute("type", "application/json"); other.setAttribute("data-roc-picture-envelope", "1"); f.parent.insertBefore(other, f.descriptor); }],
    ]) { const f = fixture(); alter(f); const answer = await prepare(f); check(`${label} locator is diagnosed without claiming an author element`, answer.picture === null && answer.descriptor === null && answer.diagnostic?.code === "locator"); }
    const comments = fixture(); comments.parent.insertBefore(comments.doc.createComment("roc:node=9 data-n=1"), comments.descriptor); comments.parent.insertBefore(comments.doc.createTextNode("\n"), comments.descriptor);
    check("explicit nextElementSibling ignores only intervening non-elements", (await prepare(comments)).descriptor === comments.descriptor);
    const collision = fixture(); collision.root.setAttributeNS(null, "id", "shared"); collision.descriptor.setAttributeNS(null, "id", "shared"); const unrelated = collision.doc.createElement("script"); unrelated.id = "shared"; unrelated.type = "application/json"; unrelated.setAttribute("data-roc-picture-envelope", "1"); unrelated.textContent = "malformed"; collision.parent.insertBefore(unrelated, collision.root);
    check("duplicate IDs and earlier marked scripts do not affect association", (await prepare(collision)).descriptor === collision.descriptor);
    const nested = fixture(); const nestedScript = nested.doc.createElement("script"); nestedScript.type = "application/json"; nestedScript.setAttribute("data-roc-picture-envelope", "1"); nestedScript.textContent = payload; nested.root.append(nestedScript); nested.descriptor.remove();
    check("a matching descendant is never used as a descriptor", (await prepare(nested)).diagnostic?.code === "locator");
    const author = { ...structuredClone(empty), physicalCount: 1, containers: [[0xffffffff, 0, [0]]], logical: [[1, 0]] };
    const authoredComment = fixture({ data: JSON.stringify([...measurementEnvelope(author)]) }); const comment = authoredComment.doc.createComment("roc:node=9 roc:row=2 data-n=1"); authoredComment.root.append(comment);
    check("author comments remain physical data without becoming claims", (await prepare(authoredComment)).measurement.physical[0] === comment);
    for (const [label, data, code] of [
      ["non-ASCII", "[83,é]", "ascii"], ["BOM", "\ufeff[]", "ascii"], ["nested array", "[[0]]", "json"], ["object", "{}", "json"], ["string item", '["83"]', "json"],
      ["boolean item", "[true]", "json"], ["trailing comma", "[0,]", "json"], ["missing close", "[0", "json"], ["extra JSON", "[] []", "json"],
      ["fraction", "[1.5]", "byte_value"], ["negative", "[-1]", "byte_value"], ["overflow byte", "[256]", "byte_value"], ["infinite exponent", "[1e999]", "byte_value"],
    ]) { const f = fixture({ data }), answer = await prepare(f); check(`${label} payload is diagnosed and both nodes retained`, answer.picture === null && answer.descriptor === f.descriptor && answer.diagnostic?.code === code && f.root.parentNode === f.parent && f.descriptor.firstChild.data === data); }
    const numeric = `[${[...bytes].map((value, i) => value === 0 ? (i % 2 ? "-0" : "0e0") : `${value}.0`).join(",")}]`;
    check("standard JSON numeric spellings yielding integer bytes are accepted", (await prepare(fixture({ data: numeric }))).picture?.envelope.every((n, i) => n === bytes[i]));
    const split = fixture(); split.descriptor.replaceChildren(split.doc.createTextNode(payload.slice(0, 3)), split.doc.createTextNode(""), split.doc.createTextNode(payload.slice(3)));
    check("direct split text is joined without changing fragment identities", (await prepare(split, { max_descriptor_fragments: 3 })).picture !== null && split.descriptor.childNodes.length === 3);
    const cdata = fixture({ xml: true }); cdata.descriptor.replaceChildren(cdata.doc.createCDATASection(payload.slice(0, 4)), cdata.doc.createTextNode(payload.slice(4)));
    check("explicit XML HTML-script CDATA/Text fragments are accepted", (await prepare(cdata)).picture !== null && cdata.descriptor.firstChild.nodeType === 4);
    const zeroNodes = await prepare(fixture(), { maxNodes: 0, maxDepth: 0, max_descriptor_fragments: 1 }); check("descriptor fragments are independent of physical maxNodes zero", zeroNodes.picture !== null);
    const nonText = fixture(); nonText.descriptor.append(nonText.doc.createComment("not ignored")); check("non-character descriptor children are malformed", (await prepare(nonText)).diagnostic?.code === "descriptor_children");
    const fragments = fixture(); for (let i = 0; i < 5; i++) fragments.descriptor.append(fragments.doc.createTextNode("")); let dataReads = 0;
    Object.defineProperty(fragments.descriptor.firstChild, "data", { configurable: true, get() { dataReads++; throw new Error("must refuse fragment count first"); } });
    check("empty-fragment excess refuses before reading any fragment data", (await prepare(fragments, { max_descriptor_fragments: 5 })).diagnostic?.code === "descriptor_fragments" && dataReads === 0);
    const noContentGetter = fixture(); for (const property of ["textContent", "text", "innerHTML"]) Object.defineProperty(noContentGetter.descriptor, property, { get() { throw new Error(`unbounded ${property} read`); } });
    check("preparation never reads an unbounded descriptor textContent/text/innerHTML", (await prepare(noContentGetter)).picture !== null);
    const byteBound = fixture({ data: `[${Array(80).fill(0).join(",")}]` }), textBound = fixture({ data: " ".repeat(515) });
    const byteValue = fixture({ data: "[256]" }), ascii = fixture({ data: "[é]" });
    for (const [label, f, limits, expectedCode, expectedParses] of [
      ["text bound", textBound, { maxBytes: 128 }, "descriptor_size", 0], ["element count bound", byteBound, { maxBytes: 64 }, "byte_count", 0],
      ["ASCII bound", ascii, {}, "ascii", 0], ["byte value validation", byteValue, {}, "byte_value", 1],
    ]) {
      let parses = 0, joins = 0, allocations = 0; const parse = JSON.parse, join = Array.prototype.join, Bytes = globalThis.Uint8Array;
      JSON.parse = (...args) => { parses++; return parse(...args); }; Array.prototype.join = function (...args) { joins++; return join.apply(this, args); };
      globalThis.Uint8Array = new Proxy(Bytes, { construct(target, args, newTarget) { allocations++; return Reflect.construct(target, args, newTarget); } });
      let answer; try { answer = await prepare(f, limits); } finally { JSON.parse = parse; Array.prototype.join = join; globalThis.Uint8Array = Bytes; }
      check(`${label} occurs before byte allocation`, answer.diagnostic?.code === expectedCode && parses === expectedParses && allocations === 0 && (expectedParses !== 0 || joins === 0));
    }
    let allTruncations = true;
    for (let end = 0; end < bytes.length; end++) {
      const f = fixture({ data: JSON.stringify([...bytes.subarray(0, end)]) }), answer = await prepare(f);
      if (answer.picture !== null || answer.descriptor !== f.descriptor || answer.diagnostic?.code !== "binary") { allTruncations = false; break; }
    }
    check("every binary byte truncation becomes diagnosed Absent without mutation", allTruncations);
    const mismatch = fixture(); mismatch.root.append(mismatch.doc.createTextNode("unexpected")); check("invalid actual measurement becomes diagnosed Absent", (await prepare(mismatch)).diagnostic?.code === "measurement");
    const textareaRecords = { ...structuredClone(empty), physicalCount: 2, containers: [[0xffffffff, 0, [0]], [0, 0, [1]]], logical: [[0, 0], [3, 1, 0, "old"], [4, 1, 1, "comment"]], scaffolds: [[0, 0, 1, 1]] };
    const textarea = fixture({ data: JSON.stringify([...measurementEnvelope(textareaRecords)]) }); const control = textarea.doc.createElementNS(html, "h:textarea"); control.append(textarea.doc.createTextNode("rendered")); textarea.root.append(control);
    check("preparation carries measured ControlText scaffold facts without acting", (await prepare(textarea)).measurement.envelope.scaffolds[0].role === 0 && control.firstChild.data === "rendered");
    const selectionRecords = { ...structuredClone(empty), physicalCount: 2, containers: [[0xffffffff, 0, [0]], [0, 0, [1]], [1, 0, []]], logical: [[0, 0]], scaffolds: [[2, 0, 1]] };
    const selection = fixture({ data: JSON.stringify([...measurementEnvelope(selectionRecords)]) }); const select = selection.doc.createElement("select"), option = selection.doc.createElement("option"); for (const name of ["hidden", "selected", "value"]) option.setAttribute(name, ""); select.append(option); selection.root.append(select);
    check("preparation does not remove a declared NoSelectionOption scaffold", (await prepare(selection)).picture !== null && option.parentNode === select && option.attributes.length === 3);
    const attributeRecords = { ...structuredClone(selectionRecords), logical: [[0, 0], [0, 1]], scaffolds: [[1, 1, ["", "", "selected"], 0, null, ""]] };
    const attribute = fixture({ data: JSON.stringify([...measurementEnvelope(attributeRecords)]) }); const select2 = attribute.doc.createElement("select"), option2 = attribute.doc.createElement("option"); option2.setAttribute("selected", ""); select2.append(option2); attribute.root.append(select2);
    check("preparation does not restore or alter AttributeOverride scaffolds", (await prepare(attribute)).picture !== null && option2.getAttribute("selected") === "");
    const cap = await prepare(fixture(), { maxBytes: bytes.length }); check("exact envelope byte cap permits valid preparation", cap.picture?.envelope.length === bytes.length);
    check("measurement allocation cap is reported without an init/verdict", (await prepare(fixture(), { max_measurement_bytes: 94 })).diagnostic?.code === "measurement");
    const authoredInert = fixture(); authoredInert.root.setAttributeNS(null, "inert", "author text"); authoredInert.root.setAttributeNS(null, "data-roc-picture-inert", "added");
    const inertPrepared = await prepare(authoredInert); check("external inert bootstrap facts remain untouched and unhashed", inertPrepared.picture?.measured.every((n, i) => n === result.picture.measured[i]) && authoredInert.root.getAttributeNS(null, "inert") === "author text" && authoredInert.root.getAttributeNS(null, "data-roc-picture-inert") === "added");
    const svgParent = document.createElementNS(svg, "svg"); svgParent.innerHTML = "<h:div></h:div>"; const svgRoot = svgParent.firstChild; svgRoot.setAttributeNS(null, "data-roc-picture", "19:1");
    const svgEnvelope = measurementEnvelope({ ...structuredClone(empty), root_name: [svg, "", "h:div"] }), svgDescriptor = document.createElement("script"); svgDescriptor.type = "application/json"; svgDescriptor.setAttribute("data-roc-picture-envelope", "1"); svgDescriptor.append(document.createTextNode(JSON.stringify([...svgEnvelope]))); svgParent.append(svgDescriptor);
    check("existing SVG colon-local root uses its explicit HTML script sibling", (await prepare({ root: svgRoot, descriptor: svgDescriptor, parent: svgParent })).picture !== null);
    const xmlnsEnvelope = measurementEnvelope({ ...structuredClone(empty), root_name: ["urn:entry", "", "xmlns"] });
    const xmlDoc = new DOMParser().parseFromString(`<parent><xmlns xmlns="urn:entry" data-roc-picture="19:1"/><h:script xmlns:h="${html}" type="application/json" data-roc-picture-envelope="1"><![CDATA[${JSON.stringify([...xmlnsEnvelope])}]]></h:script></parent>`, "application/xml");
    const xmlnsRoot = xmlDoc.documentElement.firstElementChild, xmlnsDescriptor = xmlnsRoot.nextElementSibling;
    check("existing custom-URI xmlns root prepares without a factory fallback", (await prepare({ root: xmlnsRoot, descriptor: xmlnsDescriptor, parent: xmlDoc.documentElement })).picture !== null);
    for (const limits of [{ max_descriptor_fragments: -1 }, { max_descriptor_fragments: 262145 }, { max_descriptor_fragments: null }, { maxNodes: -1 }, { max_measurement_bytes: null }, { invented: 1 }]) {
      let error; try { await prepare(fixture(), limits); } catch (caught) { error = caught; }
      check(`invalid caller limits throw classified errors ${JSON.stringify(limits)}`, error?.code === "limits" || error?.rule?.startsWith("invalid"));
    }
    check("all preparation paths are factory/query/mutation-free", true);
    return checks;
  });
  for (const [name, ok] of checks) console.log(`${ok ? "ok  " : "FAIL"} ${name}`);
  if (checks.some(([, ok]) => !ok)) process.exitCode = 1;
} finally { await browser.close(); await new Promise(resolve => server.close(resolve)); }
