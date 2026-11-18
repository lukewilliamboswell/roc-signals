// Independent malformed-transport and native-selection controls. The producer's
// real native/Wasm handoff is exercised separately; these fixtures deliberately
// write their own bytes rather than borrowing the producer's encoder.
// fixtures/startup.webm is a tiny silent generated clip; only playback
// progress is asserted, independently of its pixels.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { launch } from './cdp.mjs';
import { parseArgs, runtimeFiles } from './args.mjs';
import { protocolFixtureSection } from './protocol-fixture.mjs';
const options = parseArgs(process.argv.slice(2), ['playwright', 'browser'], ['runtime']);
const files = runtimeFiles(options.runtime);
files['startup.mjs'] = path.join(path.dirname(options.runtime), 'startup.mjs');
const server = http.createServer((request, response) => {
  const route = new URL(request.url, 'http://x').pathname;
  if (route === '/empty.wasm') { response.setHeader('content-type', 'application/wasm'); response.end(new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0])); return; }
  if (route === '/startup-frame') { response.setHeader('cache-control', 'no-store'); response.end('<!doctype html><title>Native frame</title>'); return; }
  if (route === '/startup.webm') { response.setHeader('content-type', 'video/webm'); response.end(fs.readFileSync(new URL('./fixtures/startup.webm', import.meta.url))); return; }
  const file = files[path.basename(route)];
  response.setHeader('content-type', file ? 'text/javascript' : 'text/html');
  response.end(file ? fs.readFileSync(file) : '<!doctype html><body></body>');
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const automation = options.playwright ? await import(pathToFileURL(path.resolve(options.playwright)).href) : null;
const engine = automation?.[options.browser ?? 'chromium'];
if (automation && !engine?.launch) throw new Error(`unknown browser ${options.browser}`);
const browser = engine ? await engine.launch({ headless: true }) : await launch({ executablePath: options.chrome });
try {
  const page = await browser.newPage(); await page.goto(`http://127.0.0.1:${server.address().port}/`);
  const checks = await page.evaluate(async protocolSection => {
    const { StartupFrame } = await import('/startup.mjs');
    const { RocEngineRuntime, readDeclarations, mountRocEngineApp } = await import('/runtime.mjs');
    const word = value => [value & 255, value >>> 8 & 255, value >>> 16 & 255, value >>> 24];
    const text = value => { const bytes = [...new TextEncoder().encode(value)]; return [...word(bytes.length), ...bytes]; };
    const facts = (ordinal, aliases = [], holes = []) => [...word(ordinal), ...word(aliases.length), ...aliases.flatMap(word), ...word(holes.length), ...holes.flatMap(word)];
    const encode = bytes => btoa(String.fromCharCode(...bytes));
    const node = (element, ordinal, aliases, children, flags = 0) => {
      element.setAttribute('data-roc-node', encode([1, ...facts(ordinal, aliases)]));
      element.setAttribute('data-roc-children', encode([1, flags, ...word(children.length), ...children.flat(), 0, ...word(0), ...word(0)]));
    };
    const fixture = () => {
      const root = document.createElement('div'); root.setAttribute('data-roc-frame', '1:2:build');
      const p = document.createElement('p'); p.textContent = 'abcdef';
      const video = document.createElement('video'); root.append(p, video); document.body.append(root);
      node(root, 0, [0], [[1, ...word(1)], [1, ...word(5)]]);
      node(p, 1, [1], [[2, ...facts(2, [2]), ...text('ab')], [2, ...facts(3, [3]), ...text('')], [2, ...facts(4, [4]), ...text('cdef')]]);
      node(video, 5, [5], []);
      return { root, p, video };
    };
    const checks = [], check = (name, condition) => checks.push([name, !!condition]);
    for (const backward of [false, true]) {
      const f = fixture(), selection = document.getSelection(), original = f.p.firstChild;
      selection.setBaseAndExtent(original, backward ? 5 : 1, original, backward ? 1 : 5);
      const frame = new StartupFrame(f.root, 'build'); frame.normalize();
      for (const [id, kind] of [[1, 1], [2, 2], [3, 2], [4, 2], [5, 1]]) frame.bind(id, kind);
      frame.finish();
      check(`whole frame retains native elements and ${backward ? 'backward' : 'forward'} selection`, f.root.firstChild === f.p && f.root.lastChild === f.video && selection.toString() === 'bcde' && (backward ? selection.anchorOffset === 3 && selection.focusOffset === 1 : selection.anchorOffset === 1 && selection.focusOffset === 3));
      check('adjacent and omitted text receive exact logical partitions', [...f.p.childNodes].map(child => child.data).join('|') === 'ab||cdef');
      check('cold transport facts are released', frame.ordinals.size === 0 && frame.aliases.size === 0 && frame.selection === null);
      f.root.remove();
    }
    const getSelection = document.getSelection;
    for (const [name, hidden, backward, refuses] of [
      ['collapse and extend preserve backward direction without setBaseAndExtent', ['setBaseAndExtent'], true, false],
      ['forward selection needs no directional setter', ['setBaseAndExtent', 'collapse', 'extend'], false, false],
      ['unrestorable backward direction refuses before mutation', ['setBaseAndExtent', 'collapse', 'extend'], true, true],
    ]) {
      const f = fixture(), selection = getSelection.call(document), original = f.p.firstChild;
      selection.setBaseAndExtent(original, backward ? 5 : 1, original, backward ? 1 : 5);
      const exposed = new Proxy(selection, { get(target, key) { if (hidden.includes(key)) return undefined; const value = Reflect.get(target, key, target); return typeof value === 'function' ? value.bind(target) : value; } });
      let refused = false;
      try {
        document.getSelection = () => exposed;
        const frame = new StartupFrame(f.root, 'build'); frame.normalize();
        for (const [id, kind] of [[1, 1], [2, 2], [3, 2], [4, 2], [5, 1]]) frame.bind(id, kind);
        frame.finish();
      } catch (error) { refused = error.message.includes('unsupported selection direction'); }
      finally { document.getSelection = getSelection; }
      check(name, refuses ? refused && f.p.firstChild === original && f.p.childNodes.length === 1 : !refused && selection.toString() === 'bcde' && (backward ? selection.anchorOffset === 3 && selection.focusOffset === 1 : selection.anchorOffset === 1 && selection.focusOffset === 3));
      f.root.remove();
    }
    const multiple = fixture(), multipleSelection = getSelection.call(document), multipleText = multiple.p.firstChild;
    const early = document.createRange(), late = document.createRange(); early.setStart(multipleText, 0); early.setEnd(multipleText, 1); late.setStart(multipleText, 4); late.setEnd(multipleText, 5);
    multipleSelection.removeAllRanges(); multipleSelection.addRange(late); multipleSelection.addRange(early);
    if (multipleSelection.rangeCount === 2) {
      const frame = new StartupFrame(multiple.root, 'build'); frame.normalize();
      for (const [id, kind] of [[1, 1], [2, 2], [3, 2], [4, 2], [5, 1]]) frame.bind(id, kind); frame.finish();
      check('multiple native ranges retain their forward primary endpoints', multipleSelection.rangeCount === 2 && multipleSelection.toString() === 'ae' && multipleSelection.anchorNode === multiple.p.firstChild && multipleSelection.anchorOffset === 0 && multipleSelection.focusNode === multiple.p.firstChild && multipleSelection.focusOffset === 1);
    }
    multiple.root.remove();
    const backwardMultiple = fixture(), backwardText = backwardMultiple.p.firstChild; let backwardMultipleRefused = false;
    try {
      document.getSelection = () => ({ rangeCount: 2, anchorNode: backwardText, anchorOffset: 5, focusNode: backwardText, focusOffset: 4, getRangeAt(index) { return { startContainer: backwardText, startOffset: index ? 4 : 0, endContainer: backwardText, endOffset: index ? 5 : 1 }; } });
      new StartupFrame(backwardMultiple.root, 'build');
    } catch (error) { backwardMultipleRefused = error.message.includes('unsupported multi-range selection direction'); }
    finally { document.getSelection = getSelection; }
    check('unrestorable multi-range direction refuses before mutation', backwardMultipleRefused && backwardMultiple.p.firstChild === backwardText && backwardMultiple.p.childNodes.length === 1);
    backwardMultiple.root.remove();
    const boundary = fixture(), containerSelection = document.getSelection();
    containerSelection.setBaseAndExtent(boundary.p, 0, boundary.p, 1);
    const boundaryFrame = new StartupFrame(boundary.root, 'build'); boundaryFrame.normalize();
    for (const [id, kind] of [[1, 1], [2, 2], [3, 2], [4, 2], [5, 1]]) boundaryFrame.bind(id, kind); boundaryFrame.finish();
    check('container selection boundaries map through declared text partitions', containerSelection.toString() === 'abcdef' && containerSelection.anchorNode === boundary.p && containerSelection.anchorOffset === 0 && containerSelection.focusNode === boundary.p && containerSelection.focusOffset === 3);
    boundary.root.remove();
    const ranged = fixture(), originalSelection = document.getSelection; let rangeRefused = false; const rangeText = ranged.p.firstChild;
    try { document.getSelection = () => ({ rangeCount: 65 }); new StartupFrame(ranged.root, 'build'); }
    catch (error) { rangeRefused = error.message.includes('selection range resource limit'); }
    finally { document.getSelection = originalSelection; }
    check('selection range bounds refuse before text or element mutation', rangeRefused && ranged.p.firstChild === rangeText && ranged.p.childNodes.length === 1);
    ranged.root.remove();
    for (const [name, mutate, token = 'build'] of [
      ['unknown annotation version', f => f.p.setAttribute('data-roc-node', encode([2, ...facts(1, [1])]))],
      ['noncanonical Base64 padding', f => f.p.setAttribute('data-roc-node', f.p.getAttribute('data-roc-node').replace(/=$/, ''))],
      ['duplicate engine address', f => node(f.video, 5, [1], [])],
      ['mount address on a non-root element', f => { node(f.root, 0, [], [[1, ...word(1)], [1, ...word(5)]]); node(f.video, 5, [0], []); }],
      ['mount address on logical text', f => { node(f.root, 0, [], [[1, ...word(1)], [1, ...word(5)]]); node(f.p, 1, [1], [[2, ...facts(2, [0]), ...text('abcdef')]]); }],
      ['duplicate logical ordinal', f => node(f.video, 1, [5], [])],
      ['missing declared physical child', f => f.video.remove()],
      ['unexpected physical child', f => f.root.append(document.createTextNode('foreign'))],
      ['truncated count', f => f.p.setAttribute('data-roc-node', encode([1, ...word(1), ...word(0xffffffff)]))],
      ['missing annotation', f => f.video.removeAttribute('data-roc-children')],
      ['wrong build token', () => {}, 'other'],
      ['noncanonical entry identifier', f => f.root.setAttribute('data-roc-frame', '1:02:build')],
    ]) {
      const f = fixture(); mutate(f); const before = f.root.outerHTML; let error = null;
      try { new StartupFrame(f.root, token); } catch (caught) { error = caught; }
      check(`${name} refuses before DOM mutation`, error && before === f.root.outerHTML);
      f.root.remove();
    }
    const gated = fixture(); gated.p.setAttribute('inert', ''); node(gated.p, 1, [1], [[2, ...facts(2, [2]), ...text('abcdef')]], 1);
    const frame = new StartupFrame(gated.root, 'build'); frame.normalize(); frame.bind(1, 1); frame.bind(2, 2); frame.bind(5, 1); frame.finish();
    check('producer-added gate restores on its physical node', !gated.p.hasAttribute('inert'));
    gated.root.remove();
    const controlRoot = document.createElement('div'); controlRoot.setAttribute('data-roc-frame', '1:0:build');
    const select = document.createElement('select'), option = document.createElement('option'), temporary = document.createElement('option');
    option.value = 'existing'; temporary.setAttribute('hidden', ''); temporary.setAttribute('selected', ''); temporary.setAttribute('value', '');
    select.append(option, temporary); controlRoot.append(select); document.body.append(controlRoot);
    node(controlRoot, 0, [0], [[1, ...word(1)]]); node(select, 1, [1], [[1, ...word(2)]]); node(option, 2, [2], []);
    select.setAttribute('data-roc-children', encode([1, 0, ...word(1), 1, ...word(2), 0, ...word(0), ...word(1), ...word(1)]));
    const selectionFrame = new StartupFrame(controlRoot, 'build'); selectionFrame.normalize(); selectionFrame.bind(1, 1); selectionFrame.bind(2, 1); selectionFrame.finish();
    check('explicit no-selection scaffold is removed without replacing native options', select.childNodes.length === 1 && select.firstChild === option && !temporary.isConnected);
    controlRoot.remove();
    const textareaRoot = document.createElement('div'); textareaRoot.setAttribute('data-roc-frame', '1:0:build');
    const textarea = document.createElement('textarea'); textarea.textContent = 'shown'; textareaRoot.append(textarea); document.body.append(textareaRoot);
    node(textareaRoot, 0, [0], [[1, ...word(1)]]); node(textarea, 1, [1], []);
    textarea.setAttribute('data-roc-children', encode([1, 2, ...word(1), 2, ...facts(2, [2]), ...text('authored'), 0, ...text('shown'), ...word(0), ...word(0)]));
    const textareaFrame = new StartupFrame(textareaRoot, 'build'); textareaFrame.normalize(); textareaFrame.bind(1, 1); textareaFrame.bind(2, 2); textareaFrame.finish();
    check('explicit textarea scaffold restores logical text before controlled properties', textarea.textContent === 'authored' && textareaRoot.firstChild === textarea);
    textareaRoot.remove();
    const templateRoot = document.createElement('div'); templateRoot.setAttribute('data-roc-frame', '1:0:build');
    const templateNode = document.createElement('template'), contentElement = document.createElement('span'); contentElement.textContent = 'inert'; templateNode.content.append(contentElement); templateRoot.append(templateNode); document.body.append(templateRoot);
    node(templateRoot, 0, [0], [[1, ...word(1)]]); node(templateNode, 1, [1], []); node(contentElement, 2, [2], [[2, ...facts(3, [3]), ...text('inert')]]);
    templateNode.setAttribute('data-roc-children', encode([1, 0, ...word(0), 1, ...word(1), 1, ...word(2), ...word(0), ...word(0)]));
    const contentFrame = new StartupFrame(templateRoot, 'build'); contentFrame.normalize(); contentFrame.bind(1, 1); contentFrame.bind(2, 1); contentFrame.bind(3, 2); contentFrame.finish();
    check('template content has its own retained container and logical bindings', templateNode.childNodes.length === 0 && templateNode.content.firstChild === contentElement && templateNode.textContent === '');
    templateRoot.remove();
    const nativeSelectRoot = document.createElement('div'); nativeSelectRoot.setAttribute('data-roc-frame', '1:0:build');
    nativeSelectRoot.innerHTML = '<select inert style="appearance:base-select"><button inert><selectedcontent inert></selectedcontent></button><option selected inert><span>Native copy</span></option></select>';
    document.body.append(nativeSelectRoot);
    const nativeSelect = nativeSelectRoot.firstChild, nativeButton = nativeSelect.firstChild, nativeContent = nativeButton.firstChild, nativeOption = nativeSelect.lastChild, nativeSpan = nativeOption.firstChild;
    node(nativeSelectRoot, 0, [0], [[1, ...word(1)]]); node(nativeSelect, 1, [1], [[1, ...word(2)], [1, ...word(4)]]); node(nativeButton, 2, [2], [[1, ...word(3)]]); node(nativeContent, 3, [3], []); node(nativeOption, 4, [4], [[1, ...word(5)]]); node(nativeSpan, 5, [5], [[2, ...facts(6, [6]), ...text('Native copy')]]);
    if (nativeContent.childNodes.length) {
      let nativeMutationRefused = false;
      try { new StartupFrame(nativeSelectRoot, 'build'); } catch (error) { nativeMutationRefused = error.message.startsWith('startup:'); }
      check('native selectedcontent cloning despite inert cannot become an unchecked binding', nativeMutationRefused && nativeContent.childNodes.length > 0);
    }
    nativeSelectRoot.remove();
    const shadowFrame = document.createElement('iframe');
    const shadowLoaded = new Promise((resolve, reject) => { const timer = setTimeout(() => reject(new Error('declarative shadow fixture timed out')), 5000); shadowFrame.onload = () => { clearTimeout(timer); resolve(); }; });
    shadowFrame.srcdoc = `<div id="host" inert data-roc-frame="1:0:build" data-roc-node="${encode([1, ...facts(0, [0])])}" data-roc-children="${encode([1, 0, ...word(1), 1, ...word(1), 0, ...word(0), ...word(0)])}"><template shadowrootmode="open"><span>Native shadow</span></template></div>`;
    document.body.append(shadowFrame); await shadowLoaded;
    const shadowOwner = shadowFrame.contentDocument.getElementById('host'); let shadowRefused = false;
    try { new StartupFrame(shadowOwner, 'build'); } catch (error) { shadowRefused = error.message.startsWith('startup:'); }
    check('native declarative shadow parsing removes the ordinary template before binding', shadowOwner.shadowRoot?.textContent === 'Native shadow' && shadowOwner.childNodes.length === 0 && shadowRefused);
    shadowFrame.remove();
    const section = (tag, bytes) => [tag, ...word(bytes.length), ...bytes];
    const htmlName = local => [0, ...text(''), ...text(local)];
    const startupDeclaration = [1, ...htmlName('div'), ...word(3), ...text('/'), ...text('/a/'), ...text('/b/'), ...word(0xffffffff)];
    const declarations = [...section(2, word(0)), ...section(5, word(0)), ...section(6, word(0)), ...section(10, [110, 1]), ...section(11, word(0)), ...protocolSection, ...section(14, startupDeclaration)];
    const coldGet = [13, ...word(9), 2, ...text('example')];
    const batch = [0, 28, 1, ...word(2),
      8, ...word(1), ...word(0), ...word(0), ...htmlName('p'), 0,
      10, ...word(2), ...word(1), ...word(0), ...text('ab'),
      10, ...word(3), ...word(1), ...word(0), ...text(''),
      10, ...word(4), ...word(1), ...word(0), ...text('cdef'),
      8, ...word(5), ...word(0), ...word(0), ...htmlName('video'), 0,
      ...coldGet, 29];
    const f = fixture(), memory = new WebAssembly.Memory({ initial: 4 }); let length = 0; const calls = [], effects = [];
    const write = bytes => { new Uint8Array(memory.buffer).set(bytes); length = bytes.length; };
    const host = { memory, protocol_version: () => 23, dbg_len: () => 0, dbg_ptr: () => 0,
      boot_keys() { write(declarations); }, cmd_ptr: () => 0, cmd_len: () => length, payload_reserve: () => 200000,
      init() { calls.push('init'); write(batch); return 0; },
      event(node, handler) { const payload = new Uint8Array(memory.buffer, 200000, 1)[0]; calls.push([handler, payload]); write(handler === 0 && payload === 254 ? [0, 30] : []); return 0; },
      keys_released: () => 0, files_released: () => 0, fault: () => 0, work_len: () => 0, metric: () => 0n, drop() {},
    };
    const neutralDeclarations = [...section(2, [...word(1), ...text('example')]), ...section(5, word(0)), ...section(6, [...word(1), ...text('(color)')]), ...section(10, [0, 0]), ...section(11, [...word(1), ...text('draft')]), ...protocolSection, ...section(14, startupDeclaration)];
    const domOnly = batch.slice(0, -coldGet.length - 1);
    const throwingCounts = { local: 0, session: 0, localRead: 0, sessionRead: 0, online: 0, visible: 0, matchMedia: 0, now: 0, seed: 0, languages: 0, timeZone: 0 };
    const throwingEnvironment = Object.fromEntries(['online', 'visible', 'matchMedia', 'now', 'seed', 'languages', 'timeZone'].map(key => [key, () => { throwingCounts[key]++; throw new Error('deliberately unavailable ' + key); }]));
    const lazyWindow = new Proxy(window, { get(target, key) {
      if (key === 'localStorage') { throwingCounts.local++; return { getItem() { throwingCounts.localRead++; return 'local'; } }; }
      if (key === 'sessionStorage') { throwingCounts.session++; return { getItem() { throwingCounts.sessionRead++; return 'session'; } }; }
      const value = Reflect.get(target, key, target); return typeof value === 'function' ? value.bind(target) : value;
    } });
    const neutral = fixture();
    const neutralHost = { ...host, boot_keys() { write(neutralDeclarations); }, init() { write([...domOnly, 29]); return 0; } };
    const neutralRuntime = new RocEngineRuntime(neutralHost, neutral.root, { window: lazyWindow, environment: throwingEnvironment, startupBuildToken: 'build', manualEffects: true }); neutralRuntime.mount();
    check('deterministic bootstrap reads no live environment or storage service', !neutralRuntime.poisoned && Object.values(throwingCounts).every(count => count === 0));
    write([0, 13, ...word(77), 22]); neutralRuntime.apply(); await new Promise(resolve => setTimeout(resolve, 0));
    check('only a later snapshot reaches throwing readers and classifies their fault', neutralRuntime.poisoned?.class === 'executor' && throwingCounts.now === 1 && throwingCounts.localRead === 1 && throwingCounts.sessionRead === 1);
    neutralRuntime.unmount(); neutral.root.remove(); calls.length = 0;
    const sampled = fixture(), reads = { now: 0, seed: 0, languages: 0, timeZone: 0, online: 0, visible: 0, matchMedia: 0 };
    const localValues = new Map([['example', 'before']]), sessionValues = new Map([['draft', 'current']]);
    const store = values => ({ getItem: key => values.get(key) ?? null, setItem: (key, value) => values.set(key, value), removeItem: key => values.delete(key) });
    const counted = (key, value) => () => { reads[key]++; return value; };
    const environment = { now: counted('now', 42n), seed: counted('seed', new Uint8Array(16).fill(7)), languages: counted('languages', ['en-NZ']), timeZone: counted('timeZone', { name: 'UTC', from_ms: -(1n << 63n), until_ms: (1n << 63n) - 1n, offsets: [{ from_ms: -(1n << 63n), minutes: 0 }] }), online: counted('online', false), visible: counted('visible', true), matchMedia: counted('matchMedia', { matches: true, addEventListener() {}, removeEventListener() {} }) };
    const originalLocation = location.pathname + location.search + location.hash; let snapshotPayload = null, reserved = 0;
    const sampledHost = { ...host, boot_keys() { write(neutralDeclarations); }, payload_reserve(length) { reserved = length; return 200000; }, init() { write([...domOnly, 13, ...word(77), 22, 16, 1, ...text('example'), ...text('cold'), 29]); return 0; }, event(_node, handler) {
      if (handler === 0) write([0, 16, 1, ...text('example'), ...text('ack'), 15, 2, ...text('/after-ack?query#fragment'), 30]);
      else { snapshotPayload = new Uint8Array(memory.buffer, 200000, reserved).slice(); write([]); }
      return 0;
    } };
    const sampledRuntime = new RocEngineRuntime(sampledHost, sampled.root, { environment, storage: store(localValues), sessionStorage: store(sessionValues), startupBuildToken: 'build', manualEffects: true }); sampledRuntime.mount();
    check('snapshot stays unsampled through cold and acknowledgement batches', !sampledRuntime.poisoned && Object.values(reads).every(count => count === 0) && localValues.get('example') === 'ack');
    await new Promise(resolve => setTimeout(resolve, 0));
    const sections = new Map(); let payloadAt = 1;
    while (payloadAt < snapshotPayload.length) { const tag = snapshotPayload[payloadAt], length = new DataView(snapshotPayload.buffer).getUint32(payloadAt + 1, true); sections.set(tag, snapshotPayload.slice(payloadAt + 5, payloadAt + 5 + length)); payloadAt += 5 + length; }
    const stringAt = (bytes, at) => { const length = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getUint32(at, true); return { text: new TextDecoder().decode(bytes.subarray(at + 4, at + 4 + length)), next: at + 4 + length }; };
    const localSection = sections.get(2), localKey = stringAt(localSection, 5), localValue = stringAt(localSection, localKey.next);
    check('snapshot callback sees cold and acknowledgement writes and current history', snapshotPayload[0] === 31 && stringAt(sections.get(1), 0).text === '/after-ack?query#fragment' && localKey.text === 'example' && localValue.text === 'ack' && !sections.has(13) && !sections.has(14) && Object.values(reads).every(count => count === 1));
    sampledRuntime.unmount(); sampled.root.remove(); history.replaceState(null, '', originalLocation);
    const legacyRoot = document.createElement('div'); document.body.append(legacyRoot);
    const legacyDeclarations = [...declarations.slice(0, declarations.length - 5 - startupDeclaration.length), ...section(14, [0])];
    const legacyHost = { ...host, boot_keys() { write(legacyDeclarations); }, init() { write([0, 31, 1, 1, 0, 0, 0, 0, 0, 0, 0]); return 0; } };
    const legacyRuntime = new RocEngineRuntime(legacyHost, legacyRoot, { manualEffects: true }); legacyRuntime.mount();
    check('ordinary legacy construction can register placeholder opportunities', !legacyRuntime.poisoned && legacyRuntime.opportunity?.generation === 1n && legacyRuntime.startupPhase === 'plain');
    const transitionDescriptor = Object.getOwnPropertyDescriptor(document, 'startViewTransition'); let transitionUpdate = null;
    const actions = [], register = legacyRuntime.requestOpportunity.bind(legacyRuntime);
    legacyRuntime.requestOpportunity = (action, generation) => { actions.push([action, generation.toString()]); register(action, generation); };
    try {
      Object.defineProperty(document, 'startViewTransition', { configurable: true, value: argument => { transitionUpdate = typeof argument === 'function' ? argument : argument.update; return { ready: Promise.resolve(), finished: Promise.resolve(), skipTransition() {} }; } });
      const invalidatedCallback = legacyRuntime.opportunity.deliver;
      write([1, 31, 0, 1, 0, 0, 0, 0, 0, 0, 0, 24, ...word(0)]); legacyRuntime.busy = true; legacyRuntime.apply();
      invalidatedCallback();
      check('marked batches cancel opportunities before their deferred DOM update', legacyRuntime.opportunity === null && legacyRuntime.pendingTransition !== null && legacyRuntime.queue.length === 0);
      transitionUpdate();
      write([1, 8, ...word(99), ...word(0), ...word(0), ...htmlName('div'), 0, 31, 1, 2, 0, 0, 0, 0, 0, 0, 0, 24, ...word(0)]); legacyRuntime.busy = true; legacyRuntime.apply();
      const beforeOpportunity = calls.length; legacyRuntime.runOpportunity();
      check('early transition opportunity callbacks wait behind the busy ingress barrier', legacyRuntime.opportunity?.generation === 2n && legacyRuntime.queue.length === 1 && calls.length === beforeOpportunity && legacyRoot.childNodes.length === 0);
      transitionUpdate();
      check('transition update drains one opportunity without repeating its registration', !legacyRuntime.poisoned && legacyRuntime.lookup(99)?.localName === 'div' && legacyRuntime.opportunity === null && calls.length === beforeOpportunity + 1 && JSON.stringify(actions) === JSON.stringify([[0, '1'], [1, '2']]));
    } finally {
      if (transitionDescriptor) Object.defineProperty(document, 'startViewTransition', transitionDescriptor); else delete document.startViewTransition;
    }
    legacyRuntime.requestOpportunity(1, 3n); const beforeInvalidCancel = legacyRuntime.opportunity;
    write([0, 31, 0, 4, 0, 0, 0, 0, 0, 0, 0]); let futureCancel = null;
    try { legacyRuntime.apply(); } catch (error) { futureCancel = error; }
    check('a future cancellation frame refuses before replacing its registration', futureCancel?.message.includes('no matching registration') && legacyRuntime.opportunity === beforeInvalidCancel && legacyRuntime.opportunityGeneration === 3n);
    write([0, 31, 0, 3, 0, 0, 0, 0, 0, 0, 0]); legacyRuntime.apply(); let repeatedCancel = null;
    try { legacyRuntime.apply(); } catch (error) { repeatedCancel = error; }
    check('a cancellation frame without a registration is a protocol error', repeatedCancel?.message.includes('no matching registration') && legacyRuntime.opportunity === null && legacyRuntime.opportunityGeneration === 3n);
    legacyRuntime.unmount(); legacyRoot.remove(); calls.length = 0;
    const runtime = new RocEngineRuntime(host, f.root, { startupBuildToken: 'build', manualEffects: true });
    runtime.perform = effect => { effects.push(effect.op); runtime.result(9, new Uint8Array([4])); };
    runtime.mount();
    check('whole runtime binds native nodes and accepts a quiet acknowledgement', !runtime.poisoned && runtime.startupPhase === 'complete' && runtime.lookup(1) === f.p && runtime.lookup(5) === f.video);
    check('synchronous cold answers wait behind private acknowledgement', JSON.stringify(calls) === JSON.stringify(['init', [0, 254], [9, 4]]) && effects.join() === 'get');
    check('temporary annotation maps are gone before acknowledgement', runtime.startup === null);
    runtime.requestOpportunity(1, 1n);
    await new Promise(resolve => setTimeout(resolve, 0));
    check('manual opportunity waits for an explicit test step', runtime.opportunity?.generation === 1n && calls.length === 3);
    runtime.runOpportunity();
    check('one manual opportunity enters the private ordinary turn', runtime.opportunity === null && calls.at(-1)[0] === 0 && calls.at(-1)[1] === 255);
    let missing = null; try { runtime.runOpportunity(); } catch (error) { missing = error; }
    check('an opportunity step without a registration fails explicitly', missing?.message.includes('no pending'));
    runtime.requestOpportunity(1, 2n); const stale = runtime.opportunity.deliver;
    runtime.requestOpportunity(0, 2n); const beforeStale = calls.length; stale();
    check('cancelled browser callback cannot deliver a stale generation', runtime.opportunity === null && calls.length === beforeStale);
    runtime.requestOpportunity(1, 3n); runtime.busy = true; runtime.runOpportunity();
    runtime.requestOpportunity(0, 3n); runtime.busy = false; runtime.drainQueue();
    check('cancellation also invalidates an already queued opportunity', calls.length === beforeStale && runtime.queue.length === 0);
    RocEngineRuntime.prototype.perform.call(runtime, { op: 'environment', id: 77 });
    RocEngineRuntime.prototype.perform.call(runtime, { op: 'environment', id: 78 }); runtime.cancel(78);
    await new Promise(resolve => setTimeout(resolve, 0));
    check('post-bootstrap environment snapshots use an ordinary cancellable result turn', calls.at(-1)[0] === 77 && calls.at(-1)[1] === 31 && !runtime.live.has(77) && !runtime.live.has(78));
    runtime.busy = true;
    for (let at = 0; at < 4096; at++) runtime.dispatch(0xffffffff, 9, new Uint8Array([4]));
    runtime.requestOpportunity(1, 4n); let opportunityOverflow = null;
    try { runtime.runOpportunity(); } catch (error) { opportunityOverflow = error; }
    check('opportunity ingress overflow is classified containment without eager activation', opportunityOverflow && runtime.poisoned?.class === 'resource_limit' && runtime.opportunity === null && runtime.queue.length === 0);
    runtime.busy = false; runtime.unmount(); f.root.remove();
    const unloaded = fixture(), loadFaults = [];
    let loadRejected = false;
    try { await mountRocEngineApp({ wasmUrl: '/not-wasm', root: unloaded.root, startupBuildToken: 'build', onFault: fault => loadFaults.push(fault) }); }
    catch { loadRejected = true; }
    check('a failed annotated module load contains once and retains the native frame', loadRejected && loadFaults.length === 1 && unloaded.root.hasAttribute('inert') && unloaded.root.firstChild === unloaded.p);
    const retryRuntime = new RocEngineRuntime(host, unloaded.root, { startupBuildToken: 'build', manualEffects: true }); retryRuntime.mount();
    check('an explicit retry restores only its producer-owned failed-load gate', !retryRuntime.poisoned && retryRuntime.lookup(1) === unloaded.p && !unloaded.root.hasAttribute('inert') && !unloaded.root.hasAttribute('data-roc-failed'));
    retryRuntime.unmount(); unloaded.root.remove();
    const receipted = fixture();
    const receiptInstantiate = WebAssembly.instantiate; let receiptRuntime;
    try { WebAssembly.instantiate = async () => ({ exports: host }); receiptRuntime = await mountRocEngineApp({ wasmUrl: '/empty.wasm?roc-build=build', root: receipted.root, manualEffects: true }); }
    finally { WebAssembly.instantiate = receiptInstantiate; }
    check('an explicit module URL receipt supplies the expected build token', !receiptRuntime.poisoned && receiptRuntime.startupBuildToken === 'build' && receiptRuntime.lookup(1) === receipted.p);
    receiptRuntime.unmount(); receipted.root.remove();
    const mismatched = fixture(); const mismatchFaults = [];
    let mismatchRejected = false;
    try { await mountRocEngineApp({ wasmUrl: '/empty.wasm?roc-build=build', root: mismatched.root, startupBuildToken: 'other', onFault: fault => mismatchFaults.push(fault) }); }
    catch { mismatchRejected = true; }
    check('conflicting explicit receipts refuse and contain before engine init', mismatchRejected && mismatchFaults.length === 1 && mismatched.root.hasAttribute('inert') && mismatched.root.firstChild === mismatched.p);
    mismatched.root.remove();
    const swappedRoot = document.createElement('div'); swappedRoot.setAttribute('data-roc-frame', '1:2:build');
    const first = document.createElement('p'), second = document.createElement('p'); swappedRoot.append(first, second); document.body.append(swappedRoot);
    node(swappedRoot, 0, [0], [[1, ...word(1)], [1, ...word(2)]]); node(first, 1, [2], []); node(second, 2, [1], []);
    const swappedHost = { ...host, init() { write([0, 28, 1, ...word(2), 8, ...word(1), ...word(0), ...word(0), ...htmlName('p'), 0, 8, ...word(2), ...word(0), ...word(0), ...htmlName('p'), 0, 29]); return 0; } };
    const swappedRuntime = new RocEngineRuntime(swappedHost, swappedRoot, { startupBuildToken: 'build', manualEffects: true }); swappedRuntime.mount();
    check('swapped annotations on identical siblings fail cold construction order', swappedRuntime.poisoned?.message.includes('cold construction order') && swappedRoot.firstChild === first && swappedRoot.lastChild === second);
    swappedRuntime.unmount(); swappedRoot.remove();
    const broken = fixture();
    const failedHost = { ...host, init() { write([0, 28, 1, ...word(2), 8, ...word(1), ...word(0), ...word(0), ...htmlName('wrong'), 0, 29]); return 0; } };
    const module = new WebAssembly.Module(new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0]));
    const failedRuntime = new RocEngineRuntime(failedHost, broken.root, { startupBuildToken: 'build', manualEffects: true, module });
    failedRuntime.mount();
    check('a startup binding fault keeps the declared root inert', failedRuntime.poisoned?.class === 'executor' && broken.root.hasAttribute('inert') && broken.root.firstChild === broken.p);
    let stagedLength = 0, recoveredBoot = null;
    const freshHost = { ...host, payload_reserve(length) { stagedLength = length; return 200000; }, init() {
      recoveredBoot = [...new Uint8Array(memory.buffer, 200000, stagedLength)];
      write([0, 28, 0, ...word(2), 8, ...word(1), ...word(0), ...word(0), ...htmlName('p'), 0, 9, ...word(1), 3, ...text(''), ...text('tabindex'), 1, ...text('0'), 18, 1, ...word(1), 29]); return 0;
    } };
    const instantiate = WebAssembly.instantiate;
    try { WebAssembly.instantiate = async () => ({ exports: freshHost }); await failedRuntime.recover(); }
    finally { WebAssembly.instantiate = instantiate; }
    check('explicit recovery creates a fresh frame at the same catalogue entry', !failedRuntime.poisoned && failedRuntime.startupEntry === 2 && failedRuntime.lookup(1) !== broken.p && JSON.stringify(recoveredBoot.slice(-11)) === JSON.stringify([14, 6, 0, 0, 0, 1, 0, 2, 0, 0, 0]));
    check('recovery restores its fault gate before cold focus effects', !broken.root.hasAttribute('inert') && document.activeElement === failedRuntime.lookup(1));
    failedRuntime.unmount(); broken.root.remove();
    const rowRoot = document.createElement('div'); rowRoot.setAttribute('data-roc-frame', '1:2:build');
    const row = document.createElement('div'), nested = document.createElement('p'), tail = document.createElement('span');
    nested.textContent = 'nested'; tail.textContent = 'tail'; row.append(nested, tail); rowRoot.append(row); document.body.append(rowRoot);
    node(rowRoot, 0, [0], [[1, ...word(1)]]);
    node(row, 1, [10], [[1, ...word(2)], [2, ...facts(4, [11]), ...text('')], [1, ...word(5)]]);
    row.setAttribute('data-roc-node', encode([1, ...facts(1, [10], [4, 5])]));
    node(nested, 2, [13], [[2, ...facts(3, [14]), ...text('nested')]]);
    node(tail, 5, [12], [[2, ...facts(6), ...text('tail')]]);
    const templateElement = (tag, children) => [1, ...htmlName(tag), 0, 0, children.length, ...children.flat()];
    const template = [...templateElement('div', [[2, ...text('')], templateElement('span', [[2, ...text('tail')]])]), 2, 4, 1, 0, 0, 5, 1, 0, 1];
    const rowBatch = [0, 28, 1, ...word(2), 7, ...word(1), ...word(template.length), ...template,
      1, ...word(10), ...word(0), ...word(0), ...word(1), ...word(11), ...word(12),
      8, ...word(13), ...word(0), ...word(11), ...htmlName('p'), 0,
      10, ...word(14), ...word(13), ...word(0), ...text('nested'), 29];
    const rowHost = { ...host, init() { write(rowBatch); return 0; }, event(_node, handler) { write(handler === 0 ? [0, 30] : [0, 1, ...word(20), ...word(0), ...word(0), ...word(1), ...word(21), ...word(22)]); return 0; } };
    const rowRuntime = new RocEngineRuntime(rowHost, rowRoot, { startupBuildToken: 'build', manualEffects: true });
    const createElementNS = document.createElementNS; let coldFactories = 0;
    try { document.createElementNS = () => { coldFactories++; throw new Error('cold template must remain a pure description'); }; rowRuntime.mount(); }
    finally { document.createElementNS = createElementNS; }
    check('nested site shifts template paths without changing explicit hole targets', !rowRuntime.poisoned && rowRuntime.lookup(10) === row && rowRuntime.lookup(12) === tail && rowRuntime.lookup(13) === nested && row.__ht[0] === nested.nextSibling && row.__ht[1] === tail);
    check('cold template binding creates no detached resource-capable skeleton', coldFactories === 0);
    rowRuntime.dispatch(0xffffffff, 99, new Uint8Array());
    check('a later fresh row lazily materializes the ordinary clone template', !rowRuntime.poisoned && rowRuntime.lookup(20) !== row && rowRuntime.lookup(22)?.textContent === 'tail');
    rowRuntime.unmount(); rowRoot.remove();
    // A native-state oracle must reject pause/restart/replacement mutants;
    // identity alone would let a paused video or restarted animation pass.
    const style = document.createElement('style'); style.textContent = '@keyframes roc-startup-pulse {from {opacity:.2} to {opacity:1}}'; document.head.append(style);
    for (const mutation of ['none', 'pause-video', 'pause-animation', 'restart-video', 'restart-animation', 'replace-video', 'reload-frame']) {
      const resources = document.createElement('div'); resources.setAttribute('data-roc-frame', '1:2:build');
      const video = document.createElement('video'), iframe = document.createElement('iframe'), animation = document.createElement('div'), placeholder = document.createElement('section');
      video.src = '/startup.webm'; video.muted = true; video.loop = true; video.setAttribute('muted', ''); iframe.src = '/startup-frame'; animation.style.animation = 'roc-startup-pulse 2s linear infinite';
      const loaded = new Promise((resolve, reject) => { const timer = setTimeout(() => reject(new Error('native frame load timed out')), 5000); iframe.onload = () => { clearTimeout(timer); resolve(); }; });
      resources.append(video, iframe, animation, placeholder); document.body.append(resources); await loaded; await video.play();
      getComputedStyle(animation).opacity; await new Promise(resolve => setTimeout(resolve, 400));
      const prior = { video, time: video.currentTime, animation: animation.getAnimations()[0], frame: iframe, document: iframe.contentDocument }; prior.animationTime = prior.animation.currentTime;
      node(resources, 0, [0], [1, 2, 3, 6].map(id => [1, ...word(id)])); node(video, 1, [1], []); node(iframe, 2, [2], []); node(animation, 3, [3], []); node(placeholder, 6, [6], []);
      if (mutation === 'pause-video') video.pause();
      if (mutation === 'pause-animation') prior.animation.pause();
      if (mutation === 'restart-video') video.currentTime = 0;
      if (mutation === 'restart-animation') prior.animation.currentTime = 0;
      let currentVideo = video;
      if (mutation === 'replace-video') { currentVideo = video.cloneNode(true); video.replaceWith(currentVideo); currentVideo.muted = true; await currentVideo.play(); }
      if (mutation === 'reload-frame') { const next = new Promise(resolve => { iframe.onload = resolve; }); iframe.setAttribute('src', '/startup-frame'); await next; }
      const attributes = (id, values) => values.flatMap(([key, value]) => [9, ...word(id), 3, ...text(''), ...text(key), 1, ...text(value)]);
      const element = (id, tag, attrs = []) => [8, ...word(id), ...word(0), ...word(0), ...htmlName(tag), 0, ...attributes(id, attrs)];
      const resourceBatch = [0, 28, 1, ...word(2), ...element(1, 'video', [['src', '/startup.webm'], ['muted', ''], ['loop', '']]), ...element(2, 'iframe', [['src', '/startup-frame']]), ...element(3, 'div', [['style', animation.getAttribute('style')]]), ...element(6, 'section'), 29];
      let resourceSets = 0;
      for (const target of [currentVideo, iframe]) { const original = target.setAttributeNS; target.setAttributeNS = function(namespace, name, value) { if (name === 'src') resourceSets++; return original.call(this, namespace, name, value); }; }
      const resourceHost = { ...host, init() { write(resourceBatch); return 0; }, event() { write([0, 5, ...word(6), ...element(7, 'button'), 30]); return 0; } };
      const resourceRuntime = new RocEngineRuntime(resourceHost, resources, { startupBuildToken: 'build', manualEffects: true }); resourceRuntime.mount();
      await new Promise(resolve => setTimeout(resolve, 240));
      const retainedAnimation = animation.getAnimations()[0];
      const accepted = !resourceRuntime.poisoned && resourceRuntime.lookup(1) === prior.video && !currentVideo.paused && currentVideo.currentTime - prior.time > .08 && retainedAnimation === prior.animation && retainedAnimation.playState === 'running' && retainedAnimation.currentTime - prior.animationTime > 80 && resourceRuntime.lookup(2) === prior.frame && iframe.contentDocument === prior.document && resourceSets === 0 && resourceRuntime.lookup(7)?.localName === 'button';
      check(`native resource continuity oracle ${mutation === 'none' ? 'accepts real handoff' : 'rejects ' + mutation}`, accepted === (mutation === 'none'));
      resourceRuntime.unmount(); resources.remove();
    }
    style.remove();
    for (const [name, body] of [
      ['legacy body has no trailing bytes', [0, 0]],
      ['unknown declaration profile', [2]],
      ['empty route catalogue', [1, ...htmlName('div'), ...word(0), ...word(0xffffffff)]],
      ['duplicate route paths', [1, ...htmlName('div'), ...word(2), ...text('/'), ...text('/'), ...word(0xffffffff)]],
      ['invalid fallback entry', [1, ...htmlName('div'), ...word(1), ...text('/'), ...word(2)]],
    ]) {
      write([...declarations.slice(0, declarations.length - 5 - startupDeclaration.length), ...section(14, body)]);
      const x = { ...host, boot_keys() {} }; let error = null;
      try { readDeclarations(x); } catch (caught) { error = caught; }
      check(name, error?.message.includes('section 14'));
    }
    return checks;
  }, [...protocolFixtureSection]);
  for (const [name, passed] of checks) { if (!passed) throw new Error(`FAIL ${name}`); console.log(`PASS ${name}`); }
} finally { await browser.close(); await new Promise(resolve => server.close(resolve)); }
