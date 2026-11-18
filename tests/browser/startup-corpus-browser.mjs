// One actual native Dom renderer and the same compiled typed app in Wasm.
// The default provider is the repository's Chrome driver. Supplying the
// Playwright module path runs this identical corpus in all three engines.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { launch } from './cdp.mjs';
import { parseArgs, runtimeFiles } from './args.mjs';
const options = parseArgs(process.argv.slice(2), ['runner', 'template', 'playwright', 'browser', 'output'], ['runner', 'template', 'wasm', 'runtime']);
const pages = new Map();
for (const route of ['/', '/second/']) {
  const result = spawnSync(path.resolve(options.runner), ['--prerender', route, '--template', path.resolve(options.template), '--build-token', 'corpus'], { encoding: 'utf8', maxBuffer: 20 * 1024 * 1024 });
  if (result.error || result.status !== 0) throw new Error(`native producer ${route}: ${result.error?.message ?? result.stderr ?? result.stdout}`);
  const response = JSON.parse(result.stdout);
  assert.equal(response.protocol, 'roc-signals/prerender/v1');
  assert.equal(response.url, route);
  assert.ok(response.page.includes('data-roc-frame='));
  pages.set(route, response.page);
  if (options.output) { fs.mkdirSync(options.output, { recursive: true }); fs.writeFileSync(path.join(options.output, route === '/' ? 'first.json' : 'second.json'), result.stdout); }
}
const files = runtimeFiles(options.runtime);
const resourceCounts = new Map();
const resources = new Map([
  ['/startup-image.svg', ['image/svg+xml', fs.readFileSync(new URL('../../www/samples/startup/public/landscape.svg', import.meta.url))]],
  ['/startup.webm', ['video/webm', fs.readFileSync(new URL('./fixtures/startup.webm', import.meta.url))]],
  ['/startup-frame', ['text/html', Buffer.from('<!doctype html><title>Retained native document</title><p>Native frame</p>')]],
]);
const server = http.createServer((request, response) => {
  const route = new URL(request.url, 'http://local').pathname;
  if (resources.has(route)) {
    resourceCounts.set(route, (resourceCounts.get(route) ?? 0) + 1);
    const [type, body] = resources.get(route);
    response.writeHead(200, { 'content-type': type, 'content-length': body.length, 'cache-control': 'no-store' }); response.end(body); return;
  }
  if (route === '/app.wasm') { response.setHeader('content-type', 'application/wasm'); response.end(fs.readFileSync(options.wasm)); return; }
  const file = files[path.basename(route)];
  response.setHeader('content-type', file ? 'text/javascript' : 'text/html');
  response.end(file ? fs.readFileSync(file) : pages.get(route) ?? '<!doctype html>');
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const reports = [];
try {
  let providers;
  if (options.playwright) {
    const playwright = await import(pathToFileURL(path.resolve(options.playwright)));
    const selected = options.browser ? [options.browser] : ['chromium', 'firefox', 'webkit'];
    if (selected.some(name => !['chromium', 'firefox', 'webkit'].includes(name))) throw new Error('browser must name chromium, firefox or webkit');
    providers = selected.map(name => ({ name, open: () => playwright[name].launch({ headless: true }) }));
  } else providers = [{ name: 'chrome', open: () => launch({ executablePath: options.chrome }) }];
  for (const provider of providers) {
    const browser = await provider.open();
    try {
      const version = typeof browser.version === 'function' ? browser.version() : (await browser.conn.send('Browser.getVersion')).product;
      for (const [entry, route] of ['/', '/second/'].entries()) {
        const page = await browser.newPage();
        try {
          await page.goto(`http://127.0.0.1:${server.address().port}${route}`);
          await page.waitForFunction(() => typeof window.__start === 'function');
          await page.evaluate(async () => { const video = document.querySelector('[data-testid="video"]'); video.muted = true; await video.play(); });
          await page.waitForFunction(() => { const video = document.querySelector('[data-testid="video"]'), image = document.querySelector('[data-testid="image"]'); return image.complete && image.naturalWidth > 0 && video.buffered.length > 0 && video.buffered.end(video.buffered.length - 1) >= video.duration - .01; });
          await page.evaluate(() => new Promise(resolve => setTimeout(resolve, 200)));
          const cold = await page.evaluate(({ entry }) => {
            const root = document.getElementById('app');
            const query = id => root.querySelector(`[data-testid="${id}"]`);
            const ids = ['route', 'selection', 'image', 'frame', 'video', 'counter', 'environment', 'increment', 'textarea', 'no-match', 'option-first', 'option-second', 'authored-inert', 'template', 'svg', 'svg-link', 'foreign-html', 'math', 'row-a', 'row-b', 'tail-a', 'tail-b', 'waiting'];
            window.__kept = new Map(ids.map(id => [id, query(id)]));
            window.__content = query('template').content.querySelector('[data-testid="content-span"]');
            window.__resources = { document: query('frame').contentDocument, videoTime: query('video').currentTime, sourceWrites: 0 };
            for (const id of ['image', 'frame', 'video']) { const element = query(id), original = element.setAttributeNS; element.setAttributeNS = function(namespace, name, value) { if (name === 'src') window.__resources.sourceWrites++; return original.call(this, namespace, name, value); }; }
            const selected = query('selection').firstChild;
            document.getSelection().setBaseAndExtent(selected, entry ? 7 : 1, selected, entry ? 1 : 7);
            // An embedded entry selects its fixed route, even at another live URL.
            history.replaceState(null, '', '/unlisted?client=1#before');
            return { frame: root.getAttribute('data-roc-frame'), route: query('route').textContent, counter: query('counter').textContent, environment: query('environment').textContent, rootInert: root.inert, buttonInert: query('increment').inert, textareaInert: query('textarea').inert, authored: query('authored-inert').getAttribute('inert'), optionCount: query('no-match').options.length, selectedIndex: query('no-match').selectedIndex, selection: document.getSelection().toString() };
          }, { entry });
          const requestsBefore = Object.fromEntries(resourceCounts);
          assert.equal(cold.frame, `1:${entry}:corpus`);
          assert.equal(cold.route, entry ? 'second' : 'first');
          assert.equal(cold.counter, '0'); assert.equal(cold.environment, 'waiting');
          assert.equal(cold.rootInert, false); assert.equal(cold.buttonInert, true); assert.equal(cold.textareaInert, true);
          assert.equal(cold.authored, 'author-inert'); assert.equal(cold.optionCount, 3); assert.equal(cold.selectedIndex, 2); assert.equal(cold.selection, 'lphabe');
          const committed = await page.evaluate(async () => {
            const runtime = await window.__start(), root = document.getElementById('app');
            const query = id => root.querySelector(`[data-testid="${id}"]`);
            const selection = document.getSelection();
            return { fault: runtime.poisoned, retained: [...window.__kept].every(([id, node]) => query(id) === node), content: query('template').content.firstElementChild === window.__content, counter: query('counter').textContent, environment: query('environment').textContent, buttonInert: query('increment').inert, textareaInert: query('textarea').inert, authored: query('authored-inert').getAttribute('inert'), textarea: query('textarea').value, optionCount: query('no-match').options.length, selectedIndex: query('no-match').selectedIndex, logicalSelected: query('option-first').getAttribute('selected'), checked: query('authored-inert').checked, partitions: [...query('selection').childNodes].map(node => node.data), selection: selection.toString(), anchor: selection.anchorOffset, focus: selection.focusOffset, svg: query('svg').namespaceURI, math: query('math').namespaceURI, html: query('foreign-html').namespaceURI, xlink: query('svg-link').getAttributeNS('http://www.w3.org/1999/xlink', 'href'), templateText: query('template').textContent, tailA: query('tail-a').textContent, tailB: query('tail-b').textContent, released: runtime.startup === null };
          });
          assert.equal(committed.fault, null); assert.equal(committed.retained, true); assert.equal(committed.content, true);
          assert.equal(committed.counter, '1'); assert.equal(committed.environment, 'waiting');
          assert.equal(committed.buttonInert, false); assert.equal(committed.textareaInert, false); assert.equal(committed.authored, 'author-inert');
          assert.equal(committed.textarea, 'live text'); assert.equal(committed.optionCount, 2); assert.equal(committed.selectedIndex, -1); assert.equal(committed.logicalSelected, ''); assert.equal(committed.checked, true);
          assert.deepEqual(committed.partitions, ['alpha', '', 'beta']); assert.equal(committed.selection, 'lphabe');
          assert.equal(committed.anchor, entry ? 2 : 1); assert.equal(committed.focus, entry ? 1 : 2);
          assert.equal(committed.svg, 'http://www.w3.org/2000/svg'); assert.equal(committed.math, 'http://www.w3.org/1998/Math/MathML'); assert.equal(committed.html, 'http://www.w3.org/1999/xhtml'); assert.equal(committed.xlink, '#native');
          assert.equal(committed.templateText, ''); assert.equal(committed.tailA, 'a'); assert.equal(committed.tailB, 'b'); assert.equal(committed.released, true);
          await page.waitForFunction(() => document.querySelector('[data-testid="environment"]').textContent === 'snapshot|/snapshot-ready?query#fragment|ack');
          const active = await page.evaluate(() => {
            document.querySelector('[data-testid="increment"]').click();
            window.__rt.runOpportunity();
            const root = document.getElementById('app');
            return { fault: window.__rt.poisoned, counter: root.querySelector('[data-testid="counter"]').textContent, active: root.querySelector('[data-testid="active"]')?.textContent, waiting: root.querySelector('[data-testid="waiting"]') !== null, retained: [...window.__kept].filter(([id]) => id !== 'waiting').every(([id, node]) => root.querySelector(`[data-testid="${id}"]`) === node), pending: window.__rt.opportunity !== null };
          });
          assert.equal(active.fault, null); assert.equal(active.counter, '2'); assert.equal(active.active, 'Live active'); assert.equal(active.waiting, false); assert.equal(active.retained, true); assert.equal(active.pending, false);
          const native = await page.evaluate(async () => {
            const query = id => document.querySelector(`[data-testid="${id}"]`), prior = window.__resources, video = query('video'), before = video.currentTime;
            await new Promise(resolve => setTimeout(resolve, 240));
            return { imageLoaded: query('image').complete && query('image').naturalWidth === 160, documentLoaded: prior.document?.body?.textContent === 'Native frame', documentRetained: query('frame').contentDocument === prior.document, sourceWrites: prior.sourceWrites, playing: !video.paused, beforeStartup: prior.videoTime, before, after: video.currentTime, duration: video.duration, progress: (video.currentTime - before + video.duration) % video.duration };
          });
          const requestsAfter = Object.fromEntries(resourceCounts);
          assert.equal(native.imageLoaded, true); assert.equal(native.documentLoaded, true); assert.equal(native.documentRetained, true); assert.equal(native.sourceWrites, 0); assert.equal(native.playing, true); assert.ok(native.progress > .08, 'retained native video keeps progressing after binding and replacement');
          assert.deepEqual(requestsAfter, requestsBefore, 'native binding and placeholder activation issue no extra resource request');
          await page.evaluate(() => window.__rt.unmount());
          const record = { browser: provider.name, version, route, cold, committed, active, native, requestsBefore, requestsAfter };
          reports.push(record); console.log(`PASS ${provider.name} ${version} native producer → same Wasm ${route}`);
        } finally { await page.close(); }
      }
    } finally { await browser.close(); }
  }
  if (options.output) fs.writeFileSync(path.join(options.output, 'browser-results.json'), JSON.stringify(reports, null, 2) + '\n');
} finally { await new Promise(resolve => server.close(resolve)); }
