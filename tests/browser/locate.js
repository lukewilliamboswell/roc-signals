// In-page locator semantics shared with test-support/SpecRunner.roc: `label` is aria-label,
// `test-id` is data-testid, `role` is the explicit role or the implicit one
// (button, a -> link, section -> region, form, dialog, h1-h6 -> heading) matched with
// the accessible name (aria-label, else text content), `text` is a text node
// whose value is exactly the string. First match in document order.
window.__loc = function (loc) {
  // The array form ["role", ROLE, NAME] / [KIND, VALUE] is accepted too.
  if (Array.isArray(loc)) loc = loc[0] === "role" ? { kind: "role", role: loc[1], name: loc[2] } : { kind: loc[0], value: loc[1] };
  const root = document.getElementById("app");
  const { kind } = loc;
  const a = kind === "role" ? loc.role : loc.value;
  const b = loc.name;
  const role = (el) => {
    const r = el.getAttribute("role");
    if (r) return r;
    const t = el.tagName.toLowerCase();
    if (t === "button") return "button";
    if (t === "a") return "link";
    if (t === "section") return "region";
    if (t === "form") return "form";
    if (t === "dialog") return "dialog";
    if (/^h[1-6]$/.test(t)) return "heading";
    return "";
  };
  const name = (el) => el.getAttribute("aria-label") || el.textContent;
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
  let n = walker.nextNode();
  while (n) {
    if (n.nodeType === 3) {
      if (kind === "text" && n.nodeValue === a) return n.parentNode;
    } else if (kind === "label" && n.getAttribute("aria-label") === a) return n;
    else if (kind === "test-id" && n.getAttribute("data-testid") === a) return n;
    else if (kind === "role" && role(n) === a && name(n) === b) return n;
    n = walker.nextNode();
  }
  return null;
};
window.__attr = function (el, name) {
  if (name === "checked") return el.checked ? "true" : "false";
  if (name === "disabled") return el.disabled ? "true" : "false";
  if (name === "value") return el.value;
  return el.getAttribute(name) ?? "";
};
