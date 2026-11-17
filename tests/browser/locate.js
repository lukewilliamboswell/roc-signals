// In-page locator semantics shared with platform/SpecRunner.roc: `label` is aria-label,
// `test-id` is data-testid, `role` is the explicit role or the implicit one
// (button, a -> link, section -> region, form, dialog, h1-h6 -> heading) matched with
// the accessible name (aria-label, else text content), `text` is a text node
// whose value is exactly the string, and names the element holding it. First
// match in document order.
window.__specOpaque = function (element) {
  if (element.__opaqueHtml) return true;
  const walker = document.createTreeWalker(element, NodeFilter.SHOW_ELEMENT);
  let node;
  while ((node = walker.nextNode())) if (node.__opaqueHtml) return true;
  return false;
};
window.__specText = function (element) {
  if (window.__specOpaque(element)) throw new Error("unsupported observation: unsafe HTML text is opaque to specs");
  return element.textContent;
};
window.__loc = function (loc) {
  // The array form ["role", ROLE, NAME] / [KIND, VALUE] is accepted too.
  if (Array.isArray(loc)) loc = loc[0] === "role" ? { kind: "role", role: loc[1], name: loc[2] } : { kind: loc[0], value: loc[1] };
  const root = document.getElementById("app");
  const { kind } = loc;
  const a = kind === "role" ? loc.role : loc.value;
  const b = loc.name;
  // Implicit roles are HTML elements by their exact local name, and an SVG
  // `a`, as `SpecRunner.implicit_role` reads them: `tagName` would fold the
  // case of an HTML element's name and ignore its namespace.
  const role = (el) => {
    const r = el.getAttributeNS(null, "role");
    if (r) return r;
    if (el.namespaceURI === "http://www.w3.org/2000/svg" && el.localName === "a") return "link";
    if (el.namespaceURI !== "http://www.w3.org/1999/xhtml") return "";
    const t = el.localName;
    if (t === "button") return "button";
    if (t === "a") return "link";
    if (t === "section") return "region";
    if (t === "form") return "form";
    if (t === "dialog") return "dialog";
    if (/^h[1-6]$/.test(t)) return "heading";
    return "";
  };
  const name = (el) => el.getAttributeNS(null, "aria-label") || window.__specText(el);
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
    acceptNode(node) { return node.parentNode?.__opaqueHtml ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT; },
  });
  let n = walker.nextNode();
  while (n) {
    if (n.nodeType === 3) {
      if (kind === "text" && n.nodeValue === a) return n.parentNode;
    } else if (kind === "label" && n.getAttributeNS(null, "aria-label") === a) return n;
    else if (kind === "test-id" && n.getAttributeNS(null, "data-testid") === a) return n;
    else if (kind === "role" && role(n) === a && name(n) === b) return n;
    n = walker.nextNode();
  }
  return null;
};
