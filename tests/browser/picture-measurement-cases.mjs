// Independent test-owned SPC1 records and physical facts. Node uses these only
// as byte/hash vectors; Chrome builds real DOM for the same measurement path.
const html = "http://www.w3.org/1999/xhtml", svg = "http://www.w3.org/2000/svg", xmlns = "http://www.w3.org/2000/xmlns/";
const word = n => [n & 255, n >>> 8 & 255, n >>> 16 & 255, n >>> 24];
const text = value => { const b = [...new TextEncoder().encode(value)]; return [...word(b.length), ...b]; };
const name = value => value.flatMap(text);
const list = (values, encode) => [...word(values.length), ...values.flatMap(encode)];
const optional = value => value === null ? [0] : [1, ...text(value)];
const element = (local, children = [], attrs = [], namespace = html, prefix = "", content) => ({ name: [namespace, prefix, local], children, attrs, ...(content === undefined ? {} : { content }) });
const root = children => element("x", children, [], "");
function records(physicalCount, containers, logical, runs = [], scaffolds = []) { return { physicalCount, containers, logical, runs, scaffolds, bindings: [], batch_bytes: 0 }; }
export function measurementEnvelope(f) {
  return Uint8Array.from([83, 80, 67, 49, 1, 0, 19, 0, ...word(0), ...name(f.root_name ?? ["", "", "x"]), ...word(f.batch_bytes), ...Array(32).fill(17), ...Array(32).fill(34), ...word(f.physicalCount),
    ...list(f.containers, ([owner, role, children]) => [...word(owner), role, ...list(children, word)]),
    ...list(f.logical, ([target, a, b, data]) => [target, ...word(a), ...(target === 2 ? word(b) : target >= 3 ? [...word(b), ...text(data)] : [])]),
    ...list(f.runs, ([container, index, physical, parts]) => [...word(container), ...word(index), ...(physical === null ? [0] : [1, ...word(physical)]), ...list(parts, ([logical, units]) => [...word(logical), ...word(units)])]),
    ...list(f.bindings, ([birth, role, address, slot, kind, logical]) => [...word(birth), role, ...word(address), ...word(slot), kind, ...word(logical)]),
    ...list(f.scaffolds, ([role, owner, a, b, c, d]) => [role, ...word(owner), ...(role === 0 ? [...word(a), ...(b === null ? [0] : [1, ...word(b)])] : role === 1 ? [...name(a), ...word(b), ...optional(c), ...optional(d)] : word(a))]),
  ]);
}
function textCase(data = "é😀\r", parts = [1, 2, 1]) {
  return { tree: root([{ text: data }]), envelope: records(1, [[0xffffffff, 0, [0]]], parts.map((_, i) => [2, 0, i]), [[0, 0, 0, parts.map((units, i) => [i, units])]]) };
}
function svgCase() {
  return { tree: root([element("g", [{ text: "x" }, { comment: "roc:node=9" }], [[[xmlns, "xmlns", "p"], svg], [["urn:attr", "a", "key"], "é"], [["", "", "pathLength"], "12"]], svg, "p")]), envelope: records(3, [[0xffffffff, 0, [0]], [0, 0, [1, 2]]], [[0, 0], [2, 0, 0], [1, 2]], [[1, 0, 1, [[1, 1]]]]) };
}
function templateCase() {
  return { tree: root([element("template", [{ text: "ordinary" }], [], html, "h", [{ comment: "content" }])]), envelope: records(3, [[0xffffffff, 0, [0]], [0, 0, [1]], [0, 1, [2]]], [[0, 0], [2, 0, 0], [1, 2]], [[1, 0, 1, [[1, 8]]]]) };
}
function controlCase() {
  return { tree: root([element("textarea", [{ text: "rendered" }], [], html, "h")]), envelope: records(2, [[0xffffffff, 0, [0]], [0, 0, [1]]], [[0, 0], [3, 1, 0, "old"], [4, 1, 1, "logical comment"]], [], [[0, 0, 1, 1]]) };
}
function attributeCase() {
  return { tree: root([element("select", [element("option", [], [[["", "", "selected"], ""]], html, "h")], [], html, "h")]), envelope: records(2, [[0xffffffff, 0, [0]], [0, 0, [1]], [1, 0, []]], [[0, 0], [0, 1]], [], [[1, 1, ["", "", "selected"], 0, null, ""]]) };
}
function selectionCase() {
  return { tree: root([element("select", [element("option", [], ["hidden", "selected", "value"].map(local => [["", "", local], ""]), html, "h")], [], html, "h")]), envelope: records(2, [[0xffffffff, 0, [0]], [0, 0, [1]], [1, 0, []]], [[0, 0]], [], [[2, 0, 1]]) };
}
export async function pictureMeasurementCases(api, build, vectors) {
  const { measurePicture, pictureMountFingerprint, decodePictureEnvelope } = api;
  const checks = [], check = (label, ok) => checks.push([label, !!ok]);
  const hex = bytes => [...bytes].map(n => n.toString(16).padStart(2, "0")).join("");
  const reject = async (label, operation) => { let error; try { await operation(); } catch (e) { error = e; } check(label, error?.message.startsWith("picture measurement:")); };
  const measure = f => measurePicture(build(f.tree), measurementEnvelope(f.envelope));
  for (const vector of vectors.mount) {
    const batch = [...vector.batch_hex.matchAll(/../g)].map(([value]) => parseInt(value, 16)), expected = vector.sha256, size = vector.canonical_bytes;
    check(`independent mount hash vector ${JSON.stringify(batch)}`, hex(await pictureMountFingerprint(Uint8Array.from(batch))) === expected);
    check(`mount byte cap is inclusive at ${size}`, hex(await pictureMountFingerprint(Uint8Array.from(batch), { max_measurement_bytes: size })) === expected);
    await reject(`mount byte cap rejects ${size - 1}`, () => pictureMountFingerprint(Uint8Array.from(batch), { max_measurement_bytes: size - 1 }));
  }
  const empty = { tree: root([]), envelope: records(0, [[0xffffffff, 0, []]], []) }, emptyBytes = measurementEnvelope(empty.envelope), emptyRoot = build(empty.tree);
  const emptyResult = await measurePicture(emptyRoot, emptyBytes);
  const golden = label => vectors.picture.find(vector => vector.name === label);
  check("independent empty picture canonical/hash vector", emptyResult.canonical_bytes === golden("empty").canonical_bytes && hex(emptyResult.digest) === golden("empty").sha256 && hex(emptyBytes) === golden("empty").envelope_hex);
  check("decoder exposes the checked hash offset after batch_bytes", decodePictureEnvelope(emptyBytes).hash_offset === 29);
  check("picture byte cap is inclusive at 95", (await measurePicture(emptyRoot, emptyBytes, { max_measurement_bytes: 95 })).canonical_bytes === 95);
  await reject("picture byte cap rejects 94", () => measurePicture(emptyRoot, emptyBytes, { max_measurement_bytes: 94 }));
  await reject("measurement protocol cap cannot be enlarged", () => measurePicture(emptyRoot, emptyBytes, { max_measurement_bytes: 64 * 1024 * 1024 + 1 }));
  await reject("unknown measurement limit is rejected", () => measurePicture(emptyRoot, emptyBytes, { invented: 1 }));
  for (const value of [null, undefined, -1, 1.5, NaN]) await reject(`invalid explicit measurement limit ${String(value)}`, () => measurePicture(emptyRoot, emptyBytes, { max_measurement_bytes: value }));
  const hashesChanged = emptyBytes.slice(); hashesChanged.fill(85, 29, 93);
  check("only the checked stored hash fields are excluded", hex((await measurePicture(emptyRoot, hashesChanged)).digest) === hex(emptyResult.digest));
  const batchChanged = structuredClone(empty.envelope); batchChanged.batch_bytes = 1;
  check("batch_bytes remains in picture canonical input", hex((await measurePicture(emptyRoot, measurementEnvelope(batchChanged))).digest) !== hex(emptyResult.digest));
  const outside = build(empty.tree); outside.setAttributeNS(null, "data-roc-picture", "authored external root");
  check("external root attributes are outside the picture hash", hex((await measurePicture(outside, emptyBytes)).digest) === hex(emptyResult.digest));
  const text = textCase(), textBytes = measurementEnvelope(text.envelope), actualTextRoot = build(text.tree), textResult = await measurePicture(actualTextRoot, textBytes);
  check("independent Unicode physical facts canonical/hash vector", textResult.canonical_bytes === golden("unicode").canonical_bytes && hex(textResult.digest) === golden("unicode").sha256 && hex(textBytes) === golden("unicode").envelope_hex);
  const lookalike = textCase("\x11".repeat(32), [32]), lookalikeResult = await measure(lookalike);
  check("hash-looking physical text stays in the canonical bytes", lookalikeResult.canonical_bytes === golden("hash_lookalike").canonical_bytes && hex(lookalikeResult.digest) === golden("hash_lookalike").sha256 && hex(measurementEnvelope(lookalike.envelope)) === golden("hash_lookalike").envelope_hex);
  check("Unicode, CR and exact text partition are measured", textResult.physical[0] === actualTextRoot.childNodes[0] && textResult.digest.length === 32);
  const zero = textCase("é😀\r", [0, 1, 2, 1, 0]); check("zero text parts preserve explicit logical boundaries", (await measure(zero)).envelope.runs[0].parts.length === 5);
  await reject("UTF-16 sum must equal actual Text length", () => measure(textCase("short", [4])));
  await reject("text boundary cannot split a surrogate pair", () => measure(textCase("é😀\r", [2, 1, 1])));
  await reject("unpaired high surrogate is not replaced during UTF-8 encoding", () => measure(textCase("\ud800", [1])));
  await reject("unpaired low surrogate is not replaced during UTF-8 encoding", () => measure(textCase("\udc00", [1])));
  const expectedWrong = textBytes.slice(); expectedWrong.fill(255, decodePictureEnvelope(textBytes).hash_offset + 32, decodePictureEnvelope(textBytes).hash_offset + 64);
  check("valid digest mismatch is measured without an adoption decision", (await measurePicture(actualTextRoot, expectedWrong)).digest.length === 32);
  const svg = svgCase(), svgResult = await measure(svg), svgHash = hex(svgResult.digest);
  check("independent complete-name/ordered-attribute/comment hash vector", svgResult.canonical_bytes === golden("svg").canonical_bytes && svgHash === golden("svg").sha256 && hex(measurementEnvelope(svg.envelope)) === golden("svg").envelope_hex);
  for (const [label, change] of [
    ["element prefix", f => { f.tree.children[0].name[1] = "q"; }],
    ["element namespace", f => { f.tree.children[0].name[0] = "urn:other"; }],
    ["element local case", f => { f.tree.children[0].name[2] = "G"; }],
    ["attribute prefix", f => { f.tree.children[0].attrs[1][0][1] = "b"; }],
    ["attribute namespace", f => { f.tree.children[0].attrs[1][0][0] = "urn:other"; }],
    ["attribute local case", f => { f.tree.children[0].attrs[2][0][2] = "pathlength"; }],
    ["namespace declaration value", f => { f.tree.children[0].attrs[0][1] = "urn:changed"; }],
    ["attribute order", f => { f.tree.children[0].attrs.reverse(); }],
    ["attribute value", f => { f.tree.children[0].attrs[2][1] = "false"; }],
    ["comment data", f => { f.tree.children[0].children[1].comment = "roc:row=123"; }],
  ]) { const f = svgCase(); change(f); check(`canonical hash observes ${label}`, hex((await measure(f)).digest) !== svgHash); }
  const siblingCase = { tree: root([element("a"), element("b")]), envelope: records(2, [[0xffffffff, 0, [0, 1]], [0, 0, []], [1, 0, []]], [[0, 0], [0, 1]]) };
  const siblingDigest = hex((await measure(siblingCase)).digest); siblingCase.tree.children.reverse(); check("same-kind sibling order enters the physical canonical stream", hex((await measure(siblingCase)).digest) !== siblingDigest);
  const bom = await measure(textCase("\ufeff", [1])); check("leading BOM data is retained as text", bom.physical[0].data === "\ufeff");
  const extra = textCase(); extra.tree.children.push({ comment: "extra" }); await reject("actual container count must match metadata", () => measure(extra));
  const wrongKind = textCase(); wrongKind.tree.children[0] = { comment: "é😀\r" }; await reject("Text claim cannot resolve a comment", () => measure(wrongKind));
  const wrongRoot = build(element("div", [], [], html)); await reject("external root name must match exactly", () => measurePicture(wrongRoot, emptyBytes));
  const template = templateCase(), templateRoot = build(template.tree), owner = templateRoot.childNodes[0], ordinary = owner.childNodes[0], content = owner.content.childNodes[0];
  const templateResult = await measurePicture(templateRoot, measurementEnvelope(template.envelope));
  check("ordinary and intrinsic template children retain separate exact identities", templateResult.physical[1] === ordinary && templateResult.physical[2] === content && owner.childNodes[0] === ordinary && owner.content.childNodes[0] === content);
  const missingContent = { tree: root([element("template", [], [], html, "", [])]), envelope: records(1, [[0xffffffff, 0, [0]], [0, 0, []]], [[0, 0]]) };
  await reject("even empty HTML templates require Content metadata", () => measure(missingContent));
  const foreignContent = { tree: root([element("g", [], [], svg)]), envelope: records(1, [[0xffffffff, 0, [0]], [0, 0, []], [0, 1, []]], [[0, 0]]) };
  await reject("Content cannot target a foreign non-template", () => measure(foreignContent));
  const templateExtra = templateCase(); templateExtra.tree.children[0].children.push({ comment: "ordinary extra" }); await reject("equal content does not hide changed ordinary childNodes", () => measure(templateExtra));
  const control = controlCase(); check("prefixed HTML textarea ControlText role is measured", (await measure(control)).envelope.scaffolds[0].role === 0);
  const wrongControl = controlCase(); wrongControl.tree.children[0].name[0] = svg; await reject("ControlText cannot target SVG textarea spelling", () => measure(wrongControl));
  const valueOnly = build(control.tree), controlBytes = measurementEnvelope(control.envelope), controlBefore = await measurePicture(valueOnly, controlBytes); valueOnly.childNodes[0].value = "unhashed browser property";
  check("live control properties do not enter the canonical hash", hex((await measurePicture(valueOnly, controlBytes)).digest) === hex(controlBefore.digest));
  check("prefixed HTML option selected AttributeOverride is measured", (await measure(attributeCase())).envelope.scaffolds[0].role === 1);
  const orderedAttribute = attributeCase(), orderedOption = orderedAttribute.tree.children[0].children[0];
  orderedOption.attrs = [[["", "", "data-before"], "a"], [["", "", "data-after"], "b"]];
  orderedAttribute.envelope.scaffolds[0] = [1, 1, ["", "", "selected"], 1, "authored", null];
  const orderedRoot = build(orderedAttribute.tree), orderedNode = orderedRoot.childNodes[0].childNodes[0], beforeAttrs = [...orderedNode.attributes];
  const orderedResult = await measurePicture(orderedRoot, measurementEnvelope(orderedAttribute.envelope));
  check("removed selected at original middle position is retained without restoring or reordering DOM", orderedResult.envelope.scaffolds[0].logical_index === 1 && orderedNode.attributes.length === 2 && beforeAttrs.every((a, i) => orderedNode.attributes[i] === a) && orderedNode.getAttributeNodeNS(null, "selected") === null);
  for (const index of [0, 2]) {
    const positioned = structuredClone(orderedAttribute); positioned.envelope.scaffolds[0][3] = index;
    check(`removed original selected position ${index} is in bounds`, (await measure(positioned)).envelope.scaffolds[0].logical_index === index);
  }
  const beyondRemoved = structuredClone(orderedAttribute); beyondRemoved.envelope.scaffolds[0][3] = 3;
  await reject("removed original selected index cannot exceed logical attribute count", () => measure(beyondRemoved));
  const presentOriginal = attributeCase(); presentOriginal.envelope.scaffolds[0][4] = "authored";
  check("present original selected at first position is legal", (await measure(presentOriginal)).envelope.scaffolds[0].logical_index === 0);
  presentOriginal.envelope.scaffolds[0][3] = 1;
  await reject("present physical selected does not add an extra logical attribute position", () => measure(presentOriginal));
  const anotherPosition = structuredClone(orderedAttribute); anotherPosition.envelope.scaffolds[0][3] = 0;
  check("logical original attribute position is committed by the canonical digest", hex((await measure(anotherPosition)).digest) !== hex(orderedResult.digest));
  const templateClaims = attributeCase(); templateClaims.envelope.batch_bytes = 20;
  templateClaims.envelope.bindings = [[1, 1, 1, 7, 0, 0], [1, 4, 1, 0, 0, 0], [1, 4, 1, 1, 0, 1]];
  const templateClaimResult = await measure(templateClaims);
  check("TemplateNode references are measured data without a pre-init ownership verdict", templateClaimResult.envelope.bindings.filter(b => b.role === 4).map(b => b.slot).join() === "0,1");
  const changedTemplateSlot = structuredClone(templateClaims); changedTemplateSlot.envelope.bindings[2][3] = 2;
  check("canonical digest includes TemplateNode preorder references", hex(templateClaimResult.digest) !== hex((await measure(changedTemplateSlot)).digest));
  const wrongAttribute = attributeCase(); wrongAttribute.envelope.scaffolds[0][5] = "false"; await reject("AttributeOverride physical presence/value is verified", () => measure(wrongAttribute));
  const wrongAttributeRole = attributeCase(); wrongAttributeRole.envelope.scaffolds[0][2][2] = "value"; await reject("AttributeOverride role is specifically selected", () => measure(wrongAttributeRole));
  check("prefixed HTML select direct empty NoSelectionOption is measured", (await measure(selectionCase())).envelope.scaffolds[0].role === 2);
  const selectionAttrs = selectionCase(); selectionAttrs.tree.children[0].children[0].attrs.reverse(); await reject("NoSelectionOption uses exact generated ordered attributes", () => measure(selectionAttrs));
  const selectionValue = selectionCase(); selectionValue.tree.children[0].children[0].attrs[1][1] = "false"; await reject("NoSelectionOption selected value must be generated empty text", () => measure(selectionValue));
  const selectionChild = selectionCase(); selectionChild.tree.children[0].children[0].children = [{ text: "x" }]; selectionChild.envelope.physicalCount = 3; selectionChild.envelope.containers[2][2] = [2]; selectionChild.envelope.logical.push([2, 0, 0]); selectionChild.envelope.runs = [[2, 0, 2, [[1, 1]]]];
  await reject("NoSelectionOption must be empty even with otherwise valid coverage", () => measure(selectionChild));
  const large = textCase("x".repeat(4096), [4096]), largeBytes = measurementEnvelope(large.envelope), largeRoot = build(large.tree);
  let encodes = 0, hashes = 0;
  const originalEncode = TextEncoder.prototype.encode, originalInto = TextEncoder.prototype.encodeInto, subtle = globalThis.crypto.subtle, ownDigest = Object.getOwnPropertyDescriptor(subtle, "digest"), originalDigest = subtle.digest;
  TextEncoder.prototype.encode = function (...args) { encodes++; return originalEncode.apply(this, args); };
  TextEncoder.prototype.encodeInto = function (...args) { encodes++; return originalInto.apply(this, args); };
  subtle.digest = function (...args) { hashes++; return originalDigest.apply(this, args); };
  try {
    await reject("oversized actual string refuses before UTF-8 allocation or hashing", () => measurePicture(largeRoot, largeBytes, { max_measurement_bytes: 1024 }));
    check("measurement refusal calls neither TextEncoder nor WebCrypto", encodes === 0 && hashes === 0);
    await reject("oversized mount refuses before encoding or hashing", () => pictureMountFingerprint(new Uint8Array(128), { max_measurement_bytes: 64 }));
    check("mount refusal calls neither TextEncoder nor WebCrypto", encodes === 0 && hashes === 0);
  } finally {
    TextEncoder.prototype.encode = originalEncode; TextEncoder.prototype.encodeInto = originalInto;
    if (ownDigest) Object.defineProperty(subtle, "digest", ownDigest); else delete subtle.digest;
  }
  const saved = Object.getOwnPropertyDescriptor(subtle, "digest");
  try {
    subtle.digest = async () => { throw new Error("native crypto failure"); };
    await reject("native SHA-256 failure is classified without changing DOM", () => measurePicture(emptyRoot, emptyBytes));
    subtle.digest = async () => new ArrayBuffer(1);
    await reject("invalid SHA-256 result length is refused", () => pictureMountFingerprint(new Uint8Array()));
  } finally { if (saved) Object.defineProperty(subtle, "digest", saved); else delete subtle.digest; }
  return checks;
}

