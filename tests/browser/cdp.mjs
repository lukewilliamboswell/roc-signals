// A minimal Chrome DevTools Protocol client for the browser spec runner.
//
// It launches the declared Chrome headless with a private profile, speaks CDP
// over Node's built-in WebSocket, and offers the few page operations the
// replay needs: evaluate, scripts on new documents, navigation, real mouse
// clicks and real key events. There is no npm dependency, so the browser
// tests need only the `node` and `chrome` tools that Blueprint.roc declares.
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export async function launch({ executablePath, timeoutMs = 20000 }) {
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), "roc-signals-chrome-"));
  const child = spawn(
    executablePath,
    [
      "--headless=new",
      "--no-sandbox",
      "--disable-gpu",
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-extensions",
      "--remote-debugging-port=0",
      `--user-data-dir=${profile}`,
      "about:blank",
    ],
    { stdio: ["ignore", "ignore", "pipe"] },
  );
  const wsUrl = await new Promise((resolve, reject) => {
    let buf = "";
    const timer = setTimeout(() => reject(new Error(`chrome did not start within ${timeoutMs} ms: ${buf}`)), timeoutMs);
    child.stderr.on("data", (d) => {
      buf += d.toString();
      const m = buf.match(/DevTools listening on (ws:\/\/\S+)/);
      if (m) {
        clearTimeout(timer);
        resolve(m[1]);
      }
    });
    child.on("exit", (code) => reject(new Error(`chrome exited with ${code}: ${buf}`)));
  });
  const conn = await Connection.open(wsUrl);
  return new Browser(child, conn, profile);
}

class Connection {
  static async open(url) {
    const ws = new WebSocket(url);
    await new Promise((resolve, reject) => {
      ws.onopen = resolve;
      ws.onerror = (e) => reject(new Error(`CDP connection failed: ${e.message ?? e}`));
    });
    return new Connection(ws);
  }

  constructor(ws) {
    this.ws = ws;
    this.next = 1;
    this.waiting = new Map();
    this.listeners = new Map();
    ws.onmessage = (m) => {
      const msg = JSON.parse(typeof m.data === "string" ? m.data : m.data.toString());
      if (msg.id !== undefined) {
        const w = this.waiting.get(msg.id);
        if (!w) return;
        this.waiting.delete(msg.id);
        if (msg.error) w.reject(new Error(`${w.method}: ${msg.error.message}`));
        else w.resolve(msg.result);
      } else {
        const key = `${msg.sessionId ?? ""}:${msg.method}`;
        for (const fn of this.listeners.get(key) ?? []) fn(msg.params);
      }
    };
  }

  send(method, params = {}, sessionId = undefined) {
    const id = this.next++;
    const msg = { id, method, params };
    if (sessionId) msg.sessionId = sessionId;
    return new Promise((resolve, reject) => {
      this.waiting.set(id, { resolve, reject, method });
      this.ws.send(JSON.stringify(msg));
    });
  }

  on(sessionId, method, fn) {
    const key = `${sessionId ?? ""}:${method}`;
    if (!this.listeners.has(key)) this.listeners.set(key, []);
    this.listeners.get(key).push(fn);
  }

  off(sessionId) {
    for (const key of [...this.listeners.keys()]) if (key.startsWith(`${sessionId}:`)) this.listeners.delete(key);
  }
}

class Browser {
  constructor(child, conn, profile) {
    this.child = child;
    this.conn = conn;
    this.profile = profile;
  }

  // A page in its own browser context (fresh storage, fresh instance).
  async newPage() {
    const { browserContextId } = await this.conn.send("Target.createBrowserContext");
    const { targetId } = await this.conn.send("Target.createTarget", { url: "about:blank", browserContextId });
    const { sessionId } = await this.conn.send("Target.attachToTarget", { targetId, flatten: true });
    const page = new Page(this.conn, sessionId, targetId, browserContextId);
    await page.init();
    return page;
  }

  async close() {
    try {
      await this.conn.send("Browser.close");
    } catch (_) {
      this.child.kill("SIGKILL");
    }
    await new Promise((r) => (this.child.exitCode !== null ? r() : this.child.on("exit", r)));
    fs.rmSync(this.profile, { recursive: true, force: true });
  }
}

