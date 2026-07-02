import assert from "node:assert/strict";
import test from "node:test";

import { serviceOpsBehaviors } from "../../www/static/service_ops_charts.mjs";
import { ELEMENT_NODE, findAll, fireEvent, installDomDouble } from "./dom_double.mjs";

test("service ops chart renders points and dispatches bubbling custom events", () => {
  const root = installDomDouble();
  const shell = document.createElement("div");
  const chart = document.createElement("div");
  const hoverDetails = [];
  const selectDetails = [];

  chart.setAttribute(
    "data-ops-chart-points",
    "p1|09:00|1200|87|12;p2|09:15|1420|93|18;p3|09:30|1310|91|15",
  );
  chart.setAttribute("data-ops-chart-selected", "");
  shell.addEventListener("chart-hover", (event) => hoverDetails.push(event.detail));
  shell.addEventListener("chart-select", (event) => selectDetails.push(event.detail));

  shell.appendChild(chart);
  root.appendChild(shell);

  serviceOpsBehaviors["ops-chart"].attach(chart);
  const svgs = findAll(root, (node) => node.nodeType === ELEMENT_NODE && node.tagName === "SVG");
  const markers = findAll(root, (node) => node.nodeType === ELEMENT_NODE && node.tagName === "CIRCLE");

  assert.equal(svgs.length, 1);
  assert.equal(markers.length, 3);

  fireEvent(markers[0], "pointerenter");
  assert.match(hoverDetails[0], /09:00 \| 1,200 rpm/);

  fireEvent(markers[0], "pointerleave");
  assert.equal(hoverDetails[1], "");

  fireEvent(markers[1], "click");
  assert.match(selectDetails[0], /09:15 \| 1,420 rpm/);
});
