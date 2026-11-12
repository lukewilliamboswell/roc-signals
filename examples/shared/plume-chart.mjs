// <plume-chart data-figure="{...}">: draws a Plotly figure that the app built
// with Plume (`Chart.to_json`, a `{ data, layout }` object).
//
// Shared example JavaScript: any example's page loads it by naming it as a
// `shared` script in www/data/examples.toml. An app (the Status Page, for
// one) renders this as an ordinary element with an ordinary attribute; the
// engine and the browser runtime know nothing about charts.
// This element is the whole bridge: whenever the attribute changes while the
// element is in the document, `Plotly.react` redraws it in place, and leaving
// the document releases Plotly's state. An empty or absent attribute clears
// the chart.
//
// With `data-click="x"`, a click on a point reports the point's x the way
// any control reports a value: the element sets its `value` to the x as
// Plotly gives it (a number as text; on a date axis a date such as
// `2026-11-11 12:05`, or `2026-11-11` at midnight) and dispatches a bubbling
// `change` event, which an app hears with an ordinary change handler. An
// element without the attribute reports nothing.
//
// It reads `window.Plotly`, which the example page loads (deferred, before
// this module) from a pinned CDN URL.
const config = { responsive: true, displaylogo: false };

class PlumeChart extends HTMLElement {
  static observedAttributes = ["data-figure"];

  // Whether this element listens to Plotly's clicks; `Plotly.purge` drops
  // the listener with the rest of its state.
  #listening = false;

  connectedCallback() {
    this.#draw();
  }

  attributeChangedCallback() {
    this.#draw();
  }

  disconnectedCallback() {
    this.#purge();
  }

  #purge() {
    window.Plotly?.purge(this);
    this.#listening = false;
  }

  #draw() {
    const figure = this.dataset.figure;
    if (!this.isConnected || !window.Plotly) return;
    if (!figure) {
      this.#purge();
      return;
    }
    const { data, layout } = JSON.parse(figure);
    window.Plotly.react(this, data, layout, config);
    if (!this.#listening && this.dataset.click === "x" && typeof this.on === "function") {
      this.on("plotly_click", (event) => {
        const point = event?.points?.[0];
        if (point === undefined || point.x === undefined || point.x === null) return;
        this.value = String(point.x);
        this.dispatchEvent(new Event("change", { bubbles: true }));
      });
      this.#listening = true;
    }
  }
}

customElements.define("plume-chart", PlumeChart);
