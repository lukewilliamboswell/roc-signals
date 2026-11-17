// Imported content is checked in Chrome directly; the paired SCM specs keep
// it opaque. Real compiled updates cover equality, templates and disposal.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";

const options = parseArgs(process.argv.slice(2), ["runner"]);
if (options.runner) {
  for (const route of ["/", "/empty"]) {
    const rendered = spawnSync(options.runner, ["--prerender", route, "--template", "tests/apps/prerender/index.html"], { encoding: "utf8" });
    assert.equal(rendered.status, 1, `picture ${route} must refuse opaque contents`);
    assert.match(rendered.stderr, /unsafe HTML.*even with empty contents/);
    assert.equal(rendered.stdout, "", "a refused picture publishes no partial document");
  }
}
const files = { "index.html": "tests/browser/index.html", "app.wasm": options.wasm, "locate.js": "tests/browser/locate.js", ...runtimeFiles(options.runtime) };
const server = http.createServer((request, response) => {
  const name = path.basename(new URL(request.url, "http://local").pathname) || "index.html";
  const file = files[name];
  response.writeHead(file ? 200 : 404, { "content-type": name.endsWith(".wasm") ? "application/wasm" : name.endsWith(".html") ? "text/html" : "text/javascript" });
  response.end(file ? fs.readFileSync(file) : "");
});
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
const browser = await launch({ executablePath: options.chrome });
try {
  const page = await browser.newPage();
  await page.goto(`http://127.0.0.1:${server.address().port}/index.html`);
  await page.waitForFunction("window.__ready || window.__error");
  assert.equal(await page.evaluate(() => window.__error ?? null), null);
  await page.evaluate(source => { (0, eval)(source); }, fs.readFileSync("tests/browser/locate.js", "utf8"));
  const results = await page.evaluate(async () => {
    const results = [];
    const check = (name, ok) => results.push([name, !!ok]);
    const byId = id => document.querySelector(`[data-testid="${id}"]`);
    const button = label => [...document.querySelectorAll("button")].find(element => element.textContent === label);
    const source = document.querySelector('[aria-label="HTML source"]');
    const setHtml = html => { source.value = html; source.dispatchEvent(new Event("input", { bubbles: true })); };
    const opaque = byId("opaque"), heading = opaque.querySelector("h2");
    check("browser parses headings and table cells", heading.textContent === "Imported heading" && opaque.querySelector("td").textContent === "Imported cell");
    check("imported metadata-like attributes confer no routing", byId("forged").__rn === undefined && byId("forged").getAttribute("__rn") === "999");
    check("spec locators exclude imported nodes", window.__loc(["test-id", "forged"]) === null);
    let opaqueTextFailed = false;
    try { window.__specText(opaque); } catch (error) { opaqueTextFailed = error.message.includes("opaque"); }
    check("spec text observation fails explicitly", opaqueTextFailed);
    opaque.removeAttribute("aria-label");
    let opaqueNameFailed = false;
    try { window.__loc(["role", "region", "Imported heading"]); } catch (error) { opaqueNameFailed = error.message.includes("opaque"); }
    check("descendant-derived names fail explicitly", opaqueNameFailed);
    opaque.setAttribute("aria-label", "Imported");
    button("Equal HTML").click();
    check("equal HTML retains imported node identity", opaque.querySelector("h2") === heading);
    const row = byId("a"), child = row.firstChild;
    button("Reverse rows").click();
    check("template row moves retain imported descendants", byId("a") === row && row.firstChild === child && byId("b").textContent === "b");
    byId("forged").dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, ctrlKey: true, altKey: true, shiftKey: true, metaKey: true }));
    check("opaque clicks capture authored nearest link facts", byId("clicks").textContent === '{ alt: True, ctrl: True, link: Link({ download: True, href: "../raw", target: "_blank" }), meta: True, shift: True }');
    button("No link").click();
    const noLink = byId("clicks").textContent;
    const outsideLink = document.createElement("a");
    outsideLink.href = "#outside";
    outsideLink.addEventListener("click", event => event.preventDefault());
    document.body.append(outsideLink);
    outsideLink.append(window.__rt.root);
    button("No link").click();
    check("nearest-link capture stops at the mount", byId("clicks").textContent === noLink);
    outsideLink.replaceWith(window.__rt.root);
    // Hold the existing bounded ingress while two occurrences arrive. The
    // first replaces HTML; the second must not reach its surviving wrapper.
    window.__rt.busy = true;
    button("Replace HTML").click();
    byId("forged").dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
    window.__rt.busy = false;
    window.__rt.drainQueue();
    check("queued detached imported targets are dropped", byId("clicks").textContent === noLink && !heading.isConnected && opaque.textContent === "Replaced");
    setHtml("<span>queued document key target</span>");
    const keyTarget = opaque.firstChild;
    const beforeKeys = Number(byId("moves").textContent);
    const documentKey = () => new KeyboardEvent("keydown", { key: "F8", code: "F8", bubbles: true, cancelable: true });
    window.__rt.busy = true;
    button("Replace HTML").click();
    keyTarget.dispatchEvent(documentKey());
    window.__rt.busy = false;
    window.__rt.drainQueue();
    check("queued document keys drop detached imported targets", Number(byId("moves").textContent) === beforeKeys);
    document.body.dispatchEvent(documentKey());
    check("document shortcuts still hear targets outside the mount", Number(byId("moves").textContent) === beforeKeys + 1);
    setHtml("<span>first report target</span>");
    const firstReportTarget = opaque.firstChild;
    const beforeMoves = Number(byId("moves").textContent);
    const move = () => new PointerEvent("pointermove", { bubbles: true, pointerId: 7, pointerType: "mouse", isPrimary: true, button: -1, buttons: 0 });
    firstReportTarget.dispatchEvent(move());
    firstReportTarget.remove();
    const newestReportTarget = document.createElement("span");
    opaque.append(newestReportTarget);
    newestReportTarget.dispatchEvent(move());
    window.__rt.drainQueue(true);
    check("a replaced report retains its newest imported target", Number(byId("moves").textContent) === beforeMoves + 1 && window.__rt.reportsReplaced > 0);
    window.__importedInline = 0; window.__importedScript = 0; window.__importedConnected = 0; window.__importedDisconnected = 0;
    customElements.define("html-contract-element", class extends HTMLElement {
      connectedCallback() { window.__importedConnected++; }
      disconnectedCallback() { window.__importedDisconnected++; }
    });
    setHtml('<script>window.__importedScript++</script><html-contract-element></html-contract-element><button onclick="window.__importedInline++">inline</button><a href="javascript:window.__rawDestination=true">raw</a>');
    opaque.querySelector("button").click();
    check("inline handlers execute, nested scripts stay inert, custom elements connect", window.__importedInline === 1 && window.__importedScript === 0 && window.__importedConnected === 1);
    check("raw destinations retain deliberate scripting", opaque.querySelector("a").getAttribute("href") === "javascript:window.__rawDestination=true");
    setHtml('<svg><a xmlns:xlink="http://www.w3.org/1999/xlink" href="/svg" xlink:href="/fallback" target="frame"><text>SVG link</text></a></svg>');
    check("replacement disconnects browser custom elements", window.__importedDisconnected === 1);
    opaque.querySelector("text").dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
    check("SVG href precedes XLink in click facts", byId("clicks").textContent.includes('href: "/svg", target: "frame"'));
    opaque.querySelector("a").removeAttribute("href");
    opaque.querySelector("text").dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
    check("SVG XLink fallback is captured", byId("clicks").textContent.includes('href: "/fallback"'));
    button("Empty HTML").click();
    check("empty content preserves wrapper", opaque.isConnected && opaque.childNodes.length === 0);
    setHtml("<div><span>imported grandchildren</span></div>");
    Object.defineProperty(opaque.firstChild, "firstChild", { get() { throw new Error("runtime traversed imported descendants"); } });
    button("Toggle HTML").click();
    check("scope disposal removes wrapper without traversing imported descendants", !opaque.isConnected && !window.__rt.poisoned);
    const rt = window.__rt;
    for (const malformed of [[], [0], [16, 0], [0, 2], [0, 0, 0], [0, 1], [0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 2], [0, 1, 1, 0, 0, 0, 255, 0, 0, 0, 0, 0]]) {
      const declaring = byId("checked");
      rt.dispatch(declaring.__rn, declaring.__h.click.h, Uint8Array.from(malformed), declaring);
      check(`malformed click ${JSON.stringify(malformed)} is a routed contract fault`, rt.poisoned?.class === "contract" && rt.poisoned.message.includes("malformed click payload at site"));
      await rt.recover();
    }
    // A browser URL supplies the independently selected scheme. Cases with
    // invalid hosts are intentionally absent: Link checks no host grammar.
    const destinationInput = document.querySelector('[aria-label="Destination"]');
    for (const authored of ["", "../path", "//example.test", "/a:b", "?q=a:b", "#part", "\u0000 HTTPS://example.test \u001f", "mail\nto:a@b", "TEL:+123", "JaVa\tScRiPt:alert(1)", "data:text/html,x", "file:///tmp/a", "blob:https://example.test/id", "x+y.z:refused", "é:relative"]) {
      // Supply exact event text, including LF/CR which a native text-input
      // setter normalizes before it reaches an app. The checked-link policy
      // itself receives authored data independently of control normalization.
      Object.defineProperty(destinationInput, "value", { value: authored, configurable: true, writable: true });
      destinationInput.dispatchEvent(new Event("input", { bubbles: true }));
      const protocol = new URL(authored, "https://base.test/a/").protocol;
      const accepted = ["http:", "https:", "mailto:", "tel:"].includes(protocol);
      const attribute = byId("checked").getAttribute("href");
      check(`browser scheme differential ${JSON.stringify(authored)}`, accepted ? attribute === authored : attribute === null);
    }
    rt.unmount();
    check("teardown balances engine allocations", window.__rt.x.metric(4) === 0n && window.__rt.x.metric(5) === 0n);
    return results;
  });
  for (const [name, ok] of results) { console.log(`${ok ? "ok" : "FAIL"} ${name}`); assert.ok(ok, name); }
} finally {
  await browser.close();
  await new Promise(resolve => server.close(resolve));
}
