import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { readFile, mkdtemp, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";

const [roc, archive] = process.argv.slice(2);
const artifact = await readFile(archive);
const directory = await mkdtemp(join(tmpdir(), "signals-engine-package-"));
const route = `/0.8.0-rc1/${basename(archive)}`;
let downloads = 0;
const server = createServer((request, response) => {
  if (request.url !== route) {
    response.writeHead(404).end();
    return;
  }
  downloads++;
  response.writeHead(200, { "Content-Length": artifact.length }).end(artifact);
});

function run(args) {
  return new Promise((resolve, reject) => {
    const child = spawn(roc, args, {
      cwd: directory,
      env: { ...process.env, XDG_CACHE_HOME: join(directory, "cache") },
    });
    let output = "";
    child.stdout.on("data", (data) => (output += data));
    child.stderr.on("data", (data) => (output += data));
    child.once("error", reject);
    child.once("close", (code) => resolve({ code, output }));
  });
}

try {
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const url = `http://127.0.0.1:${server.address().port}${route}`;
  for (const name of ["platform.roc", "main.roc", "Fixture.roc", "worker.roc"]) {
    const source = await readFile(new URL(`engine/${name}`, import.meta.url), "utf8");
    await writeFile(join(directory, name), source.replace("https://example.invalid/0.8.0-rc1/ENGINE.tar.zst", url));
  }
  for (const command of ["check", "test"]) {
    const result = await run([command, "--no-cache", "main.roc"]);
    assert.equal(result.code, 0, result.output);
  }
  const worker = await run(["run", "--no-cache", "worker.roc"]);
  assert.equal(worker.code, 0, worker.output);
  assert.ok(downloads > 0, "Roc must download the engine artifact");
  const source = await readFile(join(directory, "main.roc"), "utf8");
  await writeFile(join(directory, "private.roc"), source.replace("import engine.Engine", "import engine.Core\nimport engine.Engine"));
  const refused = await run(["check", "--no-cache", "private.roc"]);
  assert.notEqual(refused.code, 0);
  assert.match(refused.output, /package module is private/i);
  console.log("engine package: external platform and app passed");
} finally {
  server.close();
  await rm(directory, { recursive: true, force: true });
}
