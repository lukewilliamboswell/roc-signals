// <latency-feed-monitor data-port="NAME">: what the runtime's monitor
// (`runtime.monitor.snapshot().ports[NAME]`, see the "Monitoring Workers"
// docs page) reports about one port subscription, beside the app's own
// figures: messages delivered, emits refused by the subscription's bound,
// messages replaced under `Latest`, the backlog waiting now, and the
// longest gap between two animation frames over the last five seconds.
//
// The Status Page's own JavaScript, named as a script in
// www/data/examples.toml. The app renders it as an ordinary empty element;
// the engine and the runtime know nothing of it. It learns which runtime
// to watch from the `roc-signals:runtime` event the page that mounts the
// app dispatches on the mount root, draws into its own shadow root, and
// only reads: a snapshot four times a second, and the frame clock. Leaving
// the document stops both.
const GAP_WINDOW_MS = 5000;
const REDRAW_MS = 250;

const STYLE = `
  :host { display: block; }
  section { border: 1px solid #e4e4e7; border-radius: 0.75rem; background: #fafafa; padding: 0.75rem 1rem; display: grid; gap: 0.5rem; font: 13px/1.4 ui-sans-serif, system-ui, sans-serif; color: #18181b; }
  .head { display: flex; flex-wrap: wrap; justify-content: space-between; gap: 0.5rem; color: #71717a; }
  dl { display: grid; grid-template-columns: repeat(auto-fit, minmax(8rem, 1fr)); gap: 0.5rem; margin: 0; }
  div.stat { border: 1px solid #f4f4f5; border-radius: 0.5rem; padding: 0.4rem 0.6rem; background: #fff; }
  dt { color: #71717a; font-size: 0.75rem; }
  dd { margin: 0; font-size: 1.1rem; font-variant-numeric: tabular-nums; }
`;

const FIELDS = [
  ["messages", "Messages delivered"],
  ["refusedEmits", "Emits refused (page full)"],
  ["coalesced", "Replaced before delivery"],
  ["backlog", "Waiting now"],
  ["subscriptions", "Live subscriptions"],
];

class LatencyFeedMonitor extends HTMLElement {
  #runtime = null;
  #timer = 0;
  #rafId = 0;
  #frames = [];
  #body = null;
  #onRuntime = (e) => {
    if (e.target instanceof Node && e.target.contains(this)) this.#watch(e.detail.runtime);
  };

  connectedCallback() {
    if (!this.shadowRoot) {
      const root = this.attachShadow({ mode: "open" });
      const style = document.createElement("style");
      style.textContent = STYLE;
      this.#body = document.createElement("section");
      this.#body.setAttribute("aria-label", "Port monitor");
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
    const frame = (t) => {
      this.#frames.push(t);
      while (this.#frames.length > 2 && t - this.#frames[0] > GAP_WINDOW_MS) this.#frames.shift();
      this.#rafId = requestAnimationFrame(frame);
    };
    this.#rafId = requestAnimationFrame(frame);
    this.#timer = setInterval(() => this.#draw(), REDRAW_MS);
    this.#draw();
  }

  #stop() {
    clearInterval(this.#timer);
    cancelAnimationFrame(this.#rafId);
    this.#runtime = null;
    this.#frames = [];
  }

  #longestGap() {
    let gap = 0;
    for (let i = 1; i < this.#frames.length; i += 1) gap = Math.max(gap, this.#frames[i] - this.#frames[i - 1]);
    return this.#frames.length > 1 ? `${Math.round(gap)} ms` : "–";
  }

  #draw() {
    const body = this.#body;
    if (!body) return;
    const head = document.createElement("div");
    head.className = "head";
    const title = document.createElement("span");
    title.textContent = "What the runtime's monitor counts for this port";
    const gap = document.createElement("span");
    gap.textContent = `Longest frame gap (5 s): ${this.#longestGap()}`;
    head.append(title, gap);
    const record = this.#runtime?.monitor.snapshot().ports?.[this.dataset.port] ?? null;
    const list = document.createElement("dl");
    for (const [key, label] of FIELDS) {
      const stat = document.createElement("div");
      stat.className = "stat";
      const dt = document.createElement("dt");
      dt.textContent = label;
      const dd = document.createElement("dd");
      dd.dataset.field = key;
      dd.textContent = record ? String(record[key]) : "–";
      stat.append(dt, dd);
      list.append(stat);
    }
    body.replaceChildren(head, list);
  }
}

customElements.define("latency-feed-monitor", LatencyFeedMonitor);
