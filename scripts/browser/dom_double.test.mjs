import assert from "node:assert/strict";
import test from "node:test";
import { createDocument, HTML_NAMESPACE, SVG_NAMESPACE, ELEMENT_NODE, TEXT_NODE } from "./dom_double.mjs";

test("DOM double preserves explicit namespaces and SVG name case across parent changes", () => {
  const document = createDocument();
  const htmlParent = document.createElement("div");
  const svgParent = document.createElementNS(SVG_NAMESPACE, "svg");
  for (const tag of ["svg", "text", "path", "foreignObject", "linearGradient"]) {
    const html = document.createElement(tag);
    const svg = document.createElementNS(SVG_NAMESPACE, tag);
    assert.equal(html.namespaceURI, HTML_NAMESPACE);
    assert.equal(html.tagName, tag.toUpperCase());
    assert.equal(html.localName, tag.toLowerCase());
    for (const parent of [htmlParent, svgParent, htmlParent]) {
      parent.appendChild(svg);
      assert.equal(svg.namespaceURI, SVG_NAMESPACE);
      assert.equal(svg.tagName, tag);
      assert.equal(svg.localName, tag);
      assert.equal(svg.nodeType, ELEMENT_NODE);
    }
  }
  const text = document.createTextNode("label");
  svgParent.appendChild(text);
  assert.equal(text.nodeType, TEXT_NODE);
  assert.equal(text.textContent, "label");
});
