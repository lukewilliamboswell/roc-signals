// reading-list-journey.mjs --wasm APP.wasm --runtime runtime.mjs --chrome PATH
// -- the Reading List example in headless Chrome with its own page
// (examples/reading-list/index.html) and its own port handlers
// (examples/reading-list/ports.mjs) against real IndexedDB and a real
// BroadcastChannel: what the specs, which stand in for the handlers, cannot
// show. Books added and moved are in the database as the port's JSON says;
// a reload finds them again; a second tab sees the first's changes and the
// first the second's; a record the app does not understand is reported as
// the typed error, not a fault; and nothing a handler does reaches the
// console as a fault.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { launch } from "./cdp.mjs";
import { parseArgs, runtimeFiles } from "./args.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const example = path.resolve(here, "../../examples/reading-list");
const opts = parseArgs(process.argv.slice(2));
const files = {
  "index.html": path.join(example, "index.html"),
  "ports.mjs": path.join(example, "ports.mjs"),
  ...runtimeFiles(opts.runtime),
  "app.wasm": opts.wasm,
};
const server = http.createServer((req, res) => {
  const u = new URL(req.url, "http://x");
  const f = u.pathname.endsWith("/") ? files["index.html"] : files[path.basename(u.pathname)];
  if (!f) {
    res.writeHead(404);
    res.end();
    return;
  }
  res.writeHead(200, { "content-type": f.endsWith(".wasm") ? "application/wasm" : f.endsWith("html") ? "text/html" : "text/javascript" });
  res.end(fs.readFileSync(f));
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
// The runtime reads the browser seed and clock; the port only stores Roc data.
const base = `http://127.0.0.1:${server.address().port}/reading-list/`;
const browser = await launch({ executablePath: opts.chrome });

let failures = 0;
const check = (name, got, want) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  if (!ok) failures += 1;
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok ? "" : `: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`}`);
};

// Runs in every page before its scripts: every console error (a port fault
// or a runtime fault is reported there) is recorded, and small helpers drive
// the app through its accessible names, as a user would.
function install() {
  window.__errors = [];
  const error = console.error.bind(console);
  console.error = (...args) => {
    window.__errors.push(args.map(String).join(" "));
    error(...args);
  };
  // An element by its accessible name: its aria-label, or a button's text.
  const named = (name) => document.querySelector(`[aria-label="${CSS.escape(name)}"]`) ?? [...document.querySelectorAll("button")].find((b) => b.textContent === name) ?? null;
  window.__status = () => document.querySelector("[data-testid=status]")?.textContent ?? "";
  window.__note = () => document.querySelector("[data-testid=note]")?.textContent ?? "";
  window.__has = (name) => named(name) !== null;
  window.__titles = () => [...document.querySelectorAll('[aria-label="Books"] li')].map((li) => li.getAttribute("aria-label"));
  window.__click = (name) => {
    const el = named(name);
    if (el === null) throw new Error(`no element named ${name}`);
    el.click();
  };
  window.__add = (title, author) => {
    for (const [label, value] of [
      ["Title", title],
      ["Author", author],
    ]) {
      const input = named(label);
      input.value = value;
      input.dispatchEvent(new Event("input", { bubbles: true }));
    }
    named("Add book").click();
  };
  // The database as the handlers left it, read with IndexedDB directly.
  window.__stored = () =>
    new Promise((resolve, reject) => {
      const open = indexedDB.open("roc-signals.example/reading-list");
      open.onerror = () => reject(open.error);
      open.onsuccess = () => {
        const all = open.result.transaction("books").objectStore("books").getAll();
        all.onsuccess = () => {
          open.result.close();
          resolve(all.result);
        };
      };
    });
  window.__write = (record) =>
    new Promise((resolve, reject) => {
      const open = indexedDB.open("roc-signals.example/reading-list");
      open.onerror = () => reject(open.error);
      open.onsuccess = () => {
        const tx = open.result.transaction("books", "readwrite");
        if (record.delete) tx.objectStore("books").delete(record.delete);
        else tx.objectStore("books").put(record);
        tx.oncomplete = () => {
          open.result.close();
          resolve();
        };
      };
    });
}

const ctx = await browser.createBrowserContext();
const pageErrors = [];

async function open() {
  const page = await ctx.newPage();
  page.on("pageerror", (e) => pageErrors.push(String(e)));
  await page.evaluateOnNewDocument(install);
  await page.goto(base);
  return page;
}

async function reload(page) {
  await page.goto(base);
}

// Wait until `fn(...args)` in the page equals `want`, then check it.
async function until(page, name, fn, want, ...args) {
  try {
    await page.waitForFunction(async (src, want, args) => JSON.stringify(await eval(src)(...args)) === JSON.stringify(want), { timeout: 10000 }, String(fn), want, args);
  } catch (_) {
    // reported below with what the page shows
  }
  check(name, await page.evaluate((src, args) => eval(src)(...args), String(fn), args), want);
}

const status = () => window.__status();
const titles = () => window.__titles();
const has = (name) => window.__has(name);

// One tab: an empty store, then two books added and one moved, stored as
// the port's JSON says.
const first = await open();
await until(first, "a new store opens empty", status, "No books yet. Add the first one above.");
await first.evaluate(() => window.__add("Dune", "Frank Herbert"));
await until(first, "Roc mints and stamps the first book", status, "1 book");
await first.evaluate(() => window.__add("Piranesi", "Susanna Clarke"));
await until(first, "and the second, newest first", titles, ["Piranesi", "Dune"]);
await first.evaluate(() => window.__click("Start reading Dune"));
await until(first, "moving a book shows at once", has, true, "Finish Dune");
await until(
  first,
  "IndexedDB holds each book as the port's JSON: a tag's name for the shelf, an I64 as signed digits, Roc's seeded id",
  async () =>
    (await window.__stored())
      .map((b) => ({ title: b.title, author: b.author, shelf: b.shelf, added: /^-?[0-9]+$/.test(b.added_ms), id: /^b-[0-9a-f]{16}$/.test(b.id) }))
      .sort((a, b) => a.title.localeCompare(b.title)),
  [
    { title: "Dune", author: "Frank Herbert", shelf: "Reading", added: true, id: true },
    { title: "Piranesi", author: "Susanna Clarke", shelf: "WantToRead", added: true, id: true },
  ],
);

// A reload finds them again.
await reload(first);
await until(first, "after a reload the books are still there", titles, ["Piranesi", "Dune"]);
await until(first, "and Dune is still being read", has, true, "Finish Dune");

// A second tab sees the same books; a change in either shows in the other.
const second = await open();
await until(second, "a second tab opens the same shelf", titles, ["Piranesi", "Dune"]);
await second.evaluate(() => window.__click("Remove Piranesi"));
await until(second, "the second tab removes a book", titles, ["Dune"]);
await until(first, "and the first tab sees it go", titles, ["Dune"]);
await first.evaluate(() => window.__add("Middlemarch", "George Eliot"));
await until(first, "the first tab adds a book", titles, ["Middlemarch", "Dune"]);
await until(second, "and the second tab sees it come", titles, ["Middlemarch", "Dune"]);
await second.evaluate(() => window.__click("Finish Dune"));
await until(first, "a move in the second tab shows in the first", has, true, "Read Dune again");
await first.evaluate(() => window.__click("Remove finished books"));
await until(first, "removing every finished book", titles, ["Middlemarch"]);
await until(second, "reaches the second tab too", titles, ["Middlemarch"]);
await until(first, "and the store", async () => (await window.__stored()).map((b) => b.title), ["Middlemarch"]);

// A record the app does not understand (written by something else) is the
// typed Undecodable error, shown by the app; removing it recovers.
await first.evaluate(() => window.__write({ id: "stray", title: "Stray", author: "", shelf: "Abandoned", added_ms: "1" }));
await reload(first);
await until(
  first,
  "a record of another shape is reported, not a fault",
  status,
  'Your shelf could not be read: it holds something this app does not understand (port "roc-signals.example/reading-list/load": unknown tag "Abandoned").',
);
await first.evaluate(() => window.__write({ delete: "stray" }));
await reload(first);
await until(first, "without it the shelf reads again", titles, ["Middlemarch"]);

check(
  "no console errors or page errors in either tab",
  {
    first: await first.evaluate(() => window.__errors),
    second: await second.evaluate(() => window.__errors),
    page: pageErrors,
  },
  { first: [], second: [], page: [] },
);

await ctx.close();
await browser.close();
server.close();
console.log(failures === 0 ? "== reading-list journey: all pass" : `== reading-list journey: ${failures} failures`);
process.exit(failures === 0 ? 0 : 1);
