// A consumed placeholder factory must release runtime inputs. A future Reset
// handler deliberately keeps its source and must continue to work.
import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { launch } from './cdp.mjs';
import { parseArgs, runtimeFiles } from './args.mjs';

const options = parseArgs(process.argv.slice(2));
const files = { 'app.wasm': options.wasm, ...runtimeFiles(options.runtime) };
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
  for (const kind of ['direct', 'deferred', 'retained', 'deferred-retained']) {
    for (const count of [1000, 10000]) {
      const context = await browser.createBrowserContext();
      const page = await context.newPage();
      await page.goto(`http://127.0.0.1:${server.address().port}/${kind}-${count === 10000 ? 'large' : 'small'}/`);
      const result = await page.evaluate(async ({ kind, count }) => {
        const { mountRocEngineApp } = await import('./runtime.mjs');
        const runtime = await mountRocEngineApp({
          wasmUrl: 'app.wasm', root: document.getElementById('app'),
          manualEffects: true, manualIntervals: true, viewTransitions: 'off',
          environment: { seed: () => new Uint8Array(16) },
        });
        const x = runtime.x;
        const metrics = () => ({
          allocations: Number(x.metric(0)), bytes: Number(x.metric(2)),
          liveAllocations: Number(x.metric(4)), liveBytes: Number(x.metric(5)),
        });
        const value = () => runtime.root.querySelector('[data-testid="value"]')?.textContent;
        const click = label => {
          const button = [...runtime.root.querySelectorAll('button')]
            .find(element => (element.getAttribute('aria-label') ?? element.textContent) === label);
          if (!button) throw Error(`missing ${label}`);
          x.reset_metrics();
          button.click();
          if (runtime.poisoned) throw Error(runtime.poisoned.message);
          return metrics();
        };
        const activate = () => {
          if (kind.includes('deferred')) {
            if (!runtime.root.querySelector('[data-testid="waiting"]')) throw Error('fallback missing');
            runtime.runOpportunity();
          }
          if (value() !== '0') throw Error('body did not start from its runtime input');
        };
        activate();
        const before = metrics();
        const samples = [];
        for (let turn = 0; turn < 3; turn++) {
          samples.push(click('Bump'));
          if (value() !== String(turn + 1)) throw Error('wrong local write');
        }
        if (kind.includes('retained')) {
          click('Reset');
          if (value() !== '0') throw Error('future Reset lost its captured source');
        }
        click('Toggle region');
        if (value() !== undefined || !runtime.root.textContent.includes('hidden')) throw Error('body not disposed');
        const hidden = metrics();
        click('Toggle region');
        activate();
        const remountBefore = metrics();
        const remountAfter = click('Bump');
        if (value() !== '1') throw Error('remounted state was not fresh');
        if (kind.includes('retained')) {
          click('Reset');
          if (value() !== '0') throw Error('remounted Reset lost its captured source');
        }
        runtime.unmount();
        return {
          kind, count, before, samples, hidden, remountBefore, remountAfter,
          drop: [Number(x.metric(4)), Number(x.metric(5))],
        };
      }, { kind, count });
      assert.deepEqual(result.drop, [0, 0]);
      if (!kind.includes('retained')) {
        for (const sample of result.samples) {
          assert.ok(sample.liveBytes - result.before.liveBytes <= 2048,
            'consumed factory retained a runtime input after its first write');
        }
        assert.ok(result.remountAfter.liveBytes - result.remountBefore.liveBytes <= 2048,
          'remounted factory retained a runtime input');
      }
      results.push(result);
      console.log(JSON.stringify(result));
      await context.close();
    }
  }
} finally {
  await browser.close();
  await new Promise(resolve => server.close(resolve));
}
for (const kind of ['direct', 'deferred', 'retained', 'deferred-retained']) {
  const pair = results.filter(result => result.kind === kind);
  assert.ok(Math.abs(pair[1].hidden.liveBytes - pair[0].hidden.liveBytes) <= 2048,
    'disposing a body retained its payload');
}
console.log('placeholder factories: runtime payloads released after activation/disposal, future Reset preserved, fresh remount and zero teardown');
