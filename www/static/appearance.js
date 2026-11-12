// Run before the stylesheet so a saved preference is applied before paint.
// Theme and copy controls do not depend on the app runtime or Wasm loading.
(() => {
  const key = "roc-signals-theme";
  const media = matchMedia("(prefers-color-scheme: dark)");
  const valid = value => ["light", "dark"].includes(value) ? value : "system";
  let preference = "system";
  try { preference = valid(localStorage.getItem(key)); } catch (_) {}
  const apply = () => {
    document.documentElement.dataset.theme = preference === "system" ? (media.matches ? "dark" : "light") : preference;
    document.documentElement.dataset.themePreference = preference;
    const select = document.querySelector("[data-theme-select]");
    if (select) select.value = preference;
  };
  apply();
  media.addEventListener("change", () => { if (preference === "system") apply(); });
  addEventListener("storage", event => {
    if (event.key === key || event.key === null) { preference = valid(event.newValue); apply(); }
  });
  document.addEventListener("DOMContentLoaded", () => {
    const select = document.querySelector("[data-theme-select]");
    if (select) {
      select.closest("label").hidden = false;
      select.value = preference;
      select.addEventListener("change", () => {
        preference = valid(select.value);
        try {
          if (preference === "system") localStorage.removeItem(key);
          else localStorage.setItem(key, preference);
        } catch (_) {}
        apply();
      });
    }
    for (const pre of document.querySelectorAll("pre.sample-code")) {
      pre.tabIndex = 0;
      pre.setAttribute("aria-label", "code sample");
      if (!navigator.clipboard?.writeText) continue;
      const code = pre.querySelector("code");
      const wrapper = document.createElement("div");
      wrapper.className = "code-sample";
      pre.before(wrapper);
      wrapper.append(pre);
      const button = document.createElement("button");
      button.type = "button";
      button.className = "code-copy";
      button.setAttribute("aria-label", "Copy code sample");
      button.title = "Copy code";
      const icon = document.createElementNS("http://www.w3.org/2000/svg", "svg");
      icon.setAttribute("viewBox", "0 0 24 24");
      icon.setAttribute("width", "16");
      icon.setAttribute("height", "16");
      icon.setAttribute("fill", "none");
      icon.setAttribute("stroke", "currentColor");
      icon.setAttribute("stroke-width", "1.75");
      icon.setAttribute("stroke-linecap", "round");
      icon.setAttribute("stroke-linejoin", "round");
      icon.setAttribute("aria-hidden", "true");
      icon.setAttribute("focusable", "false");
      const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
      const copyPath = "M9 9h11v11H9z M15 5V3H3v12h2";
      path.setAttribute("d", copyPath);
      icon.append(path);
      button.append(icon);
      const status = document.createElement("span");
      status.className = "copy-status";
      status.setAttribute("role", "status");
      wrapper.prepend(button, status);
      let reset;
      button.addEventListener("click", async () => {
        clearTimeout(reset);
        try {
          await navigator.clipboard.writeText(code.textContent);
          status.textContent = "Copied";
          button.title = "Copied";
          path.setAttribute("d", "m5 12 4 4L19 6");
        } catch (_) {
          status.textContent = "Copy failed. Select the code to copy it.";
          button.title = status.textContent;
          path.setAttribute("d", "M12 8v5 M12 17h.01 M12 3 2 21h20Z");
        }
        reset = setTimeout(() => {
          button.title = "Copy code";
          path.setAttribute("d", copyPath);
        }, 2500);
      });
    }
  });
})();
