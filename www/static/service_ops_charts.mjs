import { renderOpsChart } from "./vendor/ops_chart.mjs";

const chartSelector = "[data-ops-chart]";
const observedAttrs = ["data-ops-chart-points", "data-ops-chart-selected"];

export function installServiceOpsCharts(root) {
  const charts = new Map();

  const refresh = () => {
    for (const chart of root.querySelectorAll?.(chartSelector) ?? []) {
      renderChart(chart, charts);
    }
  };

  refresh();

  if (typeof MutationObserver !== "function") {
    return () => charts.clear();
  }

  const observer = new MutationObserver((records) => {
    let shouldRefresh = false;
    for (const record of records) {
      if (record.type === "childList") {
        shouldRefresh = true;
        break;
      }
      if (record.type === "attributes" && observedAttrs.includes(record.attributeName)) {
        shouldRefresh = true;
        break;
      }
    }
    if (shouldRefresh) {
      refresh();
    }
  });
  observer.observe(root, {
    subtree: true,
    childList: true,
    attributes: true,
    attributeFilter: observedAttrs,
  });

  return () => {
    observer.disconnect();
    charts.clear();
  };
}

function renderChart(chart, charts) {
  const rawPoints = chart.getAttribute("data-ops-chart-points") ?? "";
  const selectedDetail = chart.getAttribute("data-ops-chart-selected") ?? "";
  const state = charts.get(chart);
  if (state?.rawPoints === rawPoints && state?.selectedDetail === selectedDetail) {
    return;
  }

  const bridges = chartBridgeInputs(chart);
  renderOpsChart(chart, parsePoints(rawPoints), {
    selectedDetail,
    onHover: (detail) => writeBridgeValue(bridges.hover, detail),
    onLeave: () => writeBridgeValue(bridges.hover, ""),
    onSelect: (detail) => writeBridgeValue(bridges.select, detail),
  });
  charts.set(chart, { rawPoints, selectedDetail });
}

function chartBridgeInputs(chart) {
  const chartId = chart.getAttribute("data-ops-chart") ?? "";
  const scope = chart.parentElement ?? chart.parentNode ?? document;
  return {
    hover: scope.querySelector?.(`[data-ops-chart-hover-input="${cssEscape(chartId)}"]`) ?? null,
    select: scope.querySelector?.(`[data-ops-chart-select-input="${cssEscape(chartId)}"]`) ?? null,
  };
}

function writeBridgeValue(input, value) {
  if (!input || input.value === value) {
    return;
  }
  input.value = value;
  input.dispatchEvent(new Event("input", { bubbles: true }));
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

function cssEscape(value) {
  if (globalThis.CSS?.escape) {
    return CSS.escape(value);
  }
  return String(value).replace(/["\\]/g, "\\$&");
}
