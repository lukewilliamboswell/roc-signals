// A replay's logical aliases are separate from browser-assigned pointer ids.
// Validate dispatch facts without making their numeric spelling a spec API.
export function verifyPointerRecords(records, expected, aliases, alias = expected[0]?.alias) {
  if (records.length !== expected.length) {
    throw new Error(`${alias === undefined ? "input" : `pointer ${alias}`} dispatched ${records.length} pointer records, expected ${expected.length}`);
  }
  for (let index = 0; index < records.length; index += 1) {
    const record = records[index], wanted = expected[index];
    const pointer = aliases.get(record.id);
    if (!pointer) throw new Error(`pointer ${wanted.alias} received a dispatch from an unknown browser pointer`);
    if (pointer.alias !== wanted.alias) throw new Error(`pointer ${pointer.alias} dispatched during pointer ${wanted.alias}'s input`);
    if (record.id !== wanted.id || record.kind !== wanted.kind || record.kind !== pointer.kind || record.type !== wanted.type) {
      throw new Error(`pointer ${wanted.alias} dispatched ${record.type}/${record.kind}, expected ${wanted.type}/${wanted.kind}`);
    }
    if (JSON.stringify(record.at) !== JSON.stringify(wanted.at)) {
      throw new Error(`pointer ${wanted.alias} reported ${JSON.stringify(record.at)}, expected ${JSON.stringify(wanted.at)}`);
    }
  }
}

// A click must leave physical evidence even when no typed declaration is
// reached. Missing document facts must never look like a valid empty log.
export function verifyClickEvents(events) {
  const order = ["pointermove", "pointerdown", "pointerup"];
  let previous = -1, down = false, up = false;
  for (const event of events) {
    const position = order.indexOf(event.type);
    if (event.id !== 1 || event.kind !== "mouse" || position <= previous) throw new Error("pointer 1 received an unexpected pointer dispatch during click");
    previous = position;
    down ||= event.type === "pointerdown";
    up ||= event.type === "pointerup";
  }
  if (!down || !up) throw new Error("pointer 1 click is missing physical pointerdown or pointerup evidence");
}

// CDP's passive binding carries bounded dispatch facts out of a document
// before a link's default action destroys its execution context.
export async function beginPointerInput(page, config) {
  if (!page.pointerBinding) {
    await page.send("Runtime.addBinding", { name: "__rocPointerFacts" });
    page.conn.on(page.sessionId, "Runtime.bindingCalled", (event) => {
      if (event.name !== "__rocPointerFacts" || !page.pointerFacts) return;
      const batch = JSON.parse(event.payload), facts = page.pointerFacts;
      if (facts.raw.length + batch.raw.length > 4096 || facts.records.length + batch.records.length > 4096) {
        facts.error = "resource_limit: more than 4096 pointer dispatches in one input";
        return;
      }
      facts.raw.push(...batch.raw); facts.records.push(...batch.records);
      if (batch.error) facts.error = batch.error;
    });
    page.pointerBinding = true;
  }
  page.pointerFacts = { raw: [], records: [] };
  await page.evaluate((config) => {
    const types = ["pointerdown", "pointermove", "pointerup", "pointercancel"];
    const rt = window.__rt, loc = config.loc ? window.__loc(config.loc) : null;
    let raw = [], count = 0;
    const flush = () => {
      const records = rt.takePointerLog();
      if (!raw.length && !records.length) return;
      window.__rocPointerFacts(JSON.stringify({ raw, records })); raw = [];
    };
    const capture = (event) => {
      flush();
      if (++count > 4096) {
        const error = "resource_limit: more than 4096 pointer dispatches in one input";
        if (count === 4097) window.__rocPointerFacts(JSON.stringify({ raw: [], records: [], error }));
        return;
      }
      let typed = false;
      for (let element = event.target; element && element !== rt.root; element = element.parentElement) {
        const handler = element.__h?.[event.type];
        if (handler) { typed = handler.kind === 3; break; }
      }
      let at = config.at ?? null, error;
      if (typed && loc) {
        let zone = loc;
        while (zone && zone !== rt.root && !zone.__pointerZone) zone = zone.parentElement;
        if (zone === rt.root) zone = null;
        if (zone && zone !== loc) error = `LOC lies in zone ${zone.__pointerZone}; give :at in that zone using the pointer steps`;
        at = zone ? { zone: zone.__pointerZone, x: 5000, y: 5000 } : null;
      }
      raw.push({ type: event.type, id: event.pointerId, kind: event.pointerType, typed, at });
      if (error) window.__rocPointerFacts(JSON.stringify({ raw: [], records: [], error }));
      if (event.type === "pointerdown") window.__pointerDownTarget = event.target;
    };
    for (const type of types) {
      window.addEventListener(type, capture, true);
      window.addEventListener(type, flush);
    }
    window.addEventListener("beforeunload", flush);
    window.__endPointerInput = () => {
      flush();
      for (const type of types) {
        window.removeEventListener(type, capture, true);
        window.removeEventListener(type, flush);
      }
      window.removeEventListener("beforeunload", flush);
      delete window.__endPointerInput;
    };
  }, config);
}

export async function endPointerInput(page) {
  await page.evaluate(() => window.__endPointerInput?.());
  const facts = page.pointerFacts;
  page.pointerFacts = null;
  if (facts.error) throw new Error(facts.error);
  return facts;
}
