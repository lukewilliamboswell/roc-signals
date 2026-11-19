import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { publicAsset, isRouteNavigation } from "./public-assets.mjs";
import { resourceReply } from "./startup-media.mjs";

const root = fs.mkdtempSync(path.join(os.tmpdir(), "signals-public-assets-"));
try {
  const directory = path.join(root, "public"); fs.mkdirSync(directory);
  fs.writeFileSync(path.join(directory, "frame.html"), "<!doctype html><p>Native frame</p>");
  fs.writeFileSync(path.join(root, "outside.txt"), "outside");
  fs.symlinkSync(path.join(root, "outside.txt"), path.join(directory, "linked.txt"));
  const asset = publicAsset(directory, "/frame.html");
  assert.equal(asset.type, "text/html");
  assert.equal(asset.body.toString(), "<!doctype html><p>Native frame</p>");
  for (const pathname of ["/missing.html", "/%2e%2e/outside.txt", "/linked.txt", "/%00", "/%5c..%5coutside.txt", "/%zz"]) assert.equal(publicAsset(directory, pathname), null, pathname);
  assert.equal(isRouteNavigation({ headers: { "sec-fetch-dest": "document" } }, "/page"), true);
  for (const destination of ["iframe", "empty", "video", "image"]) assert.equal(isRouteNavigation({ headers: { "sec-fetch-dest": destination } }, "/missing-resource"), false);
  const range = resourceReply({ method: "GET", range: "bytes=3-7", ...asset });
  assert.equal(range.status, 206); assert.equal(range.body.toString(), asset.body.subarray(3, 8).toString());
  assert.equal(resourceReply({ method: "GET", range: "bytes=999-", ...asset }).status, 416);
  console.log("public assets: exact files, resource refusals, navigation-only route fallback and byte ranges passed");
} finally { fs.rmSync(root, { recursive: true, force: true }); }
