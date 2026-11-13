function position(value) {
  const { latitude, longitude, accuracy } = value.coords;
  if (![latitude, longitude, accuracy].every(Number.isFinite)) throw new Error("Invalid geolocation coordinates");
  return { latitude, longitude, accuracy };
}

function watch(ctx, receive, fail) {
  if (!navigator.geolocation) throw new Error("Geolocation is unavailable");
  let active = true;
  let id = null;
  const stop = () => {
    active = false;
    if (id !== null) navigator.geolocation.clearWatch(id);
    id = null;
    ctx.signal.removeEventListener("abort", stop);
  };
  ctx.signal.addEventListener("abort", stop, { once: true });
  if (ctx.signal.aborted) { stop(); return stop; }
  // A one-shot call also uses a watch, so abort can actually cancel it.
  id = navigator.geolocation.watchPosition(
    (value) => { if (active) { try { receive(position(value), stop); } catch (error) { stop(); fail(error); } } },
    (error) => { if (active) { stop(); fail(new Error(error.message)); } },
    { maximumAge: 0 },
  );
  if (!active && id !== null) { navigator.geolocation.clearWatch(id); id = null; }
  return stop;
}

export const geolocationPorts = {
  "example.org/recipes/location": { call: (_, ctx) => new Promise((resolve, reject) => {
    const aborted = () => reject(ctx.signal.reason ?? new DOMException("Cancelled", "AbortError"));
    ctx.signal.addEventListener("abort", aborted, { once: true });
    const done = (fn, value) => { ctx.signal.removeEventListener("abort", aborted); fn(value); };
    if (ctx.signal.aborted) { done(reject, ctx.signal.reason); return; }
    try { watch(ctx, (value, stop) => { stop(); done(resolve, value); }, (error) => done(reject, error)); }
    catch (error) { done(reject, error); }
  }) },
  "example.org/recipes/positions": { subscribe: (_, ctx) => watch(ctx, (value) => ctx.emit(value), (error) => ctx.close(error)) },
};
