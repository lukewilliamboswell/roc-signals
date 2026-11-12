// <log-timings>: the Log Explorer's own element, showing what preparing a
// log took against what each later question of it took, as the runtime's
// monitor measured them (`runtime.monitor`; see the "Monitoring Workers"
// docs page). It is the example's JavaScript, named as a script in
// www/data/examples.toml; the engine renders it as an empty element and
// knows nothing about it.
//
// It learns which runtime to watch from the `roc-signals:runtime` event
// that the page mounting the app dispatches on the mount root (its
// `detail.runtime`), and draws into its own shadow root, so the engine's
// children of the element stay the engine's. It only reads: it never
// changes which job runs when. It keeps the last preparation and at most
// `RECENT` questions after it, and leaving the document unsubscribes it.
const RECENT = 8;

const STYLE = `
  :host { display: block; }
  section { border: 1px solid #e4e4e7; border-radius: 0.75rem; background: #fff; padding: 1rem 1.25rem; display: grid; gap: 0.5rem; font: 14px/1.4 ui-sans-serif, system-ui, sans-serif; color: #18181b; }
  h2 { margin: 0; font-size: 0.95rem; font-weight: 600; }
  p { margin: 0; }
  .muted { color: #71717a; font-size: 0.8rem; }
  table { width: 100%; border-collapse: collapse; font-variant-numeric: tabular-nums; }
  th, td { text-align: left; padding: 0.2rem 0.4rem; border-bottom: 1px solid #f4f4f5; font-size: 0.8rem; }
  th { color: #71717a; font-weight: 500; }
  td.n, th.n { text-align: right; }
`;

const ms = (v) => (v == null || !Number.isFinite(v) ? "–" : v < 10 ? v.toFixed(1) : Math.round(v).toLocaleString("en-US"));
const shortName = (task) => task.split("/").pop();

class LogTimings extends HTMLElement {
  #unsubscribe = null;
  #body = null;
  // The last preparation's job record, and the questions answered from it.
  #prepared = null;
  #questions = [];
  #onRuntime = (e) => {
    if (e.target instanceof Node && e.target.contains(this)) this.#watch(e.detail.runtime);
  };

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
    this.#unsubscribe?.();
    this.#unsubscribe = null;
  }

  #watch(runtime) {
    this.#unsubscribe?.();
    this.#prepared = null;
    this.#questions = [];
    this.#unsubscribe = runtime.monitor.subscribe((e) => {
      if (e.kind !== "job-end" || e.outcome !== "done") return;
      const r = e.record;
      if (r.prepared === "prepare") {
        this.#prepared = r;
        this.#questions = [];
      } else if (r.prepared === "reuse") {
        this.#questions.push(r);
        if (this.#questions.length > RECENT) this.#questions.shift();
      } else return;
      this.#draw();
    });
    this.#draw();
  }

  #draw() {
    const body = this.#body;
    if (!body) return;
    const p = this.#prepared;
    const head = "<h2>Prepared once, asked many times</h2>";
    if (p === null) {
      body.innerHTML = `${head}<p class="muted">The worker's times appear here once a log is prepared.</p>`;
      return;
    }
    const rows = this.#questions
      .slice()
      .reverse()
      .map((q) => `<tr><td>${shortName(q.task)}</td><td class="n">${ms(q.ms.compute)}</td><td class="n">${ms(q.ms.total)}</td></tr>`)
      .join("");
    body.innerHTML = `${head}
      <p data-testid="prepare-ms">Preparing the log (reading and indexing it) took <b>${ms(p.prepareMs)} ms</b>; its first question, ${shortName(p.task)}, took ${ms(p.ms.compute)} ms more.</p>
      ${rows === "" ? '<p class="muted">Every later question reuses the prepared index; its time appears here.</p>' : `<table><thead><tr><th>Later question</th><th class="n">Task ms</th><th class="n">Total ms</th></tr></thead><tbody>${rows}</tbody></table>`}
      <p class="muted">Measured by the runtime's monitor: task time in the worker, and total from the request to the page showing the answer.</p>`;
  }
}

customElements.define("log-timings", LogTimings);
