// Commands request a change; subscriptions report the browser's actual state.
// A released wake lock is never reacquired here: that decision belongs to Roc.
export function displayPorts(target) {
  let lock = null;
  let acquiring = false;
  let releasing = false;
  let enteringFullscreen = false;
  let generation = 0;
  const observers = new Set();
  const publish = () => { for (const ctx of observers) ctx.emit(lock !== null && !lock.released); };
  const release = async () => {
    generation += 1;
    if (releasing) return;
    const previous = lock;
    if (previous) {
      releasing = true;
      try {
        await previous.release();
        previous.removeEventListener("release", released);
        if (lock === previous) lock = null;
      } finally { releasing = false; }
    }
    publish();
  };
  const released = (event) => {
    const previous = event.currentTarget;
    previous.removeEventListener("release", released);
    if (lock === previous) { lock = null; publish(); }
  };
  return {
    "example.org/recipes/fullscreen": { command: async () => {
      if (!target.requestFullscreen) throw new Error("Fullscreen is unavailable");
      if (enteringFullscreen) throw new Error("A fullscreen request is already pending");
      enteringFullscreen = true;
      try { await target.requestFullscreen(); }
      finally { enteringFullscreen = false; }
    } },
    "example.org/recipes/fullscreen-state": { subscribe: (_, ctx) => {
      const changed = () => ctx.emit(document.fullscreenElement === target);
      const stop = () => {
        document.removeEventListener("fullscreenchange", changed);
        ctx.signal.removeEventListener("abort", stop);
      };
      document.addEventListener("fullscreenchange", changed);
      ctx.signal.addEventListener("abort", stop, { once: true });
      if (ctx.signal.aborted) stop(); else changed();
      return stop;
    } },
    "example.org/recipes/wake": { command: async (wanted) => {
      if (!wanted) { await release(); return; }
      if (releasing) throw new Error("A wake-lock release is already pending");
      if (lock && !lock.released) return;
      if (acquiring) throw new Error("A wake-lock request is already pending");
      if (!navigator.wakeLock?.request) throw new Error("Wake locks are unavailable");
      const requested = generation;
      acquiring = true;
      try {
        const answer = await navigator.wakeLock.request("screen");
        if (requested !== generation || observers.size === 0) { await answer.release(); return; }
        lock = answer;
        lock.addEventListener("release", released);
        publish();
      } finally { acquiring = false; }
    } },
    "example.org/recipes/wake-state": { subscribe: (_, ctx) => {
      // The sample mounts one observation. Runtime admission bounds this set
      // by its program's in-flight limit; it retains no history of observers.
      const stop = () => {
        observers.delete(ctx);
        ctx.signal.removeEventListener("abort", stop);
        if (observers.size === 0) {
          // Invalidate a permission answer that outlives its last observer.
          release().catch((error) => console.error("Wake-lock cleanup failed", error));
        }
      };
      observers.add(ctx);
      ctx.signal.addEventListener("abort", stop, { once: true });
      if (ctx.signal.aborted) stop(); else ctx.emit(lock !== null && !lock.released);
      return stop;
    } },
  };
}
