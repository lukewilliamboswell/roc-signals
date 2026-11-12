// The page side of `roc signals.roc serve`. The development server adds this
// script to index.html as it serves it; it is never written to the app's
// files and never part of `build`. It reloads the page when the server says
// the app was rebuilt, and shows over the page what stops the app from
// working: a failed build (sent by the server), an error the page's script
// throws (such as the runtime refusing to mount the app), and an engine
// fault the runtime reports. It only watches; it changes nothing the app or
// the runtime does, and it knows the runtime only by the line the runtime
// logs when it contains a fault.
(() => {
  const events = new EventSource("/__signals/events");
  let connection = "connecting";
  events.addEventListener("open", () => {
    // The server restarted while the page was open: load what it serves now.
    if (connection === "lost") location.reload();
    connection = "open";
  });
  events.addEventListener("error", () => {
    if (connection === "open") connection = "lost";
  });
  events.addEventListener("reload", () => location.reload());
  events.addEventListener("failed", (e) =>
    show({
      kind: "build",
      title: "The build failed",
      text: e.data,
      hint: "Fix the error and save the file. The page reloads when the app builds again.",
    }),
  );

  // An error's stack usually starts with its message; show that once.
  const describe = (error) => {
    if (!(error instanceof Error)) return String(error);
    if (!error.stack) return error.message;
    return error.stack.includes(error.message) ? error.stack : `${error.message}\n\n${error.stack}`;
  };
  window.addEventListener("error", (e) =>
    show({
      kind: "page",
      title: "The page stopped with an error",
      text: describe(e.error ?? e.message),
      hint: "The page's script threw this; when it happens while mounting, the app did not start. Fix it and save; the page reloads.",
    }),
  );
  window.addEventListener("unhandledrejection", (e) =>
    show({
      kind: "page",
      title: "The page stopped with an error",
      text: describe(e.reason),
      hint: "The page's script threw this; when it happens while mounting, the app did not start. Fix it and save; the page reloads.",
    }),
  );
  // The runtime logs every fault it contains as `roc engine fault [class]: message`.
  const consoleError = console.error.bind(console);
  console.error = (...args) => {
    consoleError(...args);
    if (typeof args[0] === "string" && args[0].startsWith("roc engine fault"))
      show({
        kind: "fault",
        title: "The app stopped with a fault",
        text: args[0],
        hint: "The engine stopped the app and names the rule it broke. Fix it and save; the page reloads.",
      });
  };

  let overlay = null;
  function show({ kind, title, text, hint }) {
    if (!document.documentElement) return;
    if (!overlay) {
      overlay = document.createElement("roc-signals-overlay");
      const root = overlay.attachShadow({ mode: "open" });
      root.innerHTML = `
        <style>
          :host { all: initial; }
          .backdrop { position: fixed; inset: 0; z-index: 2147483647; background: rgb(15 17 21 / 0.72);
            display: flex; align-items: flex-start; justify-content: center; padding: 6vh 16px; overflow: auto;
            font: 14px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif; }
          .panel { box-sizing: border-box; width: min(960px, 100%); background: #1b1e24; color: #e6e6e6;
            border-top: 4px solid #e5534b; border-radius: 6px; box-shadow: 0 12px 40px rgb(0 0 0 / 0.5); padding: 20px 24px; }
          h2 { margin: 0 0 12px; font-size: 18px; font-weight: 600; color: #ff938a; }
          pre { margin: 0; padding: 12px 14px; max-height: 60vh; overflow: auto; white-space: pre-wrap; word-break: break-word;
            background: #111318; border-radius: 4px; font: 13px/1.45 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; color: #f0f0f0; }
          .foot { display: flex; gap: 16px; align-items: center; justify-content: space-between; margin-top: 14px; }
          p { margin: 0; color: #b8bcc4; }
          button { font: inherit; color: #e6e6e6; background: #2d323b; border: 1px solid #454b56; border-radius: 4px; padding: 4px 12px; cursor: pointer; }
          button:focus-visible { outline: 2px solid #ff938a; outline-offset: 2px; }
        </style>
        <div class="backdrop">
          <div class="panel" role="alertdialog" aria-labelledby="title" aria-describedby="text">
            <h2 id="title"></h2>
            <pre id="text"></pre>
            <div class="foot"><p id="hint"></p><button type="button">Dismiss</button></div>
          </div>
        </div>`;
      root.querySelector("button").addEventListener("click", () => overlay.remove());
      document.addEventListener("keydown", (e) => {
        if (e.key === "Escape" && overlay.isConnected) overlay.remove();
      });
    }
    const root = overlay.shadowRoot;
    overlay.dataset.kind = kind;
    root.getElementById("title").textContent = title;
    root.getElementById("text").textContent = text;
    root.getElementById("hint").textContent = hint;
    if (!overlay.isConnected) document.documentElement.append(overlay);
  }
})();
