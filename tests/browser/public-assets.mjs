// App-owned public files are shared by ordinary SCM replay and focused browser
// contracts. Resolve exact paths under the declared directory, never aliases
// inferred from a filename or an application's route catalogue.
import fs from "node:fs";
import path from "node:path";

const types = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript", ".wasm": "application/wasm", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".jpg": "image/jpeg", ".webm": "video/webm", ".mp4": "video/mp4", ".css": "text/css", ".txt": "text/plain" };

export function publicAsset(directory, pathname) {
  if (!directory) return null;
  let decoded;
  try { decoded = decodeURIComponent(pathname); } catch { return null; }
  if (!decoded.startsWith("/") || decoded.includes("\0") || decoded.includes("\\") || decoded.split("/").includes("..")) return null;
  const root = fs.realpathSync(directory), candidate = path.resolve(root, `.${decoded}`);
  if (!fs.statSync(root).isDirectory()) throw new Error("public assets must name a directory");
  if (!candidate.startsWith(`${root}${path.sep}`)) return null;
  let file;
  try { file = fs.realpathSync(candidate); } catch (error) { if (error.code === "ENOENT" || error.code === "ENOTDIR") return null; throw error; }
  if (!file.startsWith(`${root}${path.sep}`) || !fs.statSync(file).isFile()) return null;
  return { type: types[path.extname(file).toLowerCase()] ?? "application/octet-stream", body: fs.readFileSync(file) };
}

// An unknown fetch or child-frame URL is an absent asset, not an instruction
// to mount another copy of the app. Only a top-level document navigation gets
// the replay document at a route URL.
export function isRouteNavigation(request, pathname) {
  return request.headers["sec-fetch-dest"] === "document" && (pathname.endsWith("/") || path.extname(pathname) === "");
}
