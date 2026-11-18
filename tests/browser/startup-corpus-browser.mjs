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
import { resourceReply } from './startup-media.mjs';
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
files['startup-media.mjs'] = new URL('./startup-media.mjs', import.meta.url);
const resourceCounts = new Map();
const resourceRequests = []; let resourceSequence = 0;
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
    const reply = resourceReply({ method: request.method, range: request.headers.range, type, body });
    const record = { sequence: ++resourceSequence, route, method: request.method, range: request.headers.range ?? null, status: reply.status, contentRange: reply.headers['content-range'] ?? null, bytes: reply.headers['content-length'] };
    if (resourceRequests.length === 128) resourceRequests.shift(); resourceRequests.push(record);
    response.writeHead(reply.status, reply.headers); response.end(reply.body); return;
  }
  if (route === '/app.wasm') { response.setHeader('content-type', 'application/wasm'); response.end(fs.readFileSync(options.wasm)); return; }
  const file = files[path.basename(route)];
  response.setHeader('content-type', file ? 'text/javascript' : 'text/html');
  response.end(file ? fs.readFileSync(file) : pages.get(route) ?? '<!doctype html>');
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const reports = [];
const saveReports = () => { if (options.output) fs.writeFileSync(path.join(options.output, 'browser-results.json'), JSON.stringify(reports, null, 2) + '\n'); };
async function captureFailure(page, context, error) {
  const report = { ...context, error: { name: error.name, message: error.message?.slice(0, 8192), stack: error.stack?.slice(0, 16384) }, resourceCounts: Object.fromEntries(resourceCounts), resourceRequests: resourceRequests.slice() };
  try {
    report.page = await page.evaluate(async () => {
      const { mediaState } = await import('/startup-media.mjs');
      const image = document.querySelector('[data-testid="image"]'), frame = document.querySelector('[data-testid="frame"]'), root = document.getElementById('app');
      const playback = window.__resources?.playback ?? window.__playback;
      return { url: location.href, media: mediaState(document.querySelector('[data-testid="video"]')), lifecycle: playback?.lifecycle ?? null, mediaEvents: playback?.events ?? [], image: image ? { complete: image.complete, naturalWidth: image.naturalWidth, currentSrc: image.currentSrc } : null, frame: frame ? { src: frame.src, text: frame.contentDocument?.body?.textContent } : null, fault: window.__rt?.poisoned ?? null, startupPhase: window.__rt?.startupPhase ?? null, html: root?.outerHTML.slice(0, 65536) };
    });
  } catch (capture) { report.captureError = String(capture); }
  console.error('STARTUP_CORPUS_FAILURE', JSON.stringify(report));
  if (options.output) { fs.writeFileSync(path.join(options.output, `${context.browser}-${context.entry ?? 'instances'}-failure.json`), JSON.stringify(report, null, 2) + '\n'); saveReports(); }
}
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
    const livePages = [], caseRecords = [];
    let phase = 'initial-load';
    try {
      const reportedVersion = await browser.version();
      const version = typeof reportedVersion === 'string' ? reportedVersion : reportedVersion.product;
      for (const [entry, route] of ['/', '/second/'].entries()) {
        const page = await browser.newPage();
        let kept = false;
        try {
          phase = 'initial-load';
          await page.goto(`http://127.0.0.1:${server.address().port}${route}`);
          await page.waitForFunction(() => typeof window.__start === 'function');
          phase = 'native-playback-readiness';
          await page.evaluate(async () => { const video = document.querySelector('[data-testid="video"]'); video.muted = true; await video.play(); window.__videoStart = video.currentTime; });
          // buffered ranges can be partial or discarded during successful
          // playback: https://html.spec.whatwg.org/multipage/media.html#dom-media-buffered
          await page.waitForFunction(() => { const video = document.querySelector('[data-testid="video"]'), image = document.querySelector('[data-testid="image"]'); if (video.error || image.complete && image.naturalWidth === 0) return true; const delta = video.currentTime - window.__videoStart; const progress = Number.isFinite(video.duration) && video.duration > 0 ? (delta + video.duration) % video.duration : delta; return image.complete && image.naturalWidth > 0 && !video.paused && video.readyState >= 2 && progress > .08; });
          await page.evaluate(async () => { const { observePlayback } = await import('/startup-media.mjs'); const video = document.querySelector('[data-testid="video"]'); if (video.error) throw new Error(`native video before startup: ${video.error.code} ${video.error.message}`); const image = document.querySelector('[data-testid="image"]'); if (!image.naturalWidth) throw new Error('native image did not load'); window.__playback = observePlayback(video); });
          phase = 'cold-frame-observation';
          const cold = await page.evaluate(({ entry }) => {
            const root = document.getElementById('app');
            const query = id => root.querySelector(`[data-testid="${id}"]`);
            const ids = ['route', 'store-score', 'store-increment', 'selection', 'image', 'frame', 'video', 'counter', 'environment', 'increment', 'textarea', 'no-match', 'option-first', 'option-second', 'authored-inert', 'template', 'svg', 'svg-link', 'foreign-html', 'math', 'row-a', 'row-b', 'tail-a', 'tail-b', 'waiting'];
            window.__kept = new Map(ids.map(id => [id, query(id)]));
            window.__content = query('template').content.querySelector('[data-testid="content-span"]');
            window.__resources = { document: query('frame').contentDocument, videoTime: query('video').currentTime, playback: window.__playback, sourceWrites: 0 };
            for (const id of ['image', 'frame', 'video']) { const element = query(id), original = element.setAttributeNS; element.setAttributeNS = function(namespace, name, value) { if (name === 'src') window.__resources.sourceWrites++; return original.call(this, namespace, name, value); }; }
            const selected = query('selection').firstChild;
            document.getSelection().setBaseAndExtent(selected, entry ? 7 : 1, selected, entry ? 1 : 7);
            // An embedded entry selects its fixed route, even at another live URL.
            history.replaceState(null, '', '/unlisted?client=1#before');
            return { frame: root.getAttribute('data-roc-frame'), route: query('route').textContent, score: query('store-score').textContent, counter: query('counter').textContent, environment: query('environment').textContent, rootInert: root.inert, buttonInert: query('increment').inert, textareaInert: query('textarea').inert, authored: query('authored-inert').getAttribute('inert'), optionCount: query('no-match').options.length, selectedIndex: query('no-match').selectedIndex, selection: document.getSelection().toString() };
          }, { entry });
          const requestsBefore = Object.fromEntries(resourceCounts);
          const transportBefore = resourceRequests.slice();
          const requestStart = resourceSequence;
          assert.equal(cold.frame, `1:${entry}:corpus`);
          assert.equal(cold.route, entry ? 'second' : 'first');
          assert.equal(cold.score, entry ? '90' : '40');
          assert.equal(cold.counter, '0'); assert.equal(cold.environment, 'waiting');
          assert.equal(cold.rootInert, false); assert.equal(cold.buttonInert, true); assert.equal(cold.textareaInert, true);
          assert.equal(cold.authored, 'author-inert'); assert.equal(cold.optionCount, 3); assert.equal(cold.selectedIndex, 2); assert.equal(cold.selection, 'lphabe');
          phase = 'cold-binding-and-acknowledgement';
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
          phase = 'snapshot-and-placeholder-activation';
          await page.waitForFunction(() => document.querySelector('[data-testid="environment"]').textContent === 'snapshot|/snapshot-ready?query#fragment|ack');
          const active = await page.evaluate(() => {
            document.querySelector('[data-testid="increment"]').click();
            window.__rt.runOpportunity();
            const root = document.getElementById('app');
            return { fault: window.__rt.poisoned, counter: root.querySelector('[data-testid="counter"]').textContent, active: root.querySelector('[data-testid="active"]')?.textContent, waiting: root.querySelector('[data-testid="waiting"]') !== null, retained: [...window.__kept].filter(([id]) => id !== 'waiting').every(([id, node]) => root.querySelector(`[data-testid="${id}"]`) === node), pending: window.__rt.opportunity !== null };
          });
          assert.equal(active.fault, null); assert.equal(active.counter, '2'); assert.equal(active.active, 'Live active'); assert.equal(active.waiting, false); assert.equal(active.retained, true); assert.equal(active.pending, false);
          phase = 'retained-native-resource-continuity';
          const native = await page.evaluate(async () => {
            const { playbackContinuity } = await import('/startup-media.mjs');
            const query = id => document.querySelector(`[data-testid="${id}"]`), prior = window.__resources, video = query('video'), before = video.currentTime;
            await new Promise(resolve => setTimeout(resolve, 240));
            return { imageLoaded: query('image').complete && query('image').naturalWidth === 160, documentLoaded: prior.document?.body?.textContent === 'Native frame', documentRetained: query('frame').contentDocument === prior.document, sourceWrites: prior.sourceWrites, playing: !video.paused, beforeStartup: prior.videoTime, before, after: video.currentTime, duration: video.duration, progress: (video.currentTime - before + video.duration) % video.duration, continuity: playbackContinuity(prior.playback, video) };
          });
          const requestsAfter = Object.fromEntries(resourceCounts);
          assert.equal(native.imageLoaded, true); assert.equal(native.documentLoaded, true); assert.equal(native.documentRetained, true); assert.equal(native.sourceWrites, 0); assert.equal(native.playing, true, 'retained native video remains playing'); assert.ok(native.progress > .08, 'retained native video keeps progressing after binding and replacement');
          assert.equal(native.continuity.accepted, true, 'native video keeps its source, lifecycle and advancing timeline');
          for (const route of ['/startup-image.svg', '/startup-frame']) assert.equal(requestsAfter[route], requestsBefore[route], `${route} is not requested again`);
          const duringBinding = resourceRequests.filter(request => request.sequence > requestStart);
          assert.ok(duringBinding.every(request => request.route === '/startup.webm' && request.range !== null && request.status === 206), 'additional video transport consists only of successful byte-range continuations');
          await page.evaluate(() => window.__resources.playback.stop());
          const record = { browser: provider.name, version, route, cold, committed, active, native, requestsBefore, requestsAfter, transportBefore, duringBinding };
          reports.push(record); caseRecords.push(record); livePages.push(page); kept = true;
          saveReports();
          console.log(`PASS ${provider.name} ${version} native producer → same Wasm ${route}`);
        } catch (error) { await captureFailure(page, { browser: provider.name, version, entry, route, phase }, error); throw error; }
        finally { if (!kept) await page.close(); }
      }
      // Both native-produced fixed-store routes remain live simultaneously.
      // Writes enter through their real controls; neither store nor local
      // state is changed through a test-only engine seam.
      phase = 'independent-instances';
      const inspect = page => page.evaluate(() => ({ score: document.querySelector('[data-testid="store-score"]').textContent, local: document.querySelector('[data-testid="counter"]').textContent, fault: window.__rt.poisoned, retained: [...window.__kept].filter(([id]) => id !== 'waiting').every(([id, node]) => document.querySelector(`[data-testid="${id}"]`) === node) }));
      const initial = await Promise.all(livePages.map(inspect));
      assert.deepEqual(initial.map(({ score, local }) => [score, local]), [['40', '2'], ['90', '2']]);
      await livePages[0].evaluate(() => { document.querySelector('[data-testid="store-increment"]').click(); document.querySelector('[data-testid="increment"]').click(); });
      const afterFirst = await Promise.all(livePages.map(inspect));
      assert.deepEqual(afterFirst.map(({ score, local }) => [score, local]), [['41', '3'], ['90', '2']]);
      await livePages[1].evaluate(() => { document.querySelector('[data-testid="store-increment"]').click(); document.querySelector('[data-testid="store-increment"]').click(); });
      const afterSecond = await Promise.all(livePages.map(inspect));
      assert.deepEqual(afterSecond.map(({ score, local }) => [score, local]), [['41', '3'], ['92', '2']]);
      const firstDropped = await livePages[0].evaluate(() => { window.__rt.unmount(); return [document.getElementById('app').childNodes.length, Number(window.__rt.x.metric(4)), Number(window.__rt.x.metric(5))]; });
      assert.deepEqual(firstDropped, [0, 0, 0]);
      await livePages[1].evaluate(() => { document.querySelector('[data-testid="store-increment"]').click(); document.querySelector('[data-testid="increment"]').click(); });
      const survivor = await inspect(livePages[1]);
      assert.deepEqual([survivor.score, survivor.local], ['93', '3']);
      assert.ok([...initial, ...afterFirst, ...afterSecond, survivor].every(value => value.fault === null && value.retained));
      const secondDropped = await livePages[1].evaluate(() => { window.__rt.unmount(); return [Number(window.__rt.x.metric(4)), Number(window.__rt.x.metric(5))]; });
      assert.deepEqual(secondDropped, [0, 0]);
      const independence = { initial, afterFirst, afterSecond, firstDropped, survivor, secondDropped };
      for (const record of caseRecords) record.independence = independence;
      saveReports();
      console.log(`PASS ${provider.name} ${version} simultaneous fixed stores/local states and surviving instance`);
    } catch (error) { if (phase === 'independent-instances') for (const [entry, page] of livePages.entries()) await captureFailure(page, { browser: provider.name, entry, phase }, error); throw error; }
    finally { for (const page of livePages) await page.close(); await browser.close(); }
  }
  if (options.output) fs.writeFileSync(path.join(options.output, 'browser-results.json'), JSON.stringify(reports, null, 2) + '\n');
} finally { await new Promise(resolve => server.close(resolve)); }
