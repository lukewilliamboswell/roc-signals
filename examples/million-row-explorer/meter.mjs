// <query-meter data-task="NAME" data-port="NAME" data-shards="N">: what the
// runtime measured of the explorer's questions, drawn from its documented
// monitor (`runtime.monitor`; see the "Monitoring Workers" docs page).
//
// The Million-Row Explorer's own JavaScript, named as a script in
// www/data/examples.toml. The app renders it as an ordinary empty element
// with three attributes; the engine and the runtime know nothing about it.
// It learns which runtime to watch from the `roc-signals:runtime` event the
// page that mounts the app dispatches on the mount root, draws into its own
// shadow root, and only reads: it never changes which job runs when.
//
// A question is the jobs of the task `data-task` issued in one turn (the
// gather asks every shard at once). Its time runs from the first job's
// issue to the last job's end, which comes after its result turn has been
// applied, so it is what the user waits for. A question whose jobs were
// cancelled was superseded. Beside it: how many jobs prepared a shard and
// how many reused one, states replaced and workers retired, and the feed's
// port counters.
const KEEP = 32;

const STYLE = `
  :host { display: block; }
  section { border: 1px solid #e4e4e7; border-radius: 0.75rem; background: #fff; padding: 1.25rem; display: grid; gap: 0.75rem; font: 14px/1.4 ui-sans-serif, system-ui, sans-serif; color: #18181b; }
  h2 { margin: 0; font-size: 1rem; font-weight: 600; }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(9rem, 1fr)); gap: 0.5rem; }
  .stat { border: 1px solid #f4f4f5; border-radius: 0.5rem; padding: 0.5rem 0.75rem; background: #fafafa; }
  .stat b { display: block; font-size: 1.25rem; font-variant-numeric: tabular-nums; }
  .muted { color: #71717a; font-size: 0.8rem; }
  .warn { color: #b45309; font-size: 0.85rem; }
`;

const ms = (v) => (v == null || !Number.isFinite(v) ? "–" : v < 10 ? v.toFixed(1) : Math.round(v).toString());
const median = (xs) => {
  if (xs.length === 0) return null;
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.floor(s.length / 2)];
};

class QueryMeter extends HTMLElement {
  #runtime = null;
  #unsubscribe = null;
  #onRuntime = (e) => {
    if (e.target instanceof Node && e.target.contains(this)) this.#watch(e.detail.runtime);
  };
  #body = null;
  #pending = false;
  #timer = 0;
  // The question being issued in this turn, and those not yet ended.
  #issuing = null;
  #open = new Map();
  #questions = [];
  #superseded = 0;

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
    this.#unsubscribe = runtime.monitor.subscribe((e) => this.#observe(e));
    // The feed's counters move without job events.
    this.#timer = setInterval(() => this.#schedule(), 500);
    this.#schedule();
  }

  #stop() {
    this.#unsubscribe?.();
    this.#unsubscribe = null;
    clearInterval(this.#timer);
    this.#runtime = null;
    this.#open.clear();
    this.#issuing = null;
  }

  #observe(e) {
    const task = this.dataset.task;
    if (e.kind === "job-issue" && e.task === task) {
      if (this.#issuing === null) {
        this.#issuing = { issued: e.at, ids: new Set(), ended: [], cancelled: false };
        // Jobs issued by one turn arrive together: the question closes at
        // the end of the current task.
        const question = this.#issuing;
        queueMicrotask(() => {
          if (this.#issuing === question) this.#issuing = null;
        });
      }
      this.#issuing.ids.add(e.id);
      this.#open.set(e.id, this.#issuing);
    } else if (e.kind === "job-end" && this.#open.has(e.id)) {
      const question = this.#open.get(e.id);
      this.#open.delete(e.id);
      question.ended.push(e.record);
      if (e.outcome === "cancelled") question.cancelled = true;
      if (question.ended.length === question.ids.size) this.#finish(question, e.at);
    }
    this.#schedule();
  }

  #finish(question, at) {
    if (question.cancelled || question.ended.some((r) => r.outcome !== "done")) {
      this.#superseded += 1;
      return;
    }
    this.#questions.push({
      ms: at - question.issued,
      slowest: Math.max(...question.ended.map((r) => r.ms.compute ?? 0)),
      prepared: question.ended.filter((r) => r.prepared === "prepare").length,
    });
    if (this.#questions.length > KEEP) this.#questions.shift();
  }

  #schedule() {
    if (this.#pending) return;
    this.#pending = true;
    requestAnimationFrame(() => {
      this.#pending = false;
      this.#draw();
    });
  }

  #draw() {
    const body = this.#body;
    if (!body) return;
    const rt = this.#runtime;
    if (rt === null) {
      body.innerHTML = '<h2>Measured</h2><p class="muted">Waiting for the page to announce its runtime.</p>';
      return;
    }
    const s = rt.monitor.snapshot();
    const shards = Number(this.dataset.shards ?? "0");
    const last = this.#questions.at(-1);
    const warm = this.#questions.filter((q) => q.prepared === 0).map((q) => q.ms);
    const port = s.ports?.[this.dataset.port] ?? null;
    const workers = s.mode === "inline" ? 1 : s.maxWorkers;
    const stat = (label, value, title = "") => `<div class="stat" title="${title}">${label}<b>${value}</b></div>`;
    const warning =
      workers < shards
        ? `<p class="warn">${s.mode === "inline" ? "Jobs run on the page's thread, one instance" : `${workers} worker${workers === 1 ? "" : "s"}`} for ${shards} shards: an instance keeps one shard, so most questions generate shards again (see "Prepared").</p>`
        : "";
    body.innerHTML = `
      <h2>Measured</h2>
      <p class="muted">${s.mode === "inline" ? "Jobs on the page's thread" : `Up to ${s.maxWorkers} workers`}, ${shards} shards. Times from the runtime's monitor, issue to the applied answer.</p>
      ${warning}
      <div class="grid">
        ${stat("Last question", last ? `${ms(last.ms)} ms` : "–", "from the first shard's job being asked for to the last shard's answer on the page")}
        ${stat("Median warm question", warm.length ? `${ms(median(warm))} ms` : "–", `over the last ${KEEP} questions that generated no shard`)}
        ${stat("Slowest shard, last", last ? `${ms(last.slowest)} ms` : "–", "the longest summary computed by one worker for the last question")}
        ${stat("Questions answered", this.#questions.length === KEEP ? `${KEEP}+` : this.#questions.length)}
        ${stat("Superseded", this.#superseded, "questions whose jobs were cancelled because a newer question was asked")}
        ${stat("Prepared", s.jobs.prepared, "jobs that generated their shard first")}
        ${stat("Reused", s.jobs.reused, "jobs answered from a shard a worker already held")}
        ${stat("Preparing, total", `${ms(s.jobs.prepareMs)} ms`)}
        ${stat("Shards replaced", s.instances.evicted.replaced, "prepared states a worker let go to prepare another")}
        ${stat("Workers retired", s.instances.ended.retired, "workers ended for growing past maxWorkerBytes")}
        ${stat("Feed messages", port ? port.messages : "–", "live batches delivered to the app")}
        ${stat("Feed backlog", port ? port.backlog : "–", "batches emitted and not yet delivered")}
        ${stat("Feed refused", port ? port.refusedEmits : "–", "batches the page could not take yet; the feed sends them with the next")}
      </div>`;
  }
}

customElements.define("query-meter", QueryMeter);
