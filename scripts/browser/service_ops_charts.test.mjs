import assert from "node:assert/strict";
import test from "node:test";

import { installServiceOpsCharts } from "../../www/static/service_ops_charts.mjs";
import { ELEMENT_NODE, findAll, fireEvent, installDomDouble } from "./dom_double.mjs";

test("service ops chart renders points and bridges hover and click events", () => {
  const root = installDomDouble();
  const shell = document.createElement("div");
  const chart = document.createElement("div");
  const hoverInput = document.createElement("input");
  const selectInput = document.createElement("input");
  let hoverEvents = 0;
  let selectEvents = 0;

  chart.setAttribute("data-ops-chart", "traffic");
  chart.setAttribute(
    "data-ops-chart-points",
    "p1|09:00|1200|87|12;p2|09:15|1420|93|18;p3|09:30|1310|91|15",
  );
  chart.setAttribute("data-ops-chart-selected", "");
  hoverInput.setAttribute("data-ops-chart-hover-input", "traffic");
  selectInput.setAttribute("data-ops-chart-select-input", "traffic");
  hoverInput.addEventListener("input", () => {
    hoverEvents += 1;
  });
  selectInput.addEventListener("input", () => {
    selectEvents += 1;
  });

  shell.appendChild(chart);
  shell.appendChild(hoverInput);
  shell.appendChild(selectInput);
  root.appendChild(shell);

  const cleanup = installServiceOpsCharts(root);
  const svgs = findAll(root, (node) => node.nodeType === ELEMENT_NODE && node.tagName === "SVG");
  const markers = findAll(root, (node) => node.nodeType === ELEMENT_NODE && node.tagName === "CIRCLE");

  assert.equal(svgs.length, 1);
  assert.equal(markers.length, 3);

  fireEvent(markers[0], "pointerenter");
  assert.match(hoverInput.value, /09:00 \| 1,200 rpm/);
  assert.equal(hoverEvents, 1);

  fireEvent(markers[0], "pointerleave");
  assert.equal(hoverInput.value, "");
  assert.equal(hoverEvents, 2);

  fireEvent(markers[1], "click");
  assert.match(selectInput.value, /09:15 \| 1,420 rpm/);
  assert.equal(selectEvents, 1);

  cleanup();
});
