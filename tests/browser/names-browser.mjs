// node tests/browser/names-browser.mjs --chrome PATH [--corpus FILE]
// The shared corpus checks context-free HTML local-name and Fetch grammar.
// Namespace-specific qualification depends on construction context (#246).
import fs from "node:fs";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { launch } from "./cdp.mjs";

const { values: options } = parseArgs({ options: {
  chrome: { type: "string", default: process.env.CHROME ?? "chrome" },
  corpus: { type: "string", default: fileURLToPath(new URL("../../fuzz/names/corpus.tsv", import.meta.url)) },
  runtime: { type: "string" },
  "expanded-corpus": { type: "string", default: fileURLToPath(new URL("../../fuzz/names/expanded.tsv", import.meta.url)) },
} });
// A leading U+FEFF is name data, not a file signature to discard.
const utf8 = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });
const cases = fs.readFileSync(options.corpus, "utf8").split("\n").filter((line) => line.length !== 0).map((line) => {
  const columns = line.split("\t");
  if (columns.length !== 3 || !/^[01]{3}$/.test(columns[1]) || !/^(?:[0-9a-f]{2})*$/.test(columns[2])) throw new Error("invalid name corpus row");
  const [name, flags, hex] = columns;
  return { name, text: utf8.decode(Buffer.from(hex, "hex")), expected: { tag: flags[0] === "1", attribute: flags[1] === "1", method: flags[2] === "1" } };
});
// These are independent modern DOM namespace facts, not XML QName rules.
const namespaceCases = fs.readFileSync(new URL("../../fuzz/names/namespaces.tsv", import.meta.url), "utf8").trimEnd().split("\n").map(line => {
  const [name, flags, namespaceHex, qualifiedHex] = line.split("\t");
  if (!/^[01]{2}$/.test(flags) || !/^(?:[0-9a-f]{2})*$/.test(namespaceHex) || !/^(?:[0-9a-f]{2})*$/.test(qualifiedHex)) throw new Error("invalid namespace corpus row");
  return { name, namespace: utf8.decode(Buffer.from(namespaceHex, "hex")), qualified: utf8.decode(Buffer.from(qualifiedHex, "hex")), expected: { element: flags[0] === "1", attribute: flags[1] === "1" } };
});
// Expanded identity facts include parser-created names which a namespace-aware
// factory alone cannot express. This independent browser construction checks
// the corpus separately from the executor's verified empty-node factories.
const expandedCases = fs.readFileSync(options["expanded-corpus"], "utf8").trimEnd().split("\n").map(line => {
  const [name, flags, namespace, prefix, local] = line.split("\t");
  if (!/^[01]{2}$/.test(flags) || ![namespace, local, ...(prefix === "-" ? [] : [prefix])].every(value => /^(?:[0-9a-f]{2})*$/.test(value))) throw new Error("invalid expanded-name corpus row");
  const decode = value => utf8.decode(Buffer.from(value, "hex"));
  return { name, namespace: decode(namespace) || null, prefix: prefix === "-" ? null : decode(prefix), local: decode(local), expected: { tag: flags[0] === "1", attribute: flags[1] === "1" } };
});
if (cases.length === 0 || new Set(cases.map((entry) => entry.name)).size !== cases.length) throw new Error("the name corpus must be nonempty with unique names");
const browser = await launch({ executablePath: options.chrome });
let failed = 0;
try {
  const context = await browser.createBrowserContext();
  const page = await context.newPage();
  await page.goto("data:text/html;charset=utf-8,<!doctype html><title>Name grammar</title>");
  const actual = await page.evaluate((inputs) => {
    const accepted = (run) => { try { run(); return true; } catch (_) { return false; } };
    return inputs.map(({ name, text }) => ({ name, result: {
      tag: accepted(() => document.createElement(text)),
      attribute: accepted(() => document.createElement("div").setAttribute(text, "value")),
      method: accepted(() => new Request("http://localhost/name-grammar", { method: text })),
    } }));
  }, cases);
  for (let index = 0; index < cases.length; index += 1) {
    const expected = cases[index];
    const result = actual[index];
    if (result.name !== expected.name || JSON.stringify(result.result) !== JSON.stringify(expected.expected)) {
      failed += 1;
      console.log(`FAIL ${expected.name}: got ${JSON.stringify(result.result)}, expected ${JSON.stringify(expected.expected)}`);
    }
  }
  const namespaceActual = await page.evaluate(inputs => inputs.map(({ name, namespace, qualified }) => {
    const accepted = run => { try { run(); return true; } catch (_) { return false; } };
    return { name, result: {
      element: accepted(() => document.createElementNS(namespace, qualified)),
      attribute: accepted(() => document.createElement("div").setAttributeNS(namespace, qualified, "value")),
    } };
  }), namespaceCases);
  for (let index = 0; index < namespaceCases.length; index += 1) {
    const expected = namespaceCases[index], result = namespaceActual[index];
    if (result.name !== expected.name || JSON.stringify(result.result) !== JSON.stringify(expected.expected)) {
      failed += 1;
      console.log(`FAIL namespace ${expected.name}: got ${JSON.stringify(result.result)}, expected ${JSON.stringify(expected.expected)}`);
    }
  }
  const expandedActual = await page.evaluate(inputs => inputs.map(input => {
    const exact = node => node.namespaceURI === input.namespace && node.prefix === input.prefix && node.localName === input.local;
    const qualified = input.prefix === null ? input.local : `${input.prefix}:${input.local}`;
    const html = "http://www.w3.org/1999/xhtml", svg = "http://www.w3.org/2000/svg", math = "http://www.w3.org/1998/Math/MathML";
    const accepts = factory => { try { return exact(factory()); } catch { return false; } };
    const element = () => {
      if (input.prefix === null && input.namespace === null) return document.implementation.createDocument(null, "").createElement(input.local);
      if (input.prefix === null && input.namespace === html && (input.local.includes(":") || input.local === "xmlns")) return document.createElement(input.local);
      if (input.prefix === null && [svg, math].includes(input.namespace) && input.local.includes(":")) {
        const wrapper = document.createElement("template"), outer = input.namespace === svg ? "svg" : "math";
        wrapper.innerHTML = `<${outer}><${input.local}></${input.local}></${outer}>`;
        return wrapper.content.firstChild.firstChild;
      }
      if (input.prefix === null && input.local === "xmlns" && input.namespace !== "http://www.w3.org/2000/xmlns/") {
        const escape = text => text.replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;").replaceAll("\t", "&#9;").replaceAll("\n", "&#10;").replaceAll("\r", "&#13;");
        const parsed = new DOMParser().parseFromString(`<xmlns xmlns="${escape(input.namespace)}"/>`, "application/xml");
        const node = parsed.documentElement;
        node.removeAttributeNS("http://www.w3.org/2000/xmlns/", "xmlns");
        return node;
      }
      return document.createElementNS(input.namespace, qualified);
    };
    const attribute = () => input.prefix === null && input.namespace === null
      ? document.implementation.createDocument(null, "").createAttribute(input.local)
      : document.createAttributeNS(input.namespace, qualified);
    return { name: input.name, result: { tag: accepts(element), attribute: accepts(attribute) } };
  }), expandedCases);
  for (let index = 0; index < expandedCases.length; index += 1) {
    const expected = expandedCases[index], actual = expandedActual[index];
    if (actual.name !== expected.name || JSON.stringify(actual.result) !== JSON.stringify(expected.expected)) {
      failed += 1;
      console.log(`FAIL expanded ${expected.name}: got ${JSON.stringify(actual.result)}, expected ${JSON.stringify(expected.expected)}`);
    }
  }
  const namespaceIdentities = await page.evaluate(() => {
    const html = "http://www.w3.org/1999/xhtml", xlink = "http://www.w3.org/1999/xlink";
    const identity = node => ({ namespace: node.namespaceURI, prefix: node.prefix, local: node.localName, interface: node.constructor.name });
    const ordinary = document.createElement("h:div"), qualified = document.createElementNS(html, "h:div");
    const folded = document.createElement("DIV"), exact = document.createElementNS(html, "DIV");
    const attrs = document.createElement("div");
    attrs.setAttribute("data-UPPER", "raw");
    attrs.setAttributeNS(null, "data-UPPER", "exact");
    attrs.setAttribute("xlink:href", "raw");
    attrs.setAttributeNS(xlink, "xlink:href", "qualified");
    const distinct = attrs.getAttribute("data-upper") === "raw" && attrs.getAttributeNS(null, "data-UPPER") === "exact" && attrs.getAttributeNS(xlink, "href") === "qualified";
    attrs.removeAttributeNS(xlink, "href");
    return { ordinary: identity(ordinary), qualified: identity(qualified), folded: identity(folded), exact: identity(exact), distinct, rawSurvives: attrs.getAttribute("xlink:href") === "raw" && !attrs.hasAttributeNS(xlink, "href") };
  });
  const htmlNamespace = "http://www.w3.org/1999/xhtml";
  const expectedIdentities = {
    ordinary: { namespace: htmlNamespace, prefix: null, local: "h:div", interface: "HTMLUnknownElement" },
    qualified: { namespace: htmlNamespace, prefix: "h", local: "div", interface: "HTMLDivElement" },
    folded: { namespace: htmlNamespace, prefix: null, local: "div", interface: "HTMLDivElement" },
    exact: { namespace: htmlNamespace, prefix: null, local: "DIV", interface: "HTMLUnknownElement" },
    distinct: true, rawSurvives: true,
  };
  if (JSON.stringify(namespaceIdentities) !== JSON.stringify(expectedIdentities)) {
    failed += 1;
    console.log(`FAIL namespace identity: ${JSON.stringify(namespaceIdentities)}`);
  }
  console.log(`expanded identity corpus: ${expandedCases.length} cases checked`);
  const facts = await page.evaluate(() => {
    const target = new EventTarget();
    let heard = 0;
    target.addEventListener("", () => { heard += 1; });
    target.dispatchEvent(new Event(""));
    return { emptyEventHeard: heard, lowerGet: new Request("http://localhost/", { method: "get" }).method, lowerPatch: new Request("http://localhost/", { method: "patch" }).method };
  });
  if (JSON.stringify(facts) !== JSON.stringify({ emptyEventHeard: 1, lowerGet: "GET", lowerPatch: "patch" })) {
    failed += 1;
    console.log(`FAIL browser rule attribution: ${JSON.stringify(facts)}`);
  }
  await context.close();
  console.log(JSON.stringify({ corpus: options.corpus, cases: cases.length, namespaceCases: namespaceCases.length, expandedCases: expandedCases.length, expandedCorpus: options["expanded-corpus"], failed, facts }));
} finally {
  await browser.close();
}
console.log(failed === 0 ? "== names browser contract: all pass" : `== names browser contract: ${failed} failures`);
process.exit(failed === 0 ? 0 : 1);
