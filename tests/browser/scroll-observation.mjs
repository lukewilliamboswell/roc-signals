// Runs in the page. Only a real frame and its following task admit scroll
// observations; expiration is a failure, never a substitute callback.
export async function observeManualScrolls(deadline) {
  const rt = window.__rt;
  if (rt?.manualScrollers?.size) {
    let frame, task, timer;
    const starved = () => new Error(`scroll observation received no animation frame before its idle deadline (visibility=${document.visibilityState}, focused=${document.hasFocus()})`);
    try {
      await new Promise((resolve, reject) => {
        const remaining = deadline - Date.now();
        if (remaining <= 0) { reject(starved()); return; }
        timer = setTimeout(() => reject(starved()), remaining);
        frame = requestAnimationFrame(() => { task = setTimeout(() => Date.now() >= deadline ? reject(starved()) : resolve(), 0); });
      });
    } finally {
      if (frame !== undefined) cancelAnimationFrame(frame);
      clearTimeout(task); clearTimeout(timer);
    }
  }
  rt?.checkManualScrolls();
}
