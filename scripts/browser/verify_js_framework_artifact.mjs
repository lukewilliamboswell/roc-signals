#!/usr/bin/env node

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

import { SignalsRuntime, instantiateSignalsBytes } from "../../www/static/signals.mjs";
import { findAll, findNode, fireEvent, installDomDouble } from "./dom_double.mjs";

const wasmPath = process.argv[2];
if (wasmPath === undefined) {
  throw new Error("usage: verify_js_framework_artifact.mjs <app.wasm>");
}

const tag = (node, name) => node?.tagName === name.toUpperCase();
const byId = (root, id) => findNode(root, (node) => node.getAttribute?.("id") === id);
const byClass = (root, className) => findNode(root, (node) => node.className?.split(" ").includes(className));
const rows = (root) => findAll(root, (node) => tag(node, "tr"));

function click(node, label) {
  assert.ok(node, `missing ${label}`);
  fireEvent(node, "click");
}

const bytes = await readFile(wasmPath);
const { instance } = await instantiateSignalsBytes(bytes);
const root = installDomDouble();
const runtime = new SignalsRuntime(instance.exports, root);
runtime.mount();

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
const preload = byClass(root, "preloadicon");
assert.ok(tag(preload, "span"));
assert.equal(preload.getAttribute("aria-hidden"), "true");

click(byId(root, "run"), "#run");
assert.equal(rows(tbody).length, 1000);
const initialRows = rows(tbody);
const sample = initialRows[999];
assert.deepEqual(sample.childNodes.map((node) => node.tagName), ["TD", "TD", "TD", "TD"]);
assert.deepEqual(sample.childNodes.map((node) => node.className), ["col-md-1", "col-md-4", "col-md-1", "col-md-6"]);
const labelAnchor = sample.childNodes[1].childNodes[0];
const removeAnchor = sample.childNodes[2].childNodes[0];
assert.ok(tag(labelAnchor, "a"));
assert.ok(tag(removeAnchor, "a"));
const removeIcon = removeAnchor.childNodes[0];
assert.ok(tag(removeIcon, "span"));
assert.equal(removeIcon.className, "glyphicon glyphicon-remove");
assert.equal(removeIcon.getAttribute("aria-hidden"), "true");

const second = initialRows[1];
const thousandth = initialRows[998];
click(byId(root, "swaprows"), "#swaprows");
assert.equal(rows(tbody)[1], thousandth, "swap must move the existing keyed row 999 node");
assert.equal(rows(tbody)[998], second, "swap must move the existing keyed row 2 node");

const removable = rows(tbody)[1];
click(removable.childNodes[2].childNodes[0], "row remove anchor");
assert.equal(rows(tbody).length, 999);
assert.equal(removable.parentNode, null, "remove must detach the identified keyed row node");

const beforeReplacement = rows(tbody);
click(byId(root, "run"), "#run replacement");
assert.equal(rows(tbody).length, 1000);
assert.ok(beforeReplacement.every((node) => node.parentNode === null), "replacement must retire every old keyed row node");

click(byId(root, "clear"), "#clear");
assert.equal(rows(tbody).length, 0);
runtime.unmount();

console.log("verified js-framework-benchmark production DOM and keyed identity contract");
