// Hooks for browser/replay.mjs: replay Conduit's .scm specs in headless
// Chrome with manual effects. Setup seeds the initial URL and localStorage;
// `stub-http` / `stub-http-reject` stage the answer for the next
// `run-effect N`, which answers the N-th awaited request the app issued (in
// issue order) after checking its URL. History, title and storage
// assertions read the real browser state.
const BASE = "/roc-signals/examples-web/conduit/";
const sym = (x) => (typeof x === "object" && x !== null && !Array.isArray(x) ? x.sym : null);

function setupOf(spec) {
  const out = { location: `${BASE}#/`, storage: [], manual: false };
  for (const s of spec.setup) {
    const h = sym(s[0]);
    if (h === "initial-location") out.location = s[1];
    else if (h === "local-storage") out.storage.push([s[1], s[2]]);
    else if (h === "manual-effects") out.manual = true;
  }
  return out;
}

function opts(s) {
  const o = {};
  for (let i = 2; i < s.length; i += 1) {
    const k = sym(s[i]);
    if (k && k.startsWith(":")) {
      o[k.slice(1)] = sym(s[i + 1]) ?? s[i + 1];
      i += 1;
    }
  }
  return o;
}

let next = null;
const settle = (page) => page.evaluate(() => new Promise((r) => setTimeout(r, 0)));

export default {
  url: (port, spec) => `http://127.0.0.1:${port}${setupOf(spec).location}`,
  before: async (page, spec) => {
    next = null;
    const { storage, manual } = setupOf(spec);
    await page.evaluateOnNewDocument(
      (storage, manual) => {
        if (!sessionStorage.getItem("__seeded")) {
          for (const [k, v] of storage) localStorage.setItem(k, v);
          sessionStorage.setItem("__seeded", "1");
        }
        if (manual) window.__manualFx = true;
      },
      storage,
      manual,
    );
  },
  "stub-http": async (page, s) => {
    const o = opts(s);
    next = { url: o.url, status: Number(o.status), body: o.body ?? "", headers: [["content-type", "application/json"]] };
  },
  "stub-http-reject": async (page, s) => {
    const o = opts(s);
    // Same texts as the native harness (src/FxSpec.roc): the app shows them verbatim.
    next = o.kind === "timeout" ? { timeout: true } : { network: `Network("${o.detail}")` };
  },
  "run-effect": async (page, s) => {
    const n = Number(sym(s[1]) ?? s[1]);
    if (next === null) throw new Error(`run-effect ${n} without a staged answer`);
    const answer = next;
    next = null;
    const r = await page.evaluate(
      (n, answer) => {
        const rt = window.__rt;
        const id = rt.issued[n - 1];
        if (id === undefined) return `effect ${n} was never issued (issued ${rt.issued.length})`;
        const e = rt.live.get(id);
        if (e === undefined) return `effect ${n} (id ${id}) is not pending`;
        if (answer.url !== undefined && e.req.url !== answer.url) return `effect ${n} url ${e.req.url}, stub expects ${answer.url}`;
        rt.runEffect(id, answer);
        return null;
      },
      n,
      answer,
    );
    if (r) throw new Error(r);
    await settle(page);
  },
  "expect-pending-effects": async (page, s) => {
    const want = Number(sym(s[1]) ?? s[1]);
    const got = await page.evaluate(() => window.__rt.pendingEffects().map((r) => r.url ?? r.id));
    if (got.length !== want) throw new Error(`pending effects ${got.length} ${JSON.stringify(got)}, expected ${want}`);
  },
  "expect-current-location": async (page, s) => {
    const got = await page.evaluate(() => location.pathname + location.search + location.hash);
    if (got !== s[1]) throw new Error(`location ${got}, expected ${s[1]}`);
  },
  "expect-document-title": async (page, s) => {
    const got = await page.title();
    if (got !== s[1]) throw new Error(`title ${JSON.stringify(got)}, expected ${JSON.stringify(s[1])}`);
  },
  "expect-local-storage": async (page, s) => {
    const got = await page.evaluate((k) => localStorage.getItem(k), s[1]);
    if (got !== s[2]) throw new Error(`localStorage ${s[1]} = ${JSON.stringify(got)}, expected ${JSON.stringify(s[2])}`);
  },
  "expect-no-local-storage": async (page, s) => {
    const got = await page.evaluate((k) => localStorage.getItem(k), s[1]);
    if (got !== null) throw new Error(`localStorage ${s[1]} = ${JSON.stringify(got)}, expected absent`);
  },
  "history-back": async (page) => {
    await page.evaluate(() => new Promise((r) => {
      addEventListener("popstate", () => setTimeout(r, 0), { once: true });
      history.back();
    }));
  },
  "history-forward": async (page) => {
    await page.evaluate(() => new Promise((r) => {
      addEventListener("popstate", () => setTimeout(r, 0), { once: true });
      history.forward();
    }));
  },
  navigate: async (page, s) => {
    if (!s[1].includes("#")) {
      // Leaving the hash entirely is a cross-document navigation in a real
      // browser: the page reloads and the app mounts fresh at that URL.
      await page.evaluate((url) => location.assign(url), s[1]);
      await page.waitForFunction("window.__ready || window.__error", { timeout: 20000 });
      return;
    }
    // A user navigation within the document (hash route): a new history
    // entry and a popstate the app's subscription receives.
    await page.evaluate((url) => new Promise((r) => {
      addEventListener("popstate", () => setTimeout(r, 0), { once: true });
      location.assign(url);
    }), s[1]);
  },
};
