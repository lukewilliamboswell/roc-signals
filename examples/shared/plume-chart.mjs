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
// It reads `window.Plotly`, which the example page loads (deferred, before
// this module) from a pinned CDN URL.
const config = { responsive: true, displaylogo: false };

class PlumeChart extends HTMLElement {
  static observedAttributes = ["data-figure"];

  connectedCallback() {
    this.#draw();
  }

  attributeChangedCallback() {
    this.#draw();
  }

  disconnectedCallback() {
    window.Plotly?.purge(this);
  }

  #draw() {
    const figure = this.dataset.figure;
    if (!this.isConnected || !window.Plotly) return;
    if (!figure) {
      window.Plotly.purge(this);
      return;
    }
    const { data, layout } = JSON.parse(figure);
    window.Plotly.react(this, data, layout, config);
  }
}

customElements.define("plume-chart", PlumeChart);
