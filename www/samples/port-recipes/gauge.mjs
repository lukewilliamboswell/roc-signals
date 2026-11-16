// Canvas drawing is an element's business, rather than a port. The frame
// interpolates only a displayed value; Roc decides the gauge's target value.
export function registerGauge() {
  if (customElements.get("recipe-gauge")) return;
  customElements.define("recipe-gauge", class extends HTMLElement {
    static observedAttributes = ["data-value", "data-animate"];
    #frame = null;
    #shown = 0;
    constructor() {
      super();
      const root = this.attachShadow({ mode: "open" });
      this.canvas = document.createElement("canvas");
      this.canvas.width = 240;
      this.canvas.height = 140;
      this.canvas.setAttribute("aria-label", "Gauge");
      this.canvas.setAttribute("role", "img");
      root.append(this.canvas);
    }
    connectedCallback() { this.draw(); }
    attributeChangedCallback() { if (this.isConnected) this.draw(); }
    disconnectedCallback() {
      if (this.#frame !== null) cancelAnimationFrame(this.#frame);
      this.#frame = null;
    }
    draw() {
      if (this.#frame !== null) cancelAnimationFrame(this.#frame);
      this.#frame = null;
      const text = this.getAttribute("data-value") ?? "0";
      const target = Number(text);
      if (!/^(0|[1-9][0-9]*)$/.test(text) || !Number.isInteger(target) || target < 0 || target > 100) throw new Error("Gauge value must be an integer from 0 to 100");
      const animate = this.getAttribute("data-animate") === "true";
      this.#shown = animate ? this.#shown + (target - this.#shown) * 0.2 : target;
      if (Math.abs(target - this.#shown) < 0.1) this.#shown = target;
      const ctx = this.canvas.getContext("2d");
      if (!ctx) throw new Error("Canvas drawing is unavailable");
      ctx.clearRect(0, 0, 240, 140);
      ctx.lineWidth = 12;
      ctx.strokeStyle = "#e4e4e7";
      ctx.beginPath(); ctx.arc(120, 120, 90, Math.PI, 2 * Math.PI); ctx.stroke();
      ctx.strokeStyle = "#2563eb";
      ctx.beginPath(); ctx.arc(120, 120, 90, Math.PI, Math.PI + this.#shown / 100 * Math.PI); ctx.stroke();
      ctx.fillStyle = "#18181b";
      ctx.font = "24px sans-serif";
      ctx.textAlign = "center";
      ctx.fillText(`${Math.round(this.#shown)}%`, 120, 110);
      this.canvas.setAttribute("aria-label", `Gauge ${target}%`);
      if (animate && this.#shown !== target) this.#frame = requestAnimationFrame(() => { this.#frame = null; if (this.isConnected) this.draw(); });
    }
  });
}
