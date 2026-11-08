// The `serve` task: serve a directory over HTTP on localhost, with the MIME
// types the site needs (`application/wasm` lets browsers stream-compile the
// apps).
//
//     blueprint run serve [-- [DIR] [--port N]]
//
// Without DIR it serves `dist/` under `/roc-signals/`, the path the site is
// published at, so build it with `blueprint run site -- --base-url
// http://127.0.0.1:8000/roc-signals`. A DIR is served at the root.
import { createServer } from "node:http";
import { readFile, stat } from "node:fs/promises";
import { extname, join, normalize, resolve, sep } from "node:path";

const types = {
  ".html": "text/html; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".wasm": "application/wasm",
  ".txt": "text/plain; charset=utf-8",
  ".md": "text/markdown; charset=utf-8",
  ".pdf": "application/pdf",
  ".ttf": "font/ttf",
};

const args = process.argv.slice(2).filter((a) => a !== "--");
let port = 8000;
let dir = null;
for (let i = 0; i < args.length; i += 1) {
  if (args[i] === "--port") port = Number(args[++i]);
  else dir = args[i];
}
const prefix = dir === null ? "/roc-signals" : "";
dir ??= "dist";
const root = resolve(dir);

// Resolve a request path inside `root`; a directory serves its index.html.
async function file(urlPath) {
  const path0 = decodeURIComponent(urlPath.split("?")[0]);
  if (!path0.startsWith(prefix + "/")) return null;
  const rel = normalize(path0.slice(prefix.length));
  let path = join(root, rel);
  if (path !== root && !path.startsWith(root + sep)) return null;
  const info = await stat(path).catch(() => null);
  if (info?.isDirectory()) path = join(path, "index.html");
  return readFile(path).then((body) => ({ path, body })).catch(() => null);
}

createServer(async (req, res) => {
  const found = await file(req.url ?? "/");
  if (!found) {
    res.writeHead(404, { "content-type": "text/plain" }).end("not found\n");
    return;
  }
  res.writeHead(200, { "content-type": types[extname(found.path)] ?? "application/octet-stream" });
  res.end(found.body);
}).listen(port, "127.0.0.1", () => {
  console.log(`serving ${root} at http://127.0.0.1:${port}${prefix}/`);
});
