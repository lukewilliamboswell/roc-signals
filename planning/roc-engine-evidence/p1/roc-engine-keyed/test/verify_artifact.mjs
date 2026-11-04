#!/usr/bin/env node
// Structural and keyed-identity checks for the platform-roc jfb artifact,
// mirroring scripts/browser/verify_js_framework_artifact.mjs (the current
// adapter's verifier) plus select, update-every-10th, append and allocation
// balance checks.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

import { instantiateEngineBytes, RocEngineRuntime } from "../../../../platform-roc/runtime.mjs";
import { findAll, findNode, fireEvent, installDomDouble } from "./dom_double_ext.mjs";

const wasmPath = process.argv[2];
if (wasmPath === undefined) throw new Error("usage: verify_artifact.mjs <app.wasm>");

const tag = (node, name) => node?.tagName === name.toUpperCase();
const byId = (root, id) => findNode(root, (node) => node.getAttribute?.("id") === id);
const byClass = (root, className) => findNode(root, (node) => node.className?.split(" ").includes(className));
const rows = (root) => findAll(root, (node) => tag(node, "tr"));

function click(node, label) {
  assert.ok(node, `missing ${label}`);
  fireEvent(node, "click", { bubbles: true });
}

const bytes = await readFile(wasmPath);
const { instance } = await instantiateEngineBytes(bytes);
const x = instance.exports;
const root = installDomDouble();
const runtime = new RocEngineRuntime(x, root);
try {
  runtime.mount();
} catch (error) {
  const msg = new TextDecoder().decode(new Uint8Array(x.memory.buffer, x.err_ptr(), x.err_len()));
  throw new Error(`mount failed: ${msg}`, { cause: error });
}

const container = root.childNodes[0];
assert.ok(tag(container, "div"));
assert.equal(container.className, "container");
const jumbotron = container.childNodes[0];
assert.ok(tag(jumbotron, "div"));
assert.equal(jumbotron.className, "jumbotron");
assert.ok(tag(findNode(jumbotron, (node) => tag(node, "h1")), "h1"));

for (const id of ["run", "runlots", "add", "update", "clear", "swaprows"]) {
  const button = byId(root, id);
  assert.ok(tag(button, "button"), `#${id} must be a button`);
  assert.equal(button.getAttribute("type"), "button");
  assert.ok(button.className.split(" ").includes("btn-block"));
  assert.equal(button.parentNode.className, "col-sm-6 smallpad");
}

const table = byClass(root, "test-data");
assert.ok(tag(table, "table"));
const tbody = byId(root, "tbody");
assert.ok(tag(tbody, "tbody"));
assert.equal(tbody.parentNode, table);
const preload = byClass(root, "preloadicon");
assert.ok(tag(preload, "span"));
assert.equal(preload.getAttribute("aria-hidden"), "true");

const idOf = (tr) => tr.childNodes[0].textContent;
const labelOf = (tr) => tr.childNodes[1].childNodes[0].textContent;

click(byId(root, "run"), "#run");
assert.equal(rows(tbody).length, 1000);
const initialRows = rows(tbody);
assert.deepEqual(initialRows.map(idOf), Array.from({ length: 1000 }, (_, i) => String(i + 1)));
const sample = initialRows[999];
assert.deepEqual(sample.childNodes.map((node) => node.tagName), ["TD", "TD", "TD", "TD"]);
assert.deepEqual(sample.childNodes.map((node) => node.className), ["col-md-1", "col-md-4", "col-md-1", "col-md-6"]);
const labelAnchor = sample.childNodes[1].childNodes[0];
const removeAnchor = sample.childNodes[2].childNodes[0];
assert.ok(tag(labelAnchor, "a"));
assert.ok(tag(removeAnchor, "a"));
assert.match(labelAnchor.textContent, /^[a-z]+ [a-z]+ [a-z]+$/);
const removeIcon = removeAnchor.childNodes[0];
assert.ok(tag(removeIcon, "span"));
assert.equal(removeIcon.className, "glyphicon glyphicon-remove");
assert.equal(removeIcon.getAttribute("aria-hidden"), "true");
assert.equal(sample.childNodes[3].childNodes.length, 0);

// select: only the clicked row gets "danger"; selecting another moves it.
click(initialRows[4].childNodes[1].childNodes[0], "select anchor");
assert.equal(initialRows[4].className, "danger");
assert.equal(rows(tbody).filter((tr) => tr.className === "danger").length, 1);
click(initialRows[6].childNodes[1].childNodes[0].childNodes[0] ?? initialRows[6].childNodes[1].childNodes[0], "select text");
assert.equal(initialRows[4].className, "");
assert.equal(initialRows[6].className, "danger");

// update every 10th
const before10 = initialRows.map(labelOf);
click(byId(root, "update"), "#update");
initialRows.forEach((tr, i) => assert.equal(labelOf(tr), i % 10 === 0 ? `${before10[i]} !!!` : before10[i]));
assert.equal(rows(tbody)[0], initialRows[0], "update must patch, not recreate");

const second = initialRows[1];
const thousandth = initialRows[998];
click(byId(root, "swaprows"), "#swaprows");
assert.equal(rows(tbody)[1], thousandth, "swap must move the existing keyed row 999 node");
assert.equal(rows(tbody)[998], second, "swap must move the existing keyed row 2 node");

const removable = rows(tbody)[1];
click(removable.childNodes[2].childNodes[0], "row remove anchor");
assert.equal(rows(tbody).length, 999);
assert.equal(removable.parentNode, null, "remove must detach the identified keyed row node");
click(rows(tbody)[3].childNodes[2].childNodes[0].childNodes[0], "row remove icon");
assert.equal(rows(tbody).length, 998);

click(byId(root, "add"), "#add");
assert.equal(rows(tbody).length, 1998);
assert.equal(idOf(rows(tbody).at(-1)), "2000");

const beforeReplacement = rows(tbody);
click(byId(root, "run"), "#run replacement");
assert.equal(rows(tbody).length, 1000);
assert.ok(beforeReplacement.every((node) => node.parentNode === null), "replacement must retire every old keyed row node");
assert.equal(idOf(rows(tbody)[0]), "2001");

click(byId(root, "clear"), "#clear");
assert.equal(rows(tbody).length, 0);
click(byId(root, "runlots"), "#runlots");
assert.equal(rows(tbody).length, 10000);
click(byId(root, "clear"), "#clear");
assert.equal(rows(tbody).length, 0);
runtime.unmount();
assert.equal(x.metric(4), 0n, "live Roc allocations after drop");
assert.equal(x.metric(5), 0n, "live Roc bytes after drop");

console.log("verified platform-roc js-framework-benchmark DOM, keyed identity and allocation balance");
