// Fixed total-site controls isolate ready-index costs from ordinary root metadata.
import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { launch } from './cdp.mjs';
import { parseArgs, runtimeFiles } from './args.mjs';

const options = parseArgs(process.argv.slice(2));
const files = { 'app.wasm': options.wasm, ...runtimeFiles(options.runtime) };
const cases = [
  { id: 'queue-small', waiting: 10, total: 1000, kind: 'queue' },
  { id: 'queue-large', waiting: 1000, total: 1000, kind: 'queue' },
  { id: 'when-small', waiting: 0, total: 10, kind: 'when' },
  { id: 'when-large', waiting: 0, total: 1000, kind: 'when' },
  { id: 'queue-short', waiting: 10, total: 10, kind: 'queue' },
];
const server = http.createServer((request, response) => {
  const url = new URL(request.url, 'http://local');
  if (url.pathname.endsWith('/')) {
    response.writeHead(200, { 'content-type': 'text/html' });
    response.end('<!doctype html><div id="app"></div>');
    return;
  }
  const name = path.basename(url.pathname);
  if (!files[name]) { response.writeHead(404); response.end(); return; }
  response.writeHead(200, { 'content-type': name.endsWith('.wasm') ? 'application/wasm' : 'text/javascript' });
  response.end(fs.readFileSync(files[name]));
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const browser = await launch({ executablePath: options.chrome });
const results = [];
try {
  for (const fixture of cases) {
    const context = await browser.createBrowserContext();
    const page = await context.newPage();
    await page.goto(`http://127.0.0.1:${server.address().port}/${fixture.id}/`);
    const result = await page.evaluate(async fixture => {
      const { mountRocEngineApp } = await import('./runtime.mjs');
      const runtime = await mountRocEngineApp({
        wasmUrl: 'app.wasm', root: document.getElementById('app'),
        manualEffects: true, manualIntervals: true, viewTransitions: 'off',
      });
      const x = runtime.x;
      const metrics = () => ({
        allocations: Number(x.metric(0)), bytes: Number(x.metric(2)), liveBytes: Number(x.metric(5)),
        arms: Number(x.metric(69)), cancels: Number(x.metric(70)),
        delivered: Number(x.metric(71)), stale: Number(x.metric(72)),
      });
      const mount = metrics();
      const toggle = runtime.root.querySelector('button');
      const turn = action => {
        x.reset_metrics();
        action();
        if (runtime.poisoned) throw Error(runtime.poisoned.message);
        return metrics();
      };
      const append = [turn(() => toggle.click())];
      const remove = [turn(() => toggle.click())];
      for (let round = 0; round < 8; round++) {
        append.push(turn(() => toggle.click()));
        remove.push(turn(() => toggle.click()));
      }
      const opportunities = fixture.kind === 'queue'
        ? Array.from({ length: 3 }, () => turn(() => runtime.runOpportunity())) : [];
      const walker = document.createTreeWalker(runtime.root, NodeFilter.SHOW_TEXT);
      let active = 0, waiting = 0;
      while (walker.nextNode()) {
        if (walker.currentNode.data === 'active') active++;
        if (walker.currentNode.data === 'waiting') waiting++;
      }
      if (active !== (fixture.kind === 'queue' ? 3 : 0) || waiting !== fixture.total - active) {
        throw Error('queue fixture made the wrong visible progress');
      }
      runtime.unmount();
      return {
        ...fixture, mount, append, remove, opportunities, visible: { active, waiting },
        drop: [Number(x.metric(4)), Number(x.metric(5))],
      };
    }, fixture);
    assert.deepEqual(result.drop, [0, 0]);
    results.push(result);
    console.log(JSON.stringify(result));
    await context.close();
  }
} finally {
  await browser.close();
  await new Promise(resolve => server.close(resolve));
}

// U64 paths have at most 64 forks. These generous constant ceilings reject the
// reproduced 59.2 KiB whole-entry-list copy at Q=1000 while allowing small changes
// in bounded path metadata. The ordinary when routes report the existing
// root/site cost separately; construction is excluded from every turn region.
const small = results.find(result => result.id === 'queue-small');
const large = results.find(result => result.id === 'queue-large');
for (const result of [small, large]) {
  for (const later of result.append.slice(1)) {
    assert.ok(later.bytes <= result.append[0].bytes + 2048, 'remove/reappend copied the live ready index');
  }
}
for (const operation of ['append', 'remove', 'opportunities']) {
  for (let turn = 0; turn < small[operation].length; turn++) {
    assert.ok(large[operation][turn].bytes - small[operation][turn].bytes <= 32768,
      `${operation} metadata grew beyond the fixed U64-path metadata allowance`);
  }
}
console.log('placeholder queue: bounded first/later metadata at 10/1000 ready owners, independent total-site controls, exact progress and zero teardown allocations');
