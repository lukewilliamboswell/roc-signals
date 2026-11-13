// Actual DOM measurements through the production boundary. No Wasm/app,
// factory fallback, adoption verdict or mutation by the measurement is used.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";
const options = parseArgs(process.argv.slice(2), [], ["runtime"]);
const files = { ...runtimeFiles(options.runtime), "picture-measurement-cases.mjs": fileURLToPath(new URL("./picture-measurement-cases.mjs", import.meta.url)), "picture-hash-vectors.json": fileURLToPath(new URL("../picture-hash-vectors.json", import.meta.url)) };
const server = http.createServer((request, response) => {
  const file = files[path.basename(new URL(request.url, "http://x").pathname)];
  response.writeHead(200, { "content-type": file ? "text/javascript" : "text/html" });
  response.end(file ? fs.readFileSync(file) : "<!doctype html>");
});
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
const browser = await launch({ executablePath: options.chrome });
try {
  console.log(JSON.stringify(await browser.conn.send("Browser.getVersion")));
  const page = await browser.newPage();
  await page.goto(`http://127.0.0.1:${server.address().port}/`);
  const checks = await page.evaluate(async () => {
    const original = await import("/runtime.mjs");
    const { pictureMeasurementCases, measurementEnvelope } = await import("/picture-measurement-cases.mjs");
    const build = description => {
      if (Object.hasOwn(description, "text")) return document.createTextNode(description.text);
      if (Object.hasOwn(description, "comment")) return document.createComment(description.comment);
      const [namespace, prefix, local] = description.name;
      const node = document.createElementNS(namespace || null, prefix ? `${prefix}:${local}` : local);
      for (const [[uri, prefix, local], value] of description.attrs) node.setAttributeNS(uri || null, prefix ? `${prefix}:${local}` : local, value);
      for (const child of description.children) node.appendChild(build(child));
      if (Object.hasOwn(description, "content")) for (const child of description.content) node.content.appendChild(build(child));
      return node;
    };
    const passive = async (operation, args) => {
      const guards = [
        [Document.prototype, ["createElement", "createElementNS", "createTextNode", "createComment", "createDocumentFragment", "querySelector", "querySelectorAll"]],
        [Element.prototype, ["querySelector", "querySelectorAll", "setAttribute", "setAttributeNS", "removeAttribute", "removeAttributeNS", "replaceChildren"]],
        [Node.prototype, ["appendChild", "insertBefore", "removeChild", "replaceChild"]],
      ];
      const saved = [];
      let mutations = 0;
      const observer = new MutationObserver(records => { mutations += records.length; }), pending = [args[0]];
      while (pending.length) {
        const node = pending.pop(); observer.observe(node, { subtree: true, attributes: true, childList: true, characterData: true });
        for (const child of node.childNodes) if (child.nodeType === 1) pending.push(child);
        if (node.nodeType === 1 && node.namespaceURI === "http://www.w3.org/1999/xhtml" && node.localName === "template") pending.push(node.content);
      }
      for (const [target, methods] of guards) for (const name of methods) {
        const descriptor = Object.getOwnPropertyDescriptor(target, name); saved.push([target, name, descriptor]);
        Object.defineProperty(target, name, { configurable: true, value() { throw new Error(`measurement called DOM ${name}`); } });
      }
      try { return await operation(...args); }
      finally {
        mutations += observer.takeRecords().length; observer.disconnect();
        for (const [target, name, descriptor] of saved) if (descriptor) Object.defineProperty(target, name, descriptor); else delete target[name];
        if (mutations) throw new Error("measurement changed the actual DOM");
      }
    };
    const api = { ...original, measurePicture(...args) { return passive(original.measurePicture, args); } };
    const vectors = await (await fetch("/picture-hash-vectors.json")).json();
    const result = await pictureMeasurementCases(api, build, vectors);
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg"); svg.innerHTML = "<h:div></h:div>";
    const xml = new DOMParser().parseFromString("<xmlns xmlns='urn:entry'/>", "application/xml");
    for (const existing of [svg.firstChild, xml.documentElement]) {
      const bytes = measurementEnvelope({ root_name: [existing.namespaceURI ?? "", existing.prefix ?? "", existing.localName], batch_bytes: 0, physicalCount: 0, containers: [[0xffffffff, 0, []]], logical: [], runs: [], bindings: [], scaffolds: [] });
      const measured = await api.measurePicture(existing, bytes);
      result.push([`existing factory-gap root tuple measures without reconstruction ${existing.localName}`, measured.digest.length === 32 && measured.envelope.root.local === existing.localName && measured.envelope.root.prefix === null]);
    }
    const guardControl = build({ name: ["", "", "x"], children: [], attrs: [] }); let detected = false;
    try { await passive(async target => { target.textContent = "deliberate observer control"; await Promise.resolve(); }, [guardControl]); }
    catch (error) { detected = error.message === "measurement changed the actual DOM"; }
    result.push(["mutation guard catches changes after observer microtask delivery", detected]);
    result.push(["actual DOM measurement invokes no factory, selector or mutation", true]);
    return result;
  });
  for (const [name, ok] of checks) console.log(`${ok ? "ok  " : "FAIL"} ${name}`);
  if (checks.some(([, ok]) => !ok)) process.exitCode = 1;
} finally { await browser.close(); await new Promise(resolve => server.close(resolve)); }
