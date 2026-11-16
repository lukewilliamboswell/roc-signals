// Browser-resource races and bounded handler queues, without real permissions.
import assert from "node:assert/strict";
import { socketPorts } from "../../www/samples/port-recipes/sockets.mjs";
import { formatDates } from "../../www/samples/port-recipes/dates.mjs";
import { geolocationPorts } from "../../www/samples/port-recipes/geolocation.mjs";
import { registerCamera, mediaPorts } from "../../www/samples/port-recipes/media.mjs";
import { displayPorts } from "../../www/samples/port-recipes/display.mjs";
import { notificationPorts } from "../../www/samples/port-recipes/notifications.mjs";
import { sharePorts } from "../../www/samples/port-recipes/share.mjs";
import { registerGauge } from "../../www/samples/port-recipes/gauge.mjs";
import { clipboardReadPorts } from "../../www/samples/port-recipes/clipboard-read.mjs";
import { createPorts } from "../../www/samples/port-recipes/ports.mjs";

const saved = new Map();
function global(name, value) {
  if (!saved.has(name)) saved.set(name, Object.getOwnPropertyDescriptor(globalThis, name));
  Object.defineProperty(globalThis, name, { value, configurable: true, writable: true });
}
const settle = async () => { await Promise.resolve(); await Promise.resolve(); };
const context = () => {
  const ctl = new AbortController();
  return { ctl, signal: ctl.signal, values: [], errors: [], emit(value) { this.values.push(value); return true; }, close(error) { this.errors.push(error); } };
};
let checks = 0;
const checked = (name) => { checks += 1; console.log(`ok ${name}`); };
try {
  const frames = new Map(), timers = new Map();
  let next = 0;
  global("requestAnimationFrame", (fn) => { frames.set(++next, fn); return next; });
  global("cancelAnimationFrame", (id) => frames.delete(id));
  global("setTimeout", (fn) => { timers.set(++next, fn); return next; });
  global("clearTimeout", (id) => timers.delete(id));
  function flush(map) { const [id, fn] = map.entries().next().value; map.delete(id); fn(); }
  class Source {
    static OPEN = 1;
    static instances = [];
    constructor(url) { this.url = url; this.readyState = 1; this.bufferedAmount = 0; this.closed = false; this.sent = []; Source.instances.push(this); }
    close() { this.closed = true; }
    send(text) { this.sent.push(text); }
  }
  global("location", { href: "https://example.org/recipes/" });
  global("EventSource", Source);
  global("WebSocket", Source);
  const ports = socketPorts();
  const ctx = context();
  let budget = 0;
  ctx.emit = (value) => { if (budget === 0) return false; budget -= 1; ctx.values.push(value); return true; };
  ports["example.org/recipes/sse"].subscribe({ url: "/events", after: "12" }, ctx);
  const source = Source.instances.at(-1);
  assert.equal(new URL(source.url).searchParams.get("after"), "12");
  source.onopen();
  for (let i = 1; i <= 100; i += 1) source.onmessage({ lastEventId: String(i), data: `event ${i}` });
  assert.equal(frames.size, 1); assert.equal(timers.size, 1);
  // A hidden tab's timer must retry even if no animation frame runs.
  budget = 16; flush(timers);
  assert.equal(ctx.values.length, 16);
  while (frames.size) { budget = 16; flush(frames); }
  const events = ctx.values.filter((v) => v.Event).map((v) => v.Event);
  assert.equal(events.length, 64);
  assert.equal(events[0].seq, "37"); assert.equal(events.at(-1).seq, "100");
  assert.ok(events.every((v) => v.dropped === "36"));
  ctx.ctl.abort(); assert.equal(source.closed, true); assert.equal(frames.size + timers.size, 0);
  checked("count-bound drops, Every16 backpressure, hidden timer and abort cleanup");

  const bytesCtx = context();
  const bytesStop = ports["example.org/recipes/sse"].subscribe({ url: "/events", after: "0" }, bytesCtx);
  const bytesSource = Source.instances.at(-1);
  for (let i = 1; i <= 20; i += 1) bytesSource.onmessage({ lastEventId: String(i), data: "x".repeat(16000) });
  while (frames.size) {
    const before = bytesCtx.values.length; flush(frames);
    const sent = bytesCtx.values.slice(before).reduce((n, value) => n + new TextEncoder().encode(JSON.stringify(value)).length, 0);
    assert.ok(sent <= 65536);
  }
  assert.equal(bytesCtx.values.length, 4); assert.equal(bytesCtx.values[0].Event.dropped, "16");
  bytesStop(); checked("cumulative queue and per-frame byte bounds count whole dropped messages");

  const ws = context();
  ports["example.org/recipes/websocket"].subscribe({ url: "/socket", after: "0" }, ws);
  const socket = Source.instances.at(-1);
  ports["example.org/recipes/socket-send"].command({ connection: "primary", data: "hello" });
  assert.deepEqual(socket.sent, ["hello"]);
  socket.bufferedAmount = 65536;
  assert.throws(() => ports["example.org/recipes/socket-send"].command({ connection: "primary", data: "hello" }), /buffer is full/);
  socket.onmessage({ data: "not JSON" });
  assert.equal(socket.closed, true); assert.equal(ws.errors.length, 1);
  checked("named primary sends and malformed frames end their connection");

  const large = context();
  ports["example.org/recipes/sse"].subscribe({ url: "/events", after: "0" }, large);
  const largeSource = Source.instances.at(-1);
  largeSource.onmessage({ lastEventId: "1", data: "x".repeat(65537) });
  assert.equal(largeSource.closed, true); assert.equal(large.errors.length, 1);
  const errorCtx = context();
  errorCtx.close = () => assert.equal(Source.instances.at(-1).closed, true);
  ports["example.org/recipes/sse"].subscribe({ url: "/events", after: "0" }, errorCtx);
  Source.instances.at(-1).onerror();
  checked("oversized frames fail explicitly; SSE closes before reporting error");

  for (const [transport, event] of [
    ["websocket", { data: JSON.stringify({ seq: "1", data: "\ud800" }) }],
    ["sse", { lastEventId: "1", data: "\udc00" }],
  ]) {
    const bad = context();
    ports[`example.org/recipes/${transport}`].subscribe({ url: "/events", after: "0" }, bad);
    const malformed = Source.instances.at(-1);
    malformed.onmessage(event);
    assert.equal(malformed.closed, true);
    assert.equal(bad.values.length, 0);
    assert.match(bad.errors[0].message, /well-formed/);
  }
  checked("malformed Unicode frames fail without substituting replacement text");

  assert.throws(() => formatDates({ languages: ["en-US"], zone: "UTC", instants: ["9223372036854775807"] }), RangeError);
  assert.throws(() => formatDates({ languages: ["en-US"], zone: "UTC", instants: [0] }));
  assert.equal(formatDates({ languages: ["en-US"], zone: "UTC", instants: ["0", "-1"] }).length, 2);
  assert.equal(formatDates({ languages: ["en-US"], zone: "UTC", instants: Array(256).fill("0") }).length, 256);
  assert.throws(() => formatDates({ languages: ["en-US"], zone: "UTC", instants: Array(257).fill("0") }), /at most 256/);
  checked("date batching accepts exact decimal milliseconds and rejects before lossy conversion");

  const watches = new Map(); let watchId = 0;
  const navigator = { geolocation: {
    watchPosition(ok, error) { watches.set(++watchId, { ok, error }); return watchId; },
    clearWatch(id) { watches.delete(id); },
  } };
  global("navigator", navigator);
  const one = context();
  const positionAnswer = geolocationPorts["example.org/recipes/location"].call({}, one);
  watches.get(watchId).ok({ coords: { latitude: 1, longitude: 2, accuracy: 3 } });
  assert.deepEqual(await positionAnswer, { latitude: 1, longitude: 2, accuracy: 3 });
  assert.equal(watches.size, 0);
  const watch = context();
  geolocationPorts["example.org/recipes/positions"].subscribe({}, watch); watch.ctl.abort();
  assert.equal(watches.size, 0);
  const aborted = context();
  const answer = geolocationPorts["example.org/recipes/location"].call({}, aborted);
  aborted.ctl.abort(); await assert.rejects(answer); assert.equal(watches.size, 0);
  checked("one-shot and Latest geolocation clearWatch on answer and cancellation");

  const types = new Map();
  global("customElements", { get: (name) => types.get(name), define: (name, type) => types.set(name, type) });
  class Element {
    isConnected = true;
    attributes = new Map();
    attachShadow() { return { append() {} }; }
    getAttribute(name) { return this.attributes.get(name) ?? null; }
  }
  global("HTMLElement", Element);
  const document = new EventTarget();
  document.createElement = (tag) => ({ style: {}, setAttribute() {}, getContext: () => ({ clearRect() {}, beginPath() {}, arc() {}, stroke() {}, fillText() {} }) });
  document.fullscreenElement = null;
  global("document", document);
  registerCamera(); registerGauge();
  let permission;
  navigator.mediaDevices = { getUserMedia: () => new Promise((resolve) => { permission = resolve; }) };
  const camera = new (types.get("recipe-camera"))();
  const media = mediaPorts(camera)["example.org/recipes/camera"];
  const capture = context();
  media.subscribe({}, capture); capture.ctl.abort();
  assert.throws(() => media.subscribe({}, context()), /pending permission/);
  let stopped = 0;
  const track = new EventTarget(); track.stop = () => { stopped += 1; };
  permission({ getTracks: () => [track] }); await settle();
  assert.equal(stopped, 1); assert.equal(camera.video.srcObject, null);
  const active = context(); media.subscribe({}, active);
  permission({ getTracks: () => [track] }); await settle();
  assert.deepEqual(active.values, ["Starting", "Active"]);
  track.dispatchEvent(new Event("ended"));
  assert.equal(stopped, 2); assert.equal(active.values.at(-1), "Ended"); assert.equal(active.errors.length, 1);
  checked("camera bounds pending permissions and stops late or ended streams");

  const gauge = new (types.get("recipe-gauge"))();
  gauge.attributes.set("data-value", "100"); gauge.attributes.set("data-animate", "true");
  gauge.connectedCallback(); assert.equal(frames.size, 1);
  gauge.disconnectedCallback(); assert.equal(frames.size, 0);
  checked("canvas element cancels its owned animation frame on disconnect");

  let acquire;
  navigator.wakeLock = { request: () => new Promise((resolve) => { acquire = resolve; }) };
  const display = displayPorts({ requestFullscreen: async () => {} });
  const observer = context(); display["example.org/recipes/wake-state"].subscribe({}, observer);
  const pending = display["example.org/recipes/wake"].command(true);
  await assert.rejects(display["example.org/recipes/wake"].command(true), /pending/);
  observer.ctl.abort();
  const sentinel = new EventTarget(); sentinel.released = false;
  let released = 0; sentinel.release = async () => { released += 1; sentinel.released = true; sentinel.dispatchEvent(new Event("release")); };
  acquire(sentinel); await pending; assert.equal(released, 1);
  checked("wake acquisition is bounded and a late answer releases after unsubscribe");

  global("Notification", class { static permission = "granted"; static requestPermission = async () => "default"; });
  assert.equal(await notificationPorts()["example.org/recipes/notification-permission"].call({}), "Dismissed");
  navigator.share = async () => { throw new DOMException("User cancelled", "AbortError"); };
  assert.equal(await sharePorts()["example.org/recipes/share"].call({}), "Cancelled");
  navigator.share = async () => { throw new Error("denied"); };
  await assert.rejects(sharePorts()["example.org/recipes/share"].call({}), /denied/);
  assert.equal(Object.keys(createPorts({ camera, fullscreenTarget: {} })).length, 15);
  checked("permission dismissal and share cancellation are data; denial remains a failure; all 15 ports provided");

  let allowed;
  Notification.requestPermission = () => new Promise((resolve) => { allowed = resolve; });
  const permissions = notificationPorts()["example.org/recipes/notification-permission"];
  const firstPermission = permissions.call({});
  await assert.rejects(permissions.call({}), /already pending/);
  allowed("granted"); assert.equal(await firstPermission, "Granted");
  let shared;
  navigator.share = () => new Promise((resolve) => { shared = resolve; });
  const sharing = sharePorts()["example.org/recipes/share"];
  const firstShare = sharing.call({});
  await assert.rejects(sharing.call({}), /already pending/);
  shared(); assert.equal(await firstShare, "Shared");
  let copied;
  navigator.clipboard = { readText: () => new Promise((resolve) => { copied = resolve; }) };
  const reading = clipboardReadPorts()["example.org/recipes/clipboard-read"];
  const firstRead = reading.call({});
  await assert.rejects(reading.call({}), /already pending/);
  copied("clipboard text"); assert.equal(await firstRead, "clipboard text");
  checked("uncancellable notification, share and clipboard permission requests each have one pending slot");

  const target = {};
  const observedDisplay = displayPorts(target);
  const fullscreen = context();
  observedDisplay["example.org/recipes/fullscreen-state"].subscribe({}, fullscreen);
  document.fullscreenElement = target; document.dispatchEvent(new Event("fullscreenchange"));
  assert.deepEqual(fullscreen.values, [false, true]);
  fullscreen.ctl.abort(); document.fullscreenElement = null; document.dispatchEvent(new Event("fullscreenchange"));
  assert.equal(fullscreen.values.length, 2);
  let requests = 0;
  const held = new EventTarget(); held.released = false;
  held.release = async () => { held.released = true; held.dispatchEvent(new Event("release")); };
  navigator.wakeLock = { request: async () => { requests += 1; return held; } };
  const awake = context(); observedDisplay["example.org/recipes/wake-state"].subscribe({}, awake);
  await observedDisplay["example.org/recipes/wake"].command(true);
  held.released = true; held.dispatchEvent(new Event("release")); await settle();
  assert.deepEqual(awake.values, [false, true, false]); assert.equal(requests, 1);
  awake.ctl.abort();
  checked("actual fullscreen and wake state is observed; release causes no JavaScript reacquisition");

  let finishRelease;
  let releaseCalls = 0;
  const slow = new EventTarget(); slow.released = false;
  slow.release = () => { releaseCalls += 1; return new Promise((resolve) => { finishRelease = resolve; }); };
  navigator.wakeLock = { request: async () => slow };
  const boundedDisplay = displayPorts({});
  const watching = context();
  const unsubscribe = boundedDisplay["example.org/recipes/wake-state"].subscribe({}, watching);
  await boundedDisplay["example.org/recipes/wake"].command(true);
  const releasing = boundedDisplay["example.org/recipes/wake"].command(false);
  await boundedDisplay["example.org/recipes/wake"].command(false);
  watching.ctl.abort(); unsubscribe();
  assert.equal(releaseCalls, 1);
  slow.released = true; slow.dispatchEvent(new Event("release"));
  await assert.rejects(boundedDisplay["example.org/recipes/wake"].command(true), /release is already pending/);
  finishRelease(); await releasing;
  assert.equal(releaseCalls, 1);
  checked("repeated release commands and abort plus unsubscribe share one pending native release");


  console.log(`${checks} port recipe handler checks passed`);
} finally {
  for (const [name, descriptor] of saved) {
    if (descriptor) Object.defineProperty(globalThis, name, descriptor); else delete globalThis[name];
  }
}
