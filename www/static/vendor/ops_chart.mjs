const svgNs = "http://www.w3.org/2000/svg";

export function renderOpsChart(root, points, options = {}) {
  root.replaceChildren();
  if (points.length === 0) {
    const empty = document.createElement("div");
    empty.className = "grid min-h-36 place-items-center text-sm text-zinc-500";
    empty.textContent = "Waiting for chart data";
    root.appendChild(empty);
    return;
  }

  const selectedDetail = options.selectedDetail ?? "";
  const svg = el("svg", {
    viewBox: "0 0 720 280",
    role: "img",
    "aria-label": "Request pressure, latency, and error rate",
    style: "width:100%;height:auto;min-height:220px;display:block;",
  });
  const plot = { left: 54, right: 24, top: 26, bottom: 226 };
  const plotWidth = 720 - plot.left - plot.right;
  const plotHeight = plot.bottom - plot.top;
  const rpmRange = range(points.map((point) => point.rpm));
  const latencyRange = range(points.map((point) => point.latencyMs));
  const maxError = Math.max(10, ...points.map((point) => point.errorPermille));
  const coords = points.map((point, index) => ({
    point,
    x: plot.left + (index / Math.max(1, points.length - 1)) * plotWidth,
    rpmY: scaleY(point.rpm, rpmRange, plot),
    latencyY: scaleY(point.latencyMs, latencyRange, plot),
    errorY: plot.bottom - (point.errorPermille / maxError) * plotHeight,
  }));

  svg.appendChild(
    el("rect", {
      x: "0",
      y: "0",
      width: "720",
      height: "280",
      rx: "8",
      fill: "#ffffff",
    }),
  );
  for (let index = 0; index < 5; index += 1) {
    const y = plot.top + (index / 4) * plotHeight;
    svg.appendChild(line(plot.left, y, 720 - plot.right, y, "#e4e4e7", index === 4 ? 1.4 : 1));
  }

  svg.appendChild(text("rpm", 18, 34, "11", "#52525b", "start"));
  svg.appendChild(text(formatNumber(rpmRange.max), 18, plot.top + 4, "11", "#71717a", "start"));
  svg.appendChild(text(formatNumber(rpmRange.min), 18, plot.bottom, "11", "#71717a", "start"));

  for (const coord of coords) {
    const barHeight = plot.bottom - coord.errorY;
    svg.appendChild(
      el("rect", {
        x: String(coord.x - 8),
        y: String(coord.errorY),
        width: "16",
        height: String(barHeight),
        rx: "4",
        fill: "#fee2e2",
        stroke: "#fca5a5",
        "stroke-width": "1",
      }),
    );
  }

  svg.appendChild(path(coords.map((coord) => [coord.x, coord.rpmY]), "#0369a1", 3));
  svg.appendChild(path(coords.map((coord) => [coord.x, coord.latencyY]), "#b45309", 2.5));
  svg.appendChild(area(coords.map((coord) => [coord.x, coord.rpmY]), plot.bottom, "rgba(14, 165, 233, 0.12)"));

  for (const coord of coords) {
    const detail = pointDetail(coord.point);
    const selected = selectedDetail === detail;
    const marker = el("circle", {
      cx: String(coord.x),
      cy: String(coord.rpmY),
      r: selected ? "7" : "5",
      fill: selected ? "#0f766e" : "#ffffff",
      stroke: selected ? "#0f766e" : "#0369a1",
      "stroke-width": selected ? "3" : "2",
      style: "cursor:pointer;",
      tabindex: "0",
      "aria-label": detail,
    });
    marker.appendChild(el("title", {}, detail));
    marker.addEventListener("pointerenter", () => {
      marker.setAttribute("r", "7");
      options.onHover?.(detail);
    });
    marker.addEventListener("pointerleave", () => {
      marker.setAttribute("r", selected ? "7" : "5");
      options.onLeave?.();
    });
    marker.addEventListener("click", () => options.onSelect?.(detail));
    marker.addEventListener("keydown", (event) => {
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        options.onSelect?.(detail);
      }
    });
    svg.appendChild(marker);
  }

  const first = coords[0];
  const last = coords[coords.length - 1];
  svg.appendChild(text(first.point.label, first.x, 254, "11", "#71717a", "middle"));
  svg.appendChild(text(last.point.label, last.x, 254, "11", "#71717a", "middle"));
  svg.appendChild(legend(470, 24, "#0369a1", "requests"));
  svg.appendChild(legend(470, 46, "#b45309", "latency"));
  svg.appendChild(legend(470, 68, "#ef4444", "errors"));

  root.appendChild(svg);
}

function range(values) {
  const min = Math.min(...values);
  const max = Math.max(...values);
  if (min === max) {
    return { min: min - 1, max: max + 1 };
  }
  const pad = (max - min) * 0.15;
  return { min: min - pad, max: max + pad };
}

function scaleY(value, valueRange, plot) {
  const ratio = (value - valueRange.min) / (valueRange.max - valueRange.min);
  return plot.bottom - ratio * (plot.bottom - plot.top);
}

function path(points, stroke, strokeWidth) {
  const d = points.map(([x, y], index) => `${index === 0 ? "M" : "L"} ${x.toFixed(1)} ${y.toFixed(1)}`).join(" ");
  return el("path", {
    d,
    fill: "none",
    stroke,
    "stroke-width": String(strokeWidth),
    "stroke-linecap": "round",
    "stroke-linejoin": "round",
  });
}

function area(points, bottom, fill) {
  const linePath = points.map(([x, y], index) => `${index === 0 ? "M" : "L"} ${x.toFixed(1)} ${y.toFixed(1)}`).join(" ");
  const last = points[points.length - 1];
  const first = points[0];
  return el("path", {
    d: `${linePath} L ${last[0].toFixed(1)} ${bottom} L ${first[0].toFixed(1)} ${bottom} Z`,
    fill,
  });
}

function legend(x, y, color, label) {
  const group = el("g");
  group.appendChild(line(x, y - 4, x + 20, y - 4, color, 3));
  group.appendChild(text(label, x + 28, y, "12", "#52525b", "start"));
  return group;
}

function line(x1, y1, x2, y2, stroke, strokeWidth) {
  return el("line", {
    x1: String(x1),
    y1: String(y1),
    x2: String(x2),
    y2: String(y2),
    stroke,
    "stroke-width": String(strokeWidth),
  });
}

function text(value, x, y, size, fill, anchor) {
  const node = el("text", {
    x: String(x),
    y: String(y),
    "font-size": size,
    "font-family": "ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace",
    fill,
    "text-anchor": anchor,
  });
  node.textContent = value;
  return node;
}

function el(tag, attrs = {}, textValue = "") {
  const node = document.createElementNS(svgNs, tag);
  for (const [name, value] of Object.entries(attrs)) {
    node.setAttribute(name, value);
  }
  if (textValue !== "") {
    node.textContent = textValue;
  }
  return node;
}

function pointDetail(point) {
  return `${point.label} | ${formatNumber(point.rpm)} rpm | ${point.latencyMs} ms | ${formatPermille(point.errorPermille)} errors`;
}

function formatNumber(value) {
  return Number(value).toLocaleString("en-US");
}

function formatPermille(value) {
  return `${Math.floor(value / 10)}.${value % 10}%`;
}
