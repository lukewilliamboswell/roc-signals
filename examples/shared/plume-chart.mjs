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
// `data-background`, when present, supplies the paper and plot background
// color chosen by Roc beside the figure. The renderer makes no media query.
//
// On the example site, wait for the app to mount and a chart with data to
// near the viewport before executing Plotly. Pages can warm the download
// once the app has mounted.
// Standalone examples can supply an already-loaded Plotly global instead.
const config = { responsive: true, displaylogo: false };
const vendor = document.querySelector('meta[name="signals-plotly"]');
let library;
let mounted = false;

function configureRequest(element) {
  element.integrity = vendor.dataset.integrity;
  element.crossOrigin = "anonymous";
}

function loadPlotly() {
  library ??= new Promise((resolve, reject) => {
    const script = document.createElement("script");
    configureRequest(script);
    script.src = vendor.content;
    script.onload = () => {
      if (window.Plotly) resolve();
      else reject(new Error("The Plotly script did not provide a renderer."));
    };
    script.onerror = () => reject(new Error("The Plotly script failed to load."));
    document.head.append(script);
  });
  return library;
}

if (vendor) {
  document.addEventListener("roc-signals:runtime", () => {
    mounted = true;
    if (!vendor.hasAttribute("data-preload") || window.Plotly) return;
    const preload = document.createElement("link");
    preload.rel = "preload";
    preload.as = "script";
    preload.fetchPriority = "low";
    configureRequest(preload);
    preload.href = vendor.content;
    document.head.append(preload);
  }, { once: true });
}

class PlumeChart extends HTMLElement {
  static observedAttributes = ["data-figure", "data-background"];

  // Whether this element listens to Plotly's clicks; `Plotly.purge` drops
  // the listener with the rest of its state.
  #listening = false;
  #observer = null;
  #nearViewport = false;
  #waitingForLibrary = false;
  #error = null;

  connectedCallback() {
    if (!vendor) {
      this.#draw();
      return;
    }
    if (mounted) this.#observe();
    else document.addEventListener("roc-signals:runtime", this.#observe, { once: true });
  }

  #observe = () => {
    if (this.#observer || !this.dataset.figure) return;
    const observer = new IntersectionObserver(([entry]) => {
      if (this.#observer !== observer || !entry.isIntersecting) return;
      this.#stopObserving();
      this.#nearViewport = true;
      this.#draw();
    }, { rootMargin: "200px" });
    this.#observer = observer;
    observer.observe(this);
  };

  attributeChangedCallback() {
    this.#draw();
  }

  disconnectedCallback() {
    document.removeEventListener("roc-signals:runtime", this.#observe);
    this.#stopObserving();
    this.#nearViewport = false;
    this.#purge();
  }

  #stopObserving() {
    this.#observer?.disconnect();
    this.#observer = null;
  }

  #purge() {
    window.Plotly?.purge(this);
    this.#listening = false;
    this.#error?.remove();
    this.#error = null;
  }

  #showLoadError(error) {
    if (this.#error || !this.isConnected || this.#observer || !this.dataset.figure) return;
    console.error(error);
    this.#error = document.createElement("p");
    this.#error.setAttribute("role", "status");
    this.#error.textContent = "Chart unavailable.";
    this.append(this.#error);
  }

  #draw() {
    if (!this.isConnected || (vendor && !mounted)) return;
    const figure = this.dataset.figure;
    if (!figure) {
      this.#stopObserving();
      this.#purge();
      return;
    }
    if (vendor && !this.#nearViewport) {
      this.#observe();
      return;
    }
    if (!window.Plotly) {
      if (!vendor || this.#waitingForLibrary || this.#error) return;
      this.#waitingForLibrary = true;
      loadPlotly().then(() => {
        this.#waitingForLibrary = false;
        // Use the current attributes and connection after the shared download.
        this.#draw();
      }, (error) => {
        this.#waitingForLibrary = false;
        this.#showLoadError(error);
      });
      return;
    }
    const { data, layout } = JSON.parse(figure);
    const background = this.getAttribute("data-background");
    const drawnLayout = background === null ? layout : { ...layout, paper_bgcolor: background, plot_bgcolor: background };
    window.Plotly.react(this, data, drawnLayout, config);
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
