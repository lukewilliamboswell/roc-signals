// The compiled literal app uses ordinary runtime commands. These browser facts
// check details not visible through text locators: comment identity, expanded
// names, and stable keyed nodes after bindings change and rows move.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";

const opts = parseArgs(process.argv.slice(2));
const here = path.dirname(fileURLToPath(import.meta.url));
const files = { "index.html": path.join(here, "index.html"), "app.wasm": opts.wasm, ...runtimeFiles(opts.runtime) };
const server = http.createServer((request, response) => {
  const name = path.basename(new URL(request.url, "http://local").pathname) || "index.html";
  const file = files[name];
  if (!file) { response.writeHead(404); response.end(); return; }
  response.writeHead(200, { "content-type": name.endsWith(".wasm") ? "application/wasm" : name.endsWith(".html") ? "text/html" : "text/javascript" });
  response.end(fs.readFileSync(file));
});
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
const browser = await launch({ executablePath: opts.chrome });
let failures = 0;
function check(name, actual, expected) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  if (!ok) failures += 1;
  console.log(`${ok ? "ok" : "FAIL"} ${name}${ok ? "" : `: ${JSON.stringify(actual)} expected ${JSON.stringify(expected)}`}`);
}
try {
  const context = await browser.createBrowserContext();
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", error => errors.push(String(error)));
  await page.goto(`http://127.0.0.1:${server.address().port}/index.html`);
  await page.waitForFunction("window.__ready || window.__error");
  check("compiled markup mounts", await page.evaluate(() => window.__error ?? null), null);
  const initial = await page.evaluate(() => {
    const byId = id => document.querySelector(`[data-testid="${id}"]`);
    const commentData = root => {
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_COMMENT);
      const found = [];
      while (walker.nextNode()) found.push(walker.currentNode.data);
      return found;
    };
    window.__markupNodes = {
      html: byId("html-one"), svg: byId("svg-one"), foreign: byId("foreign-one"),
      comment: [...byId("html-one").childNodes].find(node => node.nodeType === Node.COMMENT_NODE),
    };
    const foreign = byId("foreign-one");
    const input = document.querySelector('[aria-label="Literal disabled"]');
    return {
      comments: commentData(document.getElementById("app")),
      html: [byId("html-one").namespaceURI, byId("html-one").localName],
      svg: [byId("svg-one").namespaceURI, byId("svg-one").localName],
      foreign: [foreign.namespaceURI, foreign.prefix, foreign.localName],
      math: [byId("literal-math").namespaceURI, byId("literal-math").localName],
      path: [byId("literal-path").getAttribute("pathLength"), byId("literal-path").pathLength.baseVal.value],
      gradients: [document.querySelector("#literal-gradient").localName, byId("svg-one").querySelector("linearGradient").localName],
      boolean: [input.disabled, input.hasAttribute("disabled"), input.getAttribute("disabled")],
      hidden: byId("literal-hidden").getAttribute("hidden"),
      text: byId("static-card").textContent,
      authoredMarks: [byId("static-card").getAttribute("data-n"), byId("static-card").getAttribute("data-h")],
    };
  });
  check("literal expanded names and Boolean presence", initial, {
    comments: ["roc:node=9", "roc:row=123", "roc:node=88", "row comment", "row comment", "roc:row=456", "roc:row=456", "region comment"],
    html: ["http://www.w3.org/1999/xhtml", "li"],
    svg: ["http://www.w3.org/2000/svg", "g"],
    foreign: ["http://www.w3.org/1999/xhtml", "h", "div"],
    math: ["http://www.w3.org/1998/Math/MathML", "math"],
    path: ["10", 10], gradients: ["linearGradient", "linearGradient"], boolean: [true, true, ""], hidden: "until-found", text: "Literal cardfixed & escaped", authoredMarks: ["app-node", "app-hole"],
  });
  check("HTML template descendants belong to inert content, not childNodes", await page.evaluate(() => {
    const template = document.querySelector('[data-testid="literal-template"]');
    return { children: template.childNodes.length, text: template.textContent, content: [...template.content.childNodes].map(node => [node.nodeType, node.nodeName, node.textContent]) };
  }), { children: 0, text: "", content: [[1, "SPAN", "inert data"], [8, "#comment", "template comment"]] });
  check("XML-parsed XHTML template also owns inert content", await page.evaluate(() => {
    const template = document.querySelector('[data-testid="xml-template"]');
    return { children: template.childNodes.length, text: template.textContent, content: [...template.content.childNodes].map(node => node.nodeType === Node.ELEMENT_NODE ? [1, node.namespaceURI, node.prefix, node.localName, node.textContent] : [node.nodeType, node.data]) };
  }), { children: 0, text: "", content: [[1, "http://www.w3.org/1999/xhtml", "h", "span", "xml data"], [8, "xml template comment"]] });
  const click = name => page.evaluate(label => [...document.querySelectorAll("button")].find(button => button.textContent === label).click(), name);
  await click("Step");
  await click("Swap rows");
  check("reactive data and keyed moves preserve nodes and comments", await page.evaluate(() => {
    const byId = id => document.querySelector(`[data-testid="${id}"]`);
    const kept = window.__markupNodes;
    return {
      same: [kept.html === byId("html-one"), kept.svg === byId("svg-one"), kept.foreign === byId("foreign-one"), kept.comment.parentNode === kept.html],
      order: [...byId("html-rows").children].map(node => node.dataset.testid),
      text: byId("literal-text").textContent,
      count: byId("literal-count").textContent,
      path: [byId("svg-one").querySelector("path").getAttribute("pathLength"), byId("svg-one").querySelector("path").pathLength.baseVal.value],
    };
  }), { same: [true, true, true, true], order: ["html-two", "html-one"], text: "second", count: "1", path: ["1", 1] });
  await click("Toggle region");
  check("scope disposal removes literal comment and element", await page.evaluate(() => document.querySelector('[data-testid="literal-region"]') === null), true);
  await click("Toggle region");
  check("scope remount rebuilds its authored comment", await page.evaluate(() => {
    const region = document.querySelector('[data-testid="literal-region"]');
    return [region.textContent, [...region.childNodes].filter(node => node.nodeType === Node.COMMENT_NODE).map(node => node.data)];
  }), ["second", ["region comment"]]);
  check("no browser errors", errors, []);
  await context.close();
} finally {
  await browser.close();
  await new Promise(resolve => server.close(resolve));
}
console.log(failures ? `== markup: ${failures} failures` : "== markup: all pass");
process.exitCode = failures ? 1 : 0;
