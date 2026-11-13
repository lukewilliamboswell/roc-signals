// A minimal Chrome DevTools Protocol client for the browser tests.
//
// It launches the declared Chrome headless with a private profile, speaks CDP
// over Node's built-in WebSocket, and offers the small part of the familiar
// puppeteer page API the tests use: browser contexts and pages, evaluate with
// element handles as arguments, scripts on new documents, navigation, waiting,
// real mouse clicks and real key events, and raw CDP sessions. There is no
// npm dependency, so the browser tests need only the `node` and `chrome`
// tools that Blueprint.roc declares.
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
    { stdio: ["ignore", "ignore", "pipe"], detached: true },
  );
  // Chrome never outlives this process: whatever ends it (a normal exit, a
  // thrown error, a failed test's process.exit, or SIGINT/SIGTERM from a
  // timeout), the browser is killed and its profile removed. Only SIGKILL of
  // node itself cannot be caught; the scripts' callers use SIGTERM.
  const cleanup = () => {
    if (child.exitCode === null && child.signalCode === null) {
      try {
        process.kill(-child.pid, "SIGKILL");
      } catch (_) {
        child.kill("SIGKILL");
      }
    }
    fs.rmSync(profile, { recursive: true, force: true });
  };
  process.on("exit", cleanup);
  for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) {
    process.on(sig, () => {
      cleanup();
      process.exit(128 + (sig === "SIGINT" ? 2 : sig === "SIGTERM" ? 15 : 1));
    });
  }
  process.on("uncaughtException", (e) => {
    console.error(e);
    cleanup();
    process.exit(1);
  });
  process.on("unhandledRejection", (e) => {
    console.error(e);
    cleanup();
    process.exit(1);
  });
  const wsUrl = await new Promise((resolve, reject) => {
    let buf = "";
    const timer = setTimeout(() => reject(new Error(`chrome did not start within ${timeoutMs} ms: ${buf}`)), timeoutMs);
    timer.unref();
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
    // A protocol call that never answers fails the test instead of hanging it.
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.waiting.delete(id);
        reject(new Error(`${method}: no answer within 120 s`));
      }, 120000);
      this.waiting.set(id, {
        resolve: (v) => (clearTimeout(timer), resolve(v)),
        reject: (e) => (clearTimeout(timer), reject(e)),
        method,
      });
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

  // An isolated context: fresh storage, fresh pages.
  async createBrowserContext() {
    const { browserContextId } = await this.conn.send("Target.createBrowserContext");
    const conn = this.conn;
    const pages = [];
    return {
      newPage: async () => {
        const p = await openPage(conn, browserContextId);
        pages.push(p);
        return p;
      },
      close: async () => {
        for (const p of pages) await p.closeTarget();
        await conn.send("Target.disposeBrowserContext", { browserContextId });
      },
    };
  }

  // A page in its own browser context; `page.close()` disposes both.
  async newPage() {
    const ctx = await this.createBrowserContext();
    const page = await ctx.newPage();
    page.close = () => ctx.close();
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

async function openPage(conn, browserContextId) {
  const { targetId } = await conn.send("Target.createTarget", { url: "about:blank", browserContextId });
  const { sessionId } = await conn.send("Target.attachToTarget", { targetId, flatten: true });
  const page = new Page(conn, sessionId, targetId);
  await page.init();
  return page;
}

// Key definitions for the named keys the tests press.
const keyDefs = {
  Backspace: { code: "Backspace", vk: 8 },
  Tab: { code: "Tab", vk: 9 },
  Enter: { code: "Enter", vk: 13, text: "\r" },
  Escape: { code: "Escape", vk: 27 },
  End: { code: "End", vk: 35 },
  Home: { code: "Home", vk: 36 },
  ArrowLeft: { code: "ArrowLeft", vk: 37 },
  ArrowUp: { code: "ArrowUp", vk: 38 },
  ArrowRight: { code: "ArrowRight", vk: 39 },
  ArrowDown: { code: "ArrowDown", vk: 40 },
  Delete: { code: "Delete", vk: 46 },
  Shift: { code: "ShiftLeft", vk: 16, modifier: 8 },
  Control: { code: "ControlLeft", vk: 17, modifier: 2 },
  Alt: { code: "AltLeft", vk: 18, modifier: 1 },
};

class Keyboard {
  constructor(page) {
    this.page = page;
    this.modifiers = 0;
  }

  def(key) {
    if (keyDefs[key]) return keyDefs[key];
    if (key.length === 1) {
      const up = key.toUpperCase();
      const letter = /[A-Z]/.test(up);
      return { code: letter ? `Key${up}` : "", vk: letter ? up.charCodeAt(0) : 0, text: key };
    }
    throw new Error(`unknown key ${key}`);
  }

  async down(key) {
    const d = this.def(key);
    if (d.modifier) this.modifiers |= d.modifier;
    // With Control held a letter is a command, not text (Ctrl+A selects all).
    const ctrl = (this.modifiers & 2) !== 0;
    const text = d.text && !ctrl ? d.text : undefined;
    const commands = ctrl && key.toLowerCase() === "a" ? ["selectAll"] : undefined;
    await this.page.send("Input.dispatchKeyEvent", {
      type: text ? "keyDown" : "rawKeyDown",
      key,
      code: d.code,
      windowsVirtualKeyCode: d.vk,
      modifiers: this.modifiers,
      text,
      unmodifiedText: text,
      commands,
    });
  }

  async up(key) {
    const d = this.def(key);
    if (d.modifier) this.modifiers &= ~d.modifier;
    await this.page.send("Input.dispatchKeyEvent", { type: "keyUp", key, code: d.code, windowsVirtualKeyCode: d.vk, modifiers: this.modifiers });
  }

  async press(key) {
    await this.down(key);
    await this.up(key);
  }

  async type(text) {
    for (const ch of text) await this.press(ch);
  }
}

class ElementHandle {
  constructor(page, objectId) {
    this.page = page;
    this.objectId = objectId;
  }

  asElement() {
    return this;
  }

  evaluate(fn, ...args) {
    return this.page.callOn(fn, [this, ...args]);
  }

  async focus() {
    await this.evaluate((e) => e.focus());
  }

  async click() {
    const box = await this.evaluate((e) => {
      e.scrollIntoView({ block: "center", inline: "center" });
      const r = e.getBoundingClientRect();
      return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
    });
    await this.page.clickAt(box);
  }

  async type(text) {
    await this.focus();
    await this.page.keyboard.type(text);
  }
}

class Page {
  constructor(conn, sessionId, targetId) {
    this.conn = conn;
    this.sessionId = sessionId;
    this.targetId = targetId;
    this.errors = [];
    this.handlers = { pageerror: [], console: [] };
    this.keyboard = new Keyboard(this);
  }

  send(method, params) {
    return this.conn.send(method, params, this.sessionId);
  }

  on(event, fn) {
    this.handlers[event].push(fn);
  }

  async init() {
    this.conn.on(this.sessionId, "Runtime.exceptionThrown", (p) => {
      const d = p.exceptionDetails;
      const text = d.exception?.description ?? d.text;
      this.errors.push(text);
      for (const fn of this.handlers.pageerror) fn(new Error(text));
    });
    this.conn.on(this.sessionId, "Runtime.consoleAPICalled", (p) => {
      const text = p.args.map((a) => a.value ?? a.description ?? "").join(" ");
      if (p.type === "error") this.errors.push(text);
      const msg = { type: () => p.type, text: () => text };
      for (const fn of this.handlers.console) fn(msg);
    });
    await this.send("Page.enable");
    await this.send("Runtime.enable");
  }

  // Call `fn` in the page with `args`, which may be element handles; returns
  // the JSON value, or a handle when `handle` is set.
  async callOn(fn, args, handle = false) {
    const g = await this.send("Runtime.evaluate", { expression: "globalThis" });
    const r = await this.send("Runtime.callFunctionOn", {
      // A value that does not serialise (a cycle, a DOM node) comes back as
      // undefined, as with puppeteer, instead of failing the call.
      functionDeclaration: handle
        ? fn.toString()
        : `async function (...a) { const r = await (${fn.toString()}).apply(this, a); try { return r === undefined ? undefined : JSON.parse(JSON.stringify(r)); } catch (_) { return undefined; } }`,
      objectId: g.result.objectId,
      arguments: args.map((a) => (a instanceof ElementHandle ? { objectId: a.objectId } : { value: a })),
      awaitPromise: true,
      returnByValue: !handle,
    });
    if (r.exceptionDetails) throw new Error(`evaluate: ${r.exceptionDetails.exception?.description ?? r.exceptionDetails.text}`);
    if (!handle) return r.result.value;
    return r.result.objectId ? new ElementHandle(this, r.result.objectId) : null;
  }

  async evaluate(fn, ...args) {
    if (typeof fn !== "string") return this.callOn(fn, args);
    const r = await this.send("Runtime.evaluate", { expression: fn, awaitPromise: true, returnByValue: true });
    if (r.exceptionDetails) throw new Error(`evaluate: ${r.exceptionDetails.exception?.description ?? r.exceptionDetails.text}`);
    return r.result.value;
  }

  evaluateHandle(fn, ...args) {
    return this.callOn(fn, args, true);
  }

  $(selector) {
    return this.callOn((s) => document.querySelector(s), [selector], true);
  }

  async $eval(selector, fn, ...args) {
    const h = await this.$(selector);
    if (!h) throw new Error(`no element ${selector}`);
    return h.evaluate(fn, ...args);
  }

  async click(selector) {
    const h = await this.$(selector);
    if (!h) throw new Error(`no element ${selector}`);
    await h.click();
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

  // Poll until `fn` (a function with `args`, or an expression) is truthy.
  async waitForFunction(fn, { timeout = 20000 } = {}, ...args) {
    const t0 = Date.now();
    for (;;) {
      try {
        if (await (typeof fn === "string" ? this.evaluate(`!!(${fn})`) : this.callOn(fn, args))) return;
      } catch (_) {
        // A navigation in flight destroys the context; poll again.
      }
      if (Date.now() - t0 > timeout) throw new Error(`timed out waiting for ${fn}`);
      await new Promise((r) => setTimeout(r, 20));
    }
  }

  waitForSelector(selector, opts) {
    return this.waitForFunction((s) => document.querySelector(s) !== null, opts, selector);
  }

  title() {
    return this.evaluate(() => document.title);
  }

  // A CDP session on this page, for protocol calls such as IME input.
  async createCDPSession() {
    return { send: (method, params) => this.send(method, params) };
  }

  async clickAt({ x, y }) {
    await this.send("Input.dispatchMouseEvent", { type: "mouseMoved", x, y });
    await this.send("Input.dispatchMouseEvent", { type: "mousePressed", x, y, button: "left", clickCount: 1 });
    await this.send("Input.dispatchMouseEvent", { type: "mouseReleased", x, y, button: "left", clickCount: 1 });
  }

  // The parser supplies the US key table, so replay and native input share
  // physical codes and the requirement to spell Shift explicitly.
  async pressSpec(chord, keyTable) {
    const definition = keyTable.find((entry) => entry.key === chord.key && entry.code === chord.code);
    if (!definition) throw new Error(`press has no parser key definition for ${JSON.stringify(chord.key)}`);
    const modifiers = (chord.alt ? 1 : 0) | (chord.ctrl ? 2 : 0) | (chord.meta ? 4 : 0) | (chord.shift ? 8 : 0);
    const text = !chord.ctrl && !chord.meta && (chord.key.length === 1 ? chord.key : chord.key === "Enter" ? "\r" : undefined);
    const vk = chord.code.startsWith("Key") ? chord.code.charCodeAt(3) : chord.code.startsWith("Digit") ? chord.code.charCodeAt(5) : undefined;
    const fields = { key: chord.key, code: chord.code, modifiers, ...(vk === undefined ? {} : { windowsVirtualKeyCode: vk }) };
    await this.send("Input.dispatchKeyEvent", { ...fields, type: text ? "keyDown" : "rawKeyDown", ...(text ? { text, unmodifiedText: text } : {}) });
    await this.send("Input.dispatchKeyEvent", { ...fields, type: "keyUp" });
  }

  // `key` and `type` for the spec replay: one key press, and typed text.
  async key(key, { modifiers = 0, commands = undefined } = {}) {
    const d = this.keyboard.def(key);
    await this.send("Input.dispatchKeyEvent", { type: "rawKeyDown", key, code: d.code, windowsVirtualKeyCode: d.vk, modifiers, commands });
    await this.send("Input.dispatchKeyEvent", { type: "keyUp", key, code: d.code, windowsVirtualKeyCode: d.vk, modifiers });
  }

  type(text) {
    return this.keyboard.type(text);
  }

  // Replace the focused control's selection with `text` as one real input
  // event (`insertText`), as Playwright's `fill` does.
  insertText(text) {
    return this.send("Input.insertText", { text });
  }

  async closeTarget() {
    this.conn.off(this.sessionId);
    await this.conn.send("Target.closeTarget", { targetId: this.targetId });
  }
}
