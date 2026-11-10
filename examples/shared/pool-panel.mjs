// <worker-pool-panel>: a live view of the runtime's worker pool, drawn from
// the runtime's documented monitor (`runtime.monitor`: `snapshot()`,
// `subscribe()`, `reset()`; see the "Monitoring Workers" docs page).
//
// Shared example JavaScript: any example's page loads it by naming it as a
// `shared` script in www/data/examples.toml. An app (the Worker Lab, for
// one) renders this as an ordinary empty element; the engine and the
// runtime know nothing about it. It learns which runtime to watch from
// the `roc-signals:runtime` event that the page mounting the app dispatches
// on the mount root (its `detail.runtime`), and draws into its own shadow
// root, so the engine's children of the element stay the engine's. It only
// reads: it never changes which job runs when. Leaving the document
// unsubscribes it.
//
// It also times the page's own animation frames, to show what a busy main
// thread looks like: the longest gap between two frames over the last few
// seconds. With jobs in workers it stays near one frame; with
// `workers: "inline"` it grows to the length of a job.
const RECENT = 8;
const GAP_WINDOW_MS = 5000;
const POOL_SIZES = [1, 2, 4, 8];

const STYLE = `
  :host { display: block; }
  section { border: 1px solid #e4e4e7; border-radius: 0.75rem; background: #fff; padding: 1.25rem; display: grid; gap: 1rem; font: 14px/1.4 ui-sans-serif, system-ui, sans-serif; color: #18181b; }
  h2 { margin: 0; font-size: 1rem; font-weight: 600; }
  .head { display: flex; flex-wrap: wrap; align-items: baseline; justify-content: space-between; gap: 0.5rem; }
  .muted { color: #71717a; font-size: 0.8rem; }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(7.5rem, 1fr)); gap: 0.5rem; }
  .stat { border: 1px solid #f4f4f5; border-radius: 0.5rem; padding: 0.5rem 0.75rem; background: #fafafa; }
  .stat b { display: block; font-size: 1.25rem; font-variant-numeric: tabular-nums; }
  .bar { height: 0.5rem; border-radius: 999px; background: #f4f4f5; overflow: hidden; }
  .bar i { display: block; height: 100%; background: #059669; }
  .slots { display: flex; flex-wrap: wrap; gap: 0.25rem; }
  .slot { width: 1.25rem; height: 1.25rem; border-radius: 0.25rem; background: #e4e4e7; }
  .slot.busy { background: #059669; }
  .slot.queued { background: #f59e0b; }
  table { width: 100%; border-collapse: collapse; font-variant-numeric: tabular-nums; }
  th, td { text-align: left; padding: 0.2rem 0.4rem; border-bottom: 1px solid #f4f4f5; font-size: 0.8rem; }
  th { color: #71717a; font-weight: 500; }
  td.n, th.n { text-align: right; }
  nav { display: flex; flex-wrap: wrap; gap: 0.5rem; align-items: center; font-size: 0.8rem; }
  nav a { color: #047857; }
  button { font: inherit; font-size: 0.8rem; padding: 0.2rem 0.6rem; border-radius: 0.375rem; border: 1px solid #d4d4d8; background: #fff; cursor: pointer; }
`;

const ms = (v) => (v == null || !Number.isFinite(v) ? "–" : v < 10 ? v.toFixed(1) : Math.round(v).toString());
const pct = (v) => (Number.isFinite(v) ? `${Math.round(v * 100)}%` : "–");
const shortName = (task) => task.split("/").pop();