const keyCodes = { Backspace: 8, Tab: 9, Enter: 13, Escape: 27, a: 65 };

class Page {
  constructor(conn, sessionId, targetId, contextId) {
    this.conn = conn;
    this.sessionId = sessionId;
    this.targetId = targetId;
    this.contextId = contextId;
    this.errors = [];
  }

  send(method, params) {
    return this.conn.send(method, params, this.sessionId);
  }

  async init() {
    this.conn.on(this.sessionId, "Runtime.exceptionThrown", (p) => {
      const d = p.exceptionDetails;
      this.errors.push(d.exception?.description ?? d.text);
    });
    this.conn.on(this.sessionId, "Runtime.consoleAPICalled", (p) => {
      if (p.type === "error") this.errors.push(p.args.map((a) => a.value ?? a.description ?? "").join(" "));
    });
    await this.send("Page.enable");
    await this.send("Runtime.enable");
  }

  // Run `fn` in the page with JSON-serialisable `args`; returns its
  // (awaited) JSON result.
  async evaluate(fn, ...args) {
    const expression = typeof fn === "string" ? fn : `(${fn})(...${JSON.stringify(args)})`;
    const r = await this.send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
    if (r.exceptionDetails) throw new Error(`evaluate: ${r.exceptionDetails.exception?.description ?? r.exceptionDetails.text}`);
    return r.result.value;
  }

  async evaluateOnNewDocument(fn, ...args) {
    const source = typeof fn === "string" ? fn : `(${fn})(...${JSON.stringify(args)})`;
    await this.send("Page.addScriptToEvaluateOnNewDocument", { source });
  }

  async goto(url) {
    const loaded = new Promise((r) => this.conn.on(this.sessionId, "Page.loadEventFired", r));
    const r = await this.send("Page.navigate", { url });
    if (r.errorText) throw new Error(`navigate ${url}: ${r.errorText}`);
    await loaded;
  }

  async waitForFunction(expression, { timeout = 20000 } = {}) {
    const t0 = Date.now();
    for (;;) {
      try {
        if (await this.evaluate(`!!(${expression})`)) return;
      } catch (_) {
        // A navigation in flight destroys the context; poll again.
      }
      if (Date.now() - t0 > timeout) throw new Error(`timed out waiting for ${expression}`);
      await new Promise((r) => setTimeout(r, 20));
    }
  }

  title() {
    return this.evaluate(() => document.title);
  }

  // A real left click at the centre of the element `selectorFn` returns.
  async clickAt({ x, y }) {
    await this.send("Input.dispatchMouseEvent", { type: "mouseMoved", x, y });
    await this.send("Input.dispatchMouseEvent", { type: "mousePressed", x, y, button: "left", clickCount: 1 });
    await this.send("Input.dispatchMouseEvent", { type: "mouseReleased", x, y, button: "left", clickCount: 1 });
  }

  async key(key, { modifiers = 0, commands = undefined } = {}) {
    const code = key.length === 1 ? `Key${key.toUpperCase()}` : key;
    const vk = keyCodes[key] ?? 0;
    await this.send("Input.dispatchKeyEvent", { type: "rawKeyDown", key, code, windowsVirtualKeyCode: vk, modifiers, commands });
    await this.send("Input.dispatchKeyEvent", { type: "keyUp", key, code, windowsVirtualKeyCode: vk, modifiers });
  }

  // Type text one character at a time, as key events carrying text.
  async type(text) {
    for (const ch of text) {
      await this.send("Input.dispatchKeyEvent", { type: "keyDown", key: ch, text: ch, unmodifiedText: ch });
      await this.send("Input.dispatchKeyEvent", { type: "keyUp", key: ch });
    }
  }

  async close() {
    this.conn.off(this.sessionId);
    await this.conn.send("Target.closeTarget", { targetId: this.targetId });
    await this.conn.send("Target.disposeBrowserContext", { browserContextId: this.contextId });
  }
}
