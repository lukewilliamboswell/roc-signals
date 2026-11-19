// The real native producer, including a view whose init must never run during
// catalogue inspection. Expectations are authored independently of Core/Dom.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

const options = {};
for (let at = 2; at < process.argv.length; at += 2) options[process.argv[at].replace(/^--/, "")] = process.argv[at + 1];
for (const name of ["runner", "query-runner", "unsafe-runner", "template"]) assert.ok(options[name], `--${name} is required`);
const invoke = (runner, args, status = 0) => {
  const result = spawnSync(path.resolve(runner), args, { encoding: "utf8", timeout: 30000, maxBuffer: 32 * 1024 * 1024 });
  assert.ifError(result.error);
  assert.equal(result.signal, null);
  assert.equal(result.status, status, result.stdout + result.stderr);
  return result;
};
const catalogue = JSON.parse(invoke(options.runner, ["--startup-catalogue"]).stdout);
assert.deepEqual(catalogue, { protocol: "roc-signals/startup-catalogue/v1", entries: ["/", "/tasks/"], root: [0, 0, 0, 0, 0, 3, 0, 0, 0, 100, 105, 118], fallback: 0xffffffff });
const query = invoke(options["query-runner"], ["--startup-catalogue"]);
assert.deepEqual(JSON.parse(query.stdout).entries, ["/"]);
assert.equal(query.stderr, "");
const temp = fs.mkdtempSync(path.join(os.tmpdir(), "signals-startup-producer-"));
try {
  for (const [entry, route, label] of [[0, "/", "home"], [1, "/tasks/", "tasks"]]) {
    const answer = invoke(options.runner, ["--prerender", route, "--template", options.template, "--build-token", "receipt"]);
    const frame = JSON.parse(answer.stdout);
    assert.equal(frame.protocol, "roc-signals/prerender/v1");
    assert.equal(frame.path, entry === 0 ? "index.html" : "tasks/index.html");
    assert.ok(frame.page.includes(`data-roc-frame="1:${entry}:receipt"`));
    assert.ok(frame.page.includes('title="app.wasm"'));
    assert.ok(frame.page.includes(`>cold ${label}</p>`));
    assert.ok(frame.page.includes(">waiting</p>"));
    assert.ok(!frame.page.includes(`>active ${label}</p>`) && !frame.page.includes(">refused</p>"));
    assert.ok(!/<div id="app"[^>]*\binert(?:=|[ >])/.test(frame.page));
    assert.deepEqual(frame.metadata, []);
    const story = path.join(temp, `entry-${entry}.scm`);
    fs.writeFileSync(story, `(test "entry ${entry}" (setup (initial-location "${route}?live=1#part")) (steps (expect-text (test-id "phase") "active ${label}") (expect-text (test-id "refusal") "refused") (expect-pending-effects 0) (click (label "Increment")) (expect-text (test-id "count") "1")))`);
    assert.equal(JSON.parse(invoke(options.runner, [story]).stdout).status, "passed");
  }
  for (const route of ["/unknown/", "/tasks/?live=1", "/tasks/#part"]) {
    assert.match(invoke(options.runner, ["--prerender", route, "--template", options.template, "--build-token", "receipt"], 1).stderr, /exactly name a declared concrete entry/);
  }
  assert.match(invoke(options.runner, ["--prerender", "/", "--template", options.template], 1).stderr, /--build-token/);
  invoke(options.runner, ["--prerender", "/", "--template", options.template, "--build-token", "bad:token"], 2);
  invoke(options.runner, ["--startup-catalogue", "unexpected.scm"], 2);
  const wrongRoot = path.join(temp, "wrong-root.html");
  fs.writeFileSync(wrongRoot, '<!doctype html><html><head><title>Wrong</title></head><body><section data-roc-picture></section></body></html>');
  assert.match(invoke(options["query-runner"], ["--prerender", "/", "--template", wrongRoot, "--build-token", "receipt"], 1).stderr, /template mount root differs/);
  assert.match(invoke(options["query-runner"], ["--prerender", "/", "--template", options.template, "--build-token", "receipt"], 70).stderr, /startup query unexpectedly initialized/);
  const plain = path.join(temp, "plain.scm");
  fs.writeFileSync(plain, '(test "ordinary construction" (steps (expect-text (text "plain construction") "plain construction")))');
  assert.equal(JSON.parse(invoke(options["unsafe-runner"], [plain]).stdout).status, "passed");
  assert.match(invoke(options["unsafe-runner"], ["--prerender", "/", "--template", options.template, "--build-token", "receipt"], 70).stderr, /annotated startup refuses custom-element upgrade via is/);
  console.log("startup producer: declaration-only catalogue, exact entries, cold Self/refusal capture, acknowledgement and root/token refusals");
} finally {
  fs.rmSync(temp, { recursive: true, force: true });
}