class WorkerPoolPanel extends HTMLElement {
  #runtime = null;
  #unsubscribe = null;
  #onRuntime = (e) => {
    if (e.target instanceof Node && e.target.contains(this)) this.#watch(e.detail.runtime);
  };
  #pending = false;
  #frames = [];
  #rafId = 0;
  #timer = 0;
  #body = null;

  connectedCallback() {
    if (!this.shadowRoot) {
      const root = this.attachShadow({ mode: "open" });
      const style = document.createElement("style");
      style.textContent = STYLE;
      this.#body = document.createElement("section");
      root.append(style, this.#body);
    }
    document.addEventListener("roc-signals:runtime", this.#onRuntime);
    this.#draw();
  }

  disconnectedCallback() {
    document.removeEventListener("roc-signals:runtime", this.#onRuntime);
    this.#stop();
  }

  #watch(runtime) {
    this.#stop();
    this.#runtime = runtime;
    this.#unsubscribe = runtime.monitor.subscribe(() => this.#schedule());
    const frame = (t) => {
      this.#frames.push(t);
      while (this.#frames.length > 2 && t - this.#frames[0] > GAP_WINDOW_MS) this.#frames.shift();
      this.#rafId = requestAnimationFrame(frame);
    };
    this.#rafId = requestAnimationFrame(frame);
    // The time integrals (utilisation, mean queue) move without events.
    this.#timer = setInterval(() => this.#schedule(), 500);
    this.#schedule();
  }

  #stop() {
    this.#unsubscribe?.();
    this.#unsubscribe = null;
    cancelAnimationFrame(this.#rafId);
    clearInterval(this.#timer);
    this.#runtime = null;
    this.#frames = [];
  }

  // At most one redraw per frame, however many events arrive.
  #schedule() {
    if (this.#pending) return;
    this.#pending = true;
    requestAnimationFrame(() => {
      this.#pending = false;
      this.#draw();
    });
  }

  #longestGap() {
    let gap = 0;
    for (let i = 1; i < this.#frames.length; i += 1) gap = Math.max(gap, this.#frames[i] - this.#frames[i - 1]);
    return this.#frames.length > 1 ? gap : null;
  }

  #links() {
    const nav = document.createElement("nav");
    nav.append("Mount again with: ");
    const here = new URL(window.location.href);
    const link = (label, set) => {
      const u = new URL(here);
      u.searchParams.delete("maxWorkers");
      u.searchParams.delete("workers");
      set(u.searchParams);
      const a = document.createElement("a");
      a.href = u.href;
      a.textContent = label;
      nav.append(a);
    };
    for (const n of POOL_SIZES) link(`${n} worker${n === 1 ? "" : "s"}`, (q) => q.set("maxWorkers", String(n)));
    link("the page's thread (inline)", (q) => q.set("workers", "inline"));
    const reset = document.createElement("button");
    reset.type = "button";
    reset.textContent = "Reset measurements";
    reset.addEventListener("click", () => {
      this.#runtime?.monitor.reset();
      this.#schedule();
    });
    nav.append(reset);
    return nav;
  }

  #draw() {
    const body = this.#body;
    if (!body) return;
    const rt = this.#runtime;
    if (rt === null) {
      body.innerHTML = "<h2>Worker pool</h2><p class=\"muted\">Waiting for the page to announce its runtime.</p>";
      return;
    }
    const s = rt.monitor.snapshot();
    const span = Math.max(s.at - s.since, 1e-9);
    const util = s.pool.aliveMs > 0 ? s.pool.busyMs / s.pool.aliveMs : NaN;
    const stat = (label, value, title = "") => `<div class="stat" title="${title}">${label}<b>${value}</b></div>`;
    const slots = [];
    const workers = s.mode === "inline" ? 1 : s.maxWorkers;
    for (let i = 0; i < workers; i += 1) slots.push(`<span class="slot ${i < s.pool.busy ? "busy" : ""}"></span>`);
    for (let i = 0; i < s.pool.queued; i += 1) slots.push("<span class=\"slot queued\"></span>");
    const rows = s.recent
      .slice(-RECENT)
      .reverse()
      .map((j) => `<tr><td>${j.id}</td><td>${shortName(j.task)}</td><td>${j.outcome ?? "…"}</td><td class="n">${ms(j.ms.queue)}</td><td class="n">${ms(j.ms.compute)}</td><td class="n">${ms(j.ms.total)}</td></tr>`)
      .join("");
    body.innerHTML = `
      <div class="head"><h2>Worker pool</h2><span class="muted">${s.mode === "inline" ? "inline, on the page's thread" : `${s.mode}, up to ${s.maxWorkers} workers`} ·measured over ${ms(span / 1000)} s</span></div>
      <div class="slots" title="green: a busy worker; grey: an idle or not yet started one; amber: a queued job">${slots.join("")}</div>
      <div class="grid">
        ${stat("Busy", s.pool.busy)}${stat("Idle", s.pool.idle)}${stat("Queued", s.pool.queued)}
        ${stat("Peak busy", s.pool.peak.busy)}${stat("Peak queued", s.pool.peak.queued)}
        ${stat("Utilisation", pct(util), "busy time over the time workers were alive")}
        ${stat("Mean queue", (s.pool.queuedMs / span).toFixed(2), "jobs waiting, on average")}
        ${stat("Done", s.jobs.done)}${stat("Cancelled", s.jobs.cancelled)}${stat("Lost", s.jobs.lost)}${stat("Timed out", s.jobs.timeout)}
        ${stat("Wasted ms", ms(s.jobs.wastedMs), "worker time spent on jobs that delivered nothing")}
        ${stat("Spawns", s.instances.spawns)}${stat("Respawns", s.instances.respawns)}
        ${stat("Longest frame gap", `${ms(this.#longestGap())} ms`, "the page's longest pause between animation frames over the last 5 s")}
      </div>
      <div class="bar" title="utilisation"><i style="width:${Number.isFinite(util) ? Math.min(100, util * 100) : 0}%"></i></div>
      <table><thead><tr><th>Job</th><th>Task</th><th>Outcome</th><th class="n">Queue ms</th><th class="n">Compute ms</th><th class="n">Total ms</th></tr></thead><tbody>${rows}</tbody></table>`;
    body.append(this.#links());
  }
}

customElements.define("worker-pool-panel", WorkerPoolPanel);
