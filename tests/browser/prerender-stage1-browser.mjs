// Native first-frame production plus the real runtime's stage-1 replacement.
// Build inputs are supplied by the controller; this script launches no compiler.
import http from "node:http";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";

const options = parseArgs(process.argv.slice(2), ["runner", "no-init-runner", "template"]);
if (!options.runner || !options["no-init-runner"]) throw new Error("--runner and --no-init-runner are required");
const template = options.template ?? fileURLToPath(new URL("../apps/prerender/index.html", import.meta.url));
const files = runtimeFiles(options.runtime);
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "roc-signals-prerender-"));
let failures = 0;
const check = (pass, name, detail = "") => {
  if (!pass) failures += 1;
  console.log(`${pass ? "ok  " : "FAIL"} ${name}${pass ? "" : ` ${detail}`}`);
};
const run = (runner, args) => spawnSync(runner, args, { encoding: "utf8", timeout: 30000, maxBuffer: 134217728 });
const decoded = (result) => {
  if (result.error || result.status !== 0) throw new Error(`runner failed: ${result.error ?? result.stderr}`);
  return JSON.parse(result.stdout);
};
let browser;
let server;
let releaseWasm;
const wasmReady = new Promise((resolve) => { releaseWasm = resolve; });
try {
  const input = "/nested?filter=open#list";
  const route = decoded(run(options.runner, ["--picture-path", input]));
  check(route.protocol === "roc-signals/picture-path/v1" && route.url === input && route.path === "nested/index.html", "native route projection preserves explicit boot input and separates output path");
  const aliases = ["/nested?filter=closed#list", "/nested#other"].map((url) => decoded(run(options.runner, ["--picture-path", url])).path);
  check(aliases.every((name) => name === route.path), "query and fragment variants identify the same collision location");
  for (const unsafe of ["ftp://example.test/path", "/safe%2Fescape", "/CON.txt", "/a//b", "/COM%C2%B9.log"]) {
    const result = run(options.runner, ["--picture-path", unsafe]);
    check(result.status === 1 && result.stdout === "" && result.stderr.trim().length > 0, `native refuses unsafe static route ${unsafe}`);
  }
  const noInit = decoded(run(options["no-init-runner"], ["--picture-path", "/safe"]));
  check(noInit.path === "safe/index.html", "path projection does not call an app init which would crash");
  const wouldInit = run(options["no-init-runner"], ["--prerender", "/safe", "--template", template]);
  check(wouldInit.status === 70 && `${wouldInit.stdout}${wouldInit.stderr}`.includes("picture-path unexpectedly called init"), "the same no-init control really fails when prerender calls init");

  const picture = decoded(run(options.runner, ["--prerender", input, "--template", template]));
  check(picture.protocol === "roc-signals/prerender/v1" && picture.url === input && picture.path === route.path && Array.isArray(picture.metadata) && picture.metadata.length === 0, "stage 1 returns a full page without fake adoption metadata");
  const source = fs.readFileSync(template, "utf8");
  check(picture.page.startsWith(source.slice(0, source.indexOf('<div id="app"'))) && picture.page.endsWith(source.slice(source.indexOf("<!--host-after-->"))), "native preserves host bytes before and after its parser-selected root");
  const authoredTemplate = path.join(scratch, "authored-inert.html");
  fs.writeFileSync(authoredTemplate, source.replace("data-roc-picture", 'data-roc-picture inert="author"'));
  const authoredPicture = decoded(run(options.runner, ["--prerender", input, "--template", authoredTemplate]));
  const reservedTemplate = path.join(scratch, "reserved-inert.html");
  fs.writeFileSync(reservedTemplate, source.replace("data-roc-picture", 'data-roc-picture data-roc-picture-inert="added"'));
  const reserved = run(options["no-init-runner"], ["--prerender", "/", "--template", reservedTemplate]);
  check(reserved.status === 1 && reserved.stdout === "" && reserved.stderr.includes("reserved"), "a preexisting producer ownership fact is rejected before init");
  const missing = path.join(scratch, "missing-root.html");
  fs.writeFileSync(missing, source.replace(" data-roc-picture", ""));
  const refusal = run(options.runner, ["--prerender", "/", "--template", missing]);
  check(refusal.status === 1 && refusal.stdout === "" && refusal.stderr.includes("exactly one"), "a template without one explicit opt-in is refused without partial page output");

  server = http.createServer(async (request, response) => {
    const name = path.basename(new URL(request.url, "http://x").pathname);
    if (name === "app.wasm") {
      await wasmReady;
      response.writeHead(200, { "content-type": "application/wasm" });
      response.end(fs.readFileSync(options.wasm));
    } else if (files[name]) {
      response.writeHead(200, { "content-type": "text/javascript" });
      response.end(fs.readFileSync(files[name]));
    } else if (name === "authored") {
      response.writeHead(200, { "content-type": "text/html" });
      response.end(authoredPicture.page);
    } else if (name === "nested") {
      response.writeHead(200, { "content-type": "text/html" });
      response.end(picture.page);
    } else { response.writeHead(404); response.end(); }
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  browser = await launch({ executablePath: options.chrome });
  const page = await browser.newPage();
  const errors = [];
  page.on("pageerror", (error) => errors.push(String(error)));
  await page.goto(`http://127.0.0.1:${server.address().port}/nested`);
  const before = await page.evaluate(() => {
    const root = document.getElementById("app");
    window.pictureButton = root.querySelector("button");
    window.pictureButton.focus();
    const comments = [];
    const walk = document.createTreeWalker(root, NodeFilter.SHOW_COMMENT);
    for (let comment; (comment = walk.nextNode());) comments.push(comment.data);
    return { inert: root.hasAttribute("inert"), producerInert: root.getAttribute("data-roc-picture-inert"), count: root.querySelector('[data-testid="count"]').textContent, value: root.querySelector("input").value, title: root.querySelector('[data-testid="asset-looking-data"]').getAttribute("title"), comments, focusSuppressed: document.activeElement !== window.pictureButton };
  });
  check(JSON.stringify(before) === JSON.stringify({ inert: true, producerInert: "added", count: "0", value: "<&\"'", title: "app.wasm", comments: ["roc:node=9", "roc:node=9"], focusSuppressed: true }), "the actual parsed first frame paints before Wasm and remains inert", JSON.stringify(before));
  releaseWasm();
  await page.evaluate(async () => { window.runtime = await window.mounted; });
  const after = await page.evaluate(() => {
    const root = document.getElementById("app");
    const replaced = root.querySelector("button") !== window.pictureButton;
    [...root.querySelectorAll("button")].find((button) => button.textContent === "Increment").click();
    return { inert: root.hasAttribute("inert"), producerInert: root.hasAttribute("data-roc-picture-inert"), replaced, count: root.querySelector('[data-testid="count"]').textContent, poisoned: window.runtime.poisoned };
  });
  check(!after.inert && !after.producerInert && after.replaced && after.count === "1" && after.poisoned === null, "stage 1 replaces the picture, lifts inert and dispatches through the real engine", JSON.stringify(after));
  check(errors.length === 0, "no page errors", JSON.stringify(errors));
  await page.evaluate(() => window.runtime.unmount());
  const authoredPage = await browser.newPage();
  await authoredPage.goto(`http://127.0.0.1:${server.address().port}/authored`);
  const authored = await authoredPage.evaluate(async () => {
    const runtime = await window.mounted;
    const root = document.getElementById("app"); root.querySelector("button").focus();
    const facts = { inert: root.getAttribute("inert"), producerInert: root.hasAttribute("data-roc-picture-inert"), focusSuppressed: document.activeElement !== root.querySelector("button"), poisoned: runtime.poisoned };
    runtime.unmount(); return facts;
  });
  check(authored.inert === "author" && !authored.producerInert && authored.focusSuppressed && authored.poisoned === null, "real producer and runtime preserve authored inert text after replacement", JSON.stringify(authored));
} finally {
  releaseWasm();
  if (browser) await browser.close();
  if (server) await new Promise((resolve) => server.close(resolve));
  fs.rmSync(scratch, { recursive: true, force: true });
}
process.exitCode = failures ? 1 : 0;
