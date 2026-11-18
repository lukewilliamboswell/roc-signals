// Test-only native resource transport and continuity observation. This module
// is never part of the platform runtime or an application's dependencies.
export function resourceReply({ method, range, type, body }) {
  const headers = { 'content-type': type, 'cache-control': 'no-store', 'accept-ranges': 'bytes' };
  let start = 0, end = body.length - 1, status = 200;
  if (method === 'GET' && range !== undefined) {
    const match = /^bytes=(\d*)-(\d*)$/.exec(range);
    const first = match?.[1] ? Number(match[1]) : null, last = match?.[2] ? Number(match[2]) : null;
    if (!match || first === null && last === null || first !== null && !Number.isSafeInteger(first) || last !== null && !Number.isSafeInteger(last) || first === null && last === 0) {
      return { status: 416, headers: { ...headers, 'content-range': `bytes */${body.length}`, 'content-length': 0 }, body: null };
    }
    start = first === null ? Math.max(0, body.length - last) : first;
    end = first === null || last === null ? end : Math.min(last, end);
    if (start >= body.length || end < start) return { status: 416, headers: { ...headers, 'content-range': `bytes */${body.length}`, 'content-length': 0 }, body: null };
    status = 206; headers['content-range'] = `bytes ${start}-${end}/${body.length}`;
  }
  headers['content-length'] = Math.max(0, end - start + 1);
  return { status, headers, body: method === 'HEAD' ? null : body.subarray(start, end + 1) };
}

export function mediaState(video) {
  if (!video) return null;
  const number = value => Number.isFinite(value) ? value : String(value);
  const ranges = value => Array.from({ length: Math.min(value.length, 16) }, (_, at) => [number(value.start(at)), number(value.end(at))]);
  return { currentTime: number(video.currentTime), duration: number(video.duration), currentSrc: video.currentSrc, paused: video.paused, ended: video.ended, readyState: video.readyState, networkState: video.networkState, buffered: ranges(video.buffered), played: ranges(video.played), error: video.error ? { code: video.error.code, message: video.error.message } : null };
}

// Observe only after playback has demonstrably progressed. Range downloads
// and native loop seeks do not restart loading or interrupt playing.
export function observePlayback(video) {
  const lifecycle = { loadstart: 0, emptied: 0, abort: 0, error: 0, pause: 0, play: 0 }, events = [];
  const record = event => { if (event.type in lifecycle) lifecycle[event.type]++; if (events.length < 32) events.push({ type: event.type, time: video.currentTime }); };
  const names = [...Object.keys(lifecycle), 'seeking', 'seeked'];
  for (const name of names) video.addEventListener(name, record);
  return { video, source: video.currentSrc, time: video.currentTime, clock: performance.now(), lifecycle, events, stop() { for (const name of names) video.removeEventListener(name, record); } };
}

export function playbackContinuity(observed, current = observed.video) {
  const elapsed = (performance.now() - observed.clock) / 1000;
  const delta = current.currentTime - observed.time;
  const progress = Number.isFinite(current.duration) && current.duration > 0 ? (delta + current.duration) % current.duration : delta;
  // The upper bound rejects a restart disguised as a whole-clip wrap. Normal
  // loop crossings remain valid without requiring exact clock equality.
  const accepted = current === observed.video && current.isConnected && current.currentSrc === observed.source && !current.paused && current.error === null && Object.values(observed.lifecycle).every(count => count === 0) && progress > .08 && progress <= elapsed * Math.abs(current.playbackRate) + .5;
  return { accepted, before: observed.time, after: current.currentTime, progress, elapsed, lifecycle: { ...observed.lifecycle }, events: observed.events.slice(), media: mediaState(current) };
}