// A read-only facts facade for Node's encoding vectors only. Actual browser
// behavior is checked separately by building native DOM in the Chrome entry.
export function buildMeasurementFacts(description, parent = null) {
  if (Object.hasOwn(description, "text")) return { nodeType: 3, data: description.text, parentNode: parent };
  if (Object.hasOwn(description, "comment")) return { nodeType: 8, data: description.comment, parentNode: parent };
  const [namespace, prefix, local] = description.name;
  const node = { nodeType: 1, namespaceURI: namespace || null, prefix: prefix || null, localName: local, parentNode: parent, childNodes: [], attributes: [] };
  node.setAttributeNS = (uri, local, value) => { node.attributes.push({ namespaceURI: uri, prefix: null, localName: local, value }); };
  node.getAttributeNodeNS = (uri, local) => node.attributes.find(a => a.namespaceURI === uri && a.localName === local) ?? null;
  node.attributes = description.attrs.map(([[uri, prefix, local], value]) => ({ namespaceURI: uri || null, prefix: prefix || null, localName: local, value }));
  node.childNodes = description.children.map(child => buildMeasurementFacts(child, node));
  if (Object.hasOwn(description, "content")) { node.content = { nodeType: 11, childNodes: [] }; node.content.childNodes = description.content.map(child => buildMeasurementFacts(child, node.content)); }
  return node;
}
