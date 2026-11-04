// Adds the few DOM members the platform-roc runtime uses (cloneNode,
// firstChild, nextSibling) to the repository's dependency-free DOM double.
// It only adds members, so the current engine's runtime behaves exactly as it
// does on the unmodified double.
import { FakeElement, FakeText } from "../../../../scripts/browser/dom_double.mjs";

export * from "../../../../scripts/browser/dom_double.mjs";

const FakeNode = Object.getPrototypeOf(FakeElement.prototype);

if (!Object.prototype.hasOwnProperty.call(FakeNode, "firstChild")) {
  Object.defineProperty(FakeNode, "firstChild", {
    get() {
      return this.childNodes[0] ?? null;
    },
  });
  Object.defineProperty(FakeNode, "nextSibling", {
    get() {
      const parent = this.parentNode;
      if (parent === null) return null;
      const siblings = parent.childNodes;
      return siblings[siblings.indexOf(this) + 1] ?? null;
    },
  });
  FakeElement.prototype.cloneNode = function cloneNode(deep) {
    const copy = new FakeElement(this.localName, this.namespaceURI);
    for (const [name, value] of this.attributes) copy.attributes.set(name, value);
    if (deep) for (const child of this.childNodes) copy.appendChild(child.cloneNode(true));
    return copy;
  };
  FakeText.prototype.cloneNode = function cloneNode() {
    return new FakeText(this.nodeValue);
  };
}
