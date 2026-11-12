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
      button.textContent = "Copy code";
      button.setAttribute("aria-label", "Copy code sample");
      const status = document.createElement("span");
      status.className = "copy-status";
      status.setAttribute("role", "status");
      wrapper.prepend(button, status);
      button.addEventListener("click", async () => {
        try {
          await navigator.clipboard.writeText(code.textContent);
          status.textContent = "Copied";
        } catch (_) { status.textContent = "Copy failed. Select the code to copy it."; }
      });
    }
  });
})();
