import { renderOpsChart } from "./vendor/ops_chart.mjs";

const observedAttrs = new Set(["data-ops-chart-points", "data-ops-chart-selected"]);

export const serviceOpsBehaviors = {
  "ops-chart": {
    attach(el) {
      renderChart(el);
      return () => {};
    },
    update(el, attrName) {
      if (observedAttrs.has(attrName)) {
        renderChart(el);
      }
    },
  },
};

function renderChart(chart) {
  const rawPoints = chart.getAttribute("data-ops-chart-points") ?? "";
  const selectedDetail = chart.getAttribute("data-ops-chart-selected") ?? "";
  renderOpsChart(chart, parsePoints(rawPoints), {
    selectedDetail,
    onHover: (detail) => dispatchChartEvent(chart, "chart-hover", detail),
    onLeave: () => dispatchChartEvent(chart, "chart-hover", ""),
    onSelect: (detail) => dispatchChartEvent(chart, "chart-select", detail),
  });
}

function dispatchChartEvent(chart, type, detail) {
  chart.dispatchEvent(new CustomEvent(type, { detail, bubbles: true }));
}

function parsePoints(raw) {
  if (raw.trim() === "") {
    return [];
  }
  return raw
    .split(";")
    .map((entry) => {
      const [id, label, rpm, latencyMs, errorPermille] = entry.split("|");
      return {
        id,
        label,
        rpm: parseSafeInteger(rpm),
        latencyMs: parseSafeInteger(latencyMs),
        errorPermille: parseSafeInteger(errorPermille),
      };
    })
    .filter((point) => point.id && point.label);
}

function parseSafeInteger(value) {
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed >= 0 ? parsed : 0;
}
