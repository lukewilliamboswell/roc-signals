// Test-owned SPC1 fixtures. These explicit node/role facts are independent of
// the production decoder, native renderer and future hash implementation.
const word = n => [n & 255, (n >>> 8) & 255, (n >>> 16) & 255, n >>> 24];
const string = value => { const bytes = [...new TextEncoder().encode(value)]; return [...word(bytes.length), ...bytes]; };
const name = value => [...string(value[0]), ...string(value[1]), ...string(value[2])];
const list = (values, encode) => [...word(values.length), ...values.flatMap(encode)];
const optional = value => value === null ? [0] : [1, ...string(value)];
const html = "http://www.w3.org/1999/xhtml";
function fixture() {
  return {
    root: [html, "", "div"], batch_bytes: 100, physicalCount: 10,
    containers: [[0xffffffff, 0, [0, 6, 8]], [0, 0, [1, 2, 3]], [3, 0, [4]], [3, 1, [5]], [5, 0, []], [6, 0, [7]], [8, 0, [9]], [9, 0, []]],
    logical: [[0, 0], [2, 0, 0], [2, 0, 1], [2, 0, 2], [1, 2], [0, 3], [1, 4], [0, 5], [0, 6], [3, 5, 0, "textarea logical"], [4, 5, 1, "textarea comment"], [0, 8], [3, 6, 0, ""], [2, 1, 0]],
    runs: [[1, 0, 1, [[1, 0], [2, 1], [3, 2]]], [0, 3, null, [[13, 0]]]],
    bindings: [[1, 0, 1, 0, 0, 0], [20, 1, 2, 7, 0, 5], [20, 2, 2, 0, 1, 2], [20, 3, 3, 1, 5, 7], [20, 2, 2, 1, 5, 7], [99, 0, 4, 0, 0, 9]],
    scaffolds: [[0, 6, 5, 7], [1, 6, ["", "", "value"], null, "edited"], [2, 8, 9]],
  };
}
function encode(f) {
  return Uint8Array.from([83, 80, 67, 49, 1, 0, 19, 0, ...word(0), ...name(f.root), ...word(f.batch_bytes), ...Array(32).fill(17), ...Array(32).fill(34), ...word(f.physicalCount),
    ...list(f.containers, ([owner, role, children]) => [...word(owner), role, ...list(children, word)]),
    ...list(f.logical, ([target, a, b, data]) => [target, ...word(a), ...(target === 2 ? word(b) : target >= 3 ? [...word(b), ...string(data)] : [])]),
    ...list(f.runs, ([container, index, physical, parts]) => [...word(container), ...word(index), ...(physical === null ? [0] : [1, ...word(physical)]), ...list(parts, ([logical, units]) => [...word(logical), ...word(units)])]),
    ...list(f.bindings, ([birth, role, address, slot, kind, logical]) => [...word(birth), role, ...word(address), ...word(slot), kind, ...word(logical)]),
    ...list(f.scaffolds, ([role, owner, a, b, c]) => [role, ...word(owner), ...(role === 0 ? [...word(a), ...(b === null ? [0] : [1, ...word(b)])] : role === 1 ? [...name(a), ...optional(b), ...optional(c)] : word(a))]),
  ]);
}
export function pictureEnvelopeCases(decode) {
  const checks = [], check = (label, ok) => checks.push([label, !!ok]);
  const valid = encode(fixture()), decoded = decode(valid);
  check("independent topology and every declared logical/scaffold variant decode", decoded.physicalCount === 10 && decoded.containers.length === 8 && decoded.logical.length === 14 && decoded.runs.length === 2 && decoded.bindings.length === 6 && decoded.scaffolds.length === 3);
  check("logical constructed positions remain distinct from physical child indices", decoded.logical[10].logical_child_index === 1 && decoded.containers[5].children.length === 1);
  check("zero and astral text part lengths are retained for later DOM checks", decoded.runs[0].parts.map(p => p.utf16Units).join() === "0,1,2" && decoded.runs[0].utf16Units === 3 && decoded.runs[1].physical === null);
  check("digests decode as data without certifying either hash", decoded.mountFingerprint.length === 32 && decoded.mountFingerprint[0] === 17 && decoded.expectedDigest[0] === 34);
  const empty = { root: [html, "", "main"], batch_bytes: 0, physicalCount: 0, containers: [[0xffffffff, 0, []]], logical: [], runs: [], bindings: [], scaffolds: [] };
  check("empty picture has an explicit external Children container", decode(encode(empty)).containers.length === 1);
  const rootCases = [["urn:entry", "p", "entry"], ["http://www.w3.org/2000/svg", "", "h:div"], ["", "", "entry"], ["urn:entry", "", "xmlns"]];
  for (const root of rootCases) { const f = fixture(); f.root = root; const value = decode(encode(f)).root; check(`root tuple retained ${JSON.stringify(root)}`, value.namespace === (root[0] || null) && value.prefix === (root[1] || null) && value.local === root[2]); }
  const reject = (label, bytes, limits) => { let error; try { decode(bytes, limits); } catch (e) { error = e; } check(label, error?.message.startsWith("picture envelope:")); };
  const mutate = (label, change) => { const f = fixture(); change(f); reject(label, encode(f)); };
  mutate("empty local name", f => { f.root[2] = ""; });
  mutate("nonpreorder subtree placement", f => { f.containers[1][2].push(4); f.containers[2][2] = []; });
  mutate("physical node ceiling", f => { f.physicalCount = 262145; });
  mutate("missing mount container", f => { f.containers = []; });
  mutate("wrong external container", f => { f.containers[0][0] = 0; });
  mutate("second external owner", f => { f.containers[1][0] = 0xffffffff; });
  mutate("unknown container role", f => { f.containers[1][1] = 2; });
  mutate("duplicate owner/role", f => { f.containers.push([0, 0, []]); });
  mutate("out of range physical child", f => { f.containers[0][2][0] = 10; });
  mutate("duplicate physical placement", f => { f.containers[1][2].push(6); });
  mutate("owner must precede child", f => { f.containers[1][2][0] = 0; });
  mutate("physical sibling order", f => { f.containers[0][2] = [6, 0, 8]; });
  mutate("missing physical placement", f => { f.containers[0][2].pop(); });
  mutate("missing element Children container", f => { f.containers.pop(); });
  mutate("duplicate principal physical claim", f => { f.logical[4] = [1, 0]; });
  mutate("missing physical role coverage", f => { f.logical[4] = [4, 1, 0, "unrepresented"]; });
  mutate("unknown logical target", f => { f.logical[0][0] = 5; });
  mutate("constructed position uses final logical bounds", f => { f.logical[10][2] = 2; });
  mutate("duplicate constructed position", f => { f.logical[10][2] = 0; });
  mutate("invalid constructed container", f => { f.logical[10][1] = 8; });
  mutate("unknown text run", f => { f.logical[1][1] = 3; });
  mutate("missing text part", f => { f.logical.push([2, 0, 3]); });
  mutate("text part back reference", f => { f.runs[0][3][0][0] = 2; });
  mutate("empty text run", f => { f.runs[0][3] = []; });
  mutate("omitted text cannot contain nonzero units", f => { f.runs[1][3][0][1] = 1; });
  mutate("run physical node must occupy exact container position", f => { f.runs[0][1] = 1; });
  mutate("omitted run gap bounds", f => { f.runs[1][1] = 4; });
  mutate("duplicate run position", f => { f.runs[1][0] = 1; f.runs[1][1] = 0; });
  mutate("binding cannot address mount root", f => { f.bindings[0][2] = 0; });
  mutate("binding cannot address effect sentinel", f => { f.bindings[0][2] = 0xffffffff; });
  mutate("birth cannot name flags byte", f => { f.bindings[0][0] = 0; });
  check("batch_bytes includes the ordinary flags byte and accepts the last offset", decoded.batch_bytes === 100 && decoded.bindings.at(-1).birthOffset === 99);
  mutate("binding at batch length is out of range", f => { f.bindings[0][0] = 100; });
  mutate("binding beyond batch length is out of range", f => { f.bindings[0][0] = 101; });
  mutate("empty ordinary batch cannot have a binding", f => { f.batch_bytes = 0; });
  mutate("flags-only ordinary batch cannot have a binding", f => { f.batch_bytes = 1; });
  const flagsOnly = structuredClone(empty); flagsOnly.batch_bytes = 1; check("flags-only batch without bindings remains valid", decode(encode(flagsOnly)).batch_bytes === 1);
  const firstCommand = fixture(); firstCommand.batch_bytes = 2; firstCommand.bindings = [[1, 0, 1, 0, 0, 0]]; check("first command byte is a valid birth inside a two-byte batch", decode(encode(firstCommand)).bindings[0].birthOffset === 1);
  mutate("unknown binding role", f => { f.bindings[0][1] = 4; });
  mutate("Static unused slot", f => { f.bindings[0][3] = 1; });
  mutate("Row unused kind", f => { f.bindings[1][4] = 1; });
  mutate("Hole kind bounds", f => { f.bindings[2][4] = 7; });
  mutate("Alias kind bounds", f => { f.bindings[3][4] = 3; });
  mutate("binding logical bounds", f => { f.bindings[0][5] = 14; });
  mutate("duplicate principal birth/address across roles", f => { f.bindings[3][0] = 20; f.bindings[3][2] = 2; });
  mutate("duplicate hole birth/row/slot", f => { f.bindings[4][3] = 0; });
  mutate("unknown scaffold role", f => { f.scaffolds[0][0] = 3; });
  mutate("scaffold owner must be an Element", f => { f.scaffolds[1][1] = 2; });
  mutate("control text container belongs to declared owner", f => { f.scaffolds[0][2] = 1; });
  mutate("control text physical node must belong to container", f => { f.scaffolds[0][3] = 1; });
  mutate("duplicate physical scaffold claim", f => { f.scaffolds.push([2, 8, 9]); });
  mutate("attribute override identity excludes prefix", f => { f.scaffolds[1][2] = ["urn:attr", "a", "key"]; f.scaffolds.push([1, 6, ["urn:attr", "b", "key"], null, "other"]); });
  mutate("selection scaffold cannot be nested under another owner", f => {
    f.physicalCount = 11; f.containers[7][2] = [10]; f.containers.push([10, 0, []]); f.logical.push([0, 9]); f.scaffolds[2][2] = 10;
  });
  const control = { root: [html, "", "div"], batch_bytes: 0, physicalCount: 1, containers: [[0xffffffff, 0, [0]], [0, 0, []]], logical: [[0, 0], [3, 1, 0, ""]], runs: [], bindings: [], scaffolds: [[0, 0, 1, null]] };
  check("omitted control text allows only constructed logical originals", decode(encode(control)).logical[1].data === "");
  const omittedMixed = structuredClone(control); omittedMixed.physicalCount = 2; omittedMixed.containers[1][2] = [1]; omittedMixed.logical.push([1, 1]); reject("omitted control text container must be physically empty", encode(omittedMixed));
  const presentMixed = structuredClone(control); presentMixed.physicalCount = 3; presentMixed.containers[1][2] = [1, 2]; presentMixed.logical.push([1, 2]); presentMixed.scaffolds[0][3] = 1; reject("present control text cannot coexist with other physical children", encode(presentMixed));
  const runMixed = structuredClone(control); runMixed.physicalCount = 2; runMixed.containers[1][2] = [1]; runMixed.logical[1] = [2, 0, 0]; runMixed.runs = [[1, 0, null, [[1, 0]]]]; runMixed.scaffolds[0][3] = 1; reject("ControlText source originals cannot use TextPart runs", encode(runMixed));
  const badPresence = encode({ ...control, logical: [[0, 0]], scaffolds: [[1, 0, ["", "", "value"], null, null]] }); badPresence[badPresence.length - 1] = 2; reject("presence is strictly zero or one", badPresence);
  const utf8Data = valid.slice(); const marker = [...new TextEncoder().encode("textarea logical")]; const dataOffset = utf8Data.findIndex((_, i) => marker.every((value, j) => utf8Data[i + j] === value)); utf8Data[dataOffset] = 255; reject("constructed data UTF-8 is strict", utf8Data);
  check("exact configured depth boundary is accepted", decode(valid, { maxDepth: 3 }).physicalCount === 10);
  check("empty picture permits zero node and depth caps", decode(encode(empty), { maxNodes: 0, maxDepth: 0 }).physicalCount === 0);
  for (const [target, label] of [[3, "constructed text"], [4, "constructed comment"]]) {
    const rootLeaf = structuredClone(empty); rootLeaf.logical = [[target, 0, 0, "leaf"]];
    reject(`${label} under Mount exceeds depth zero`, encode(rootLeaf), { maxDepth: 0 });
    check(`${label} under Mount fits depth one`, decode(encode(rootLeaf), { maxDepth: 1 }).logical.length === 1);
    const nested = structuredClone(control); nested.logical[1][0] = target;
    reject(`${label} below a depth-one element exceeds depth one`, encode(nested), { maxDepth: 1 });
    check(`${label} below a depth-one element fits depth two`, decode(encode(nested), { maxDepth: 2 }).logical.length === 2);
  }
  const omittedRoot = structuredClone(empty); omittedRoot.logical = [[2, 0, 0]]; omittedRoot.runs = [[0, 0, null, [[0, 0]]]];
  reject("omitted zero text under Mount exceeds depth zero", encode(omittedRoot), { maxDepth: 0 });
  check("omitted zero text under Mount fits depth one", decode(encode(omittedRoot), { maxDepth: 1 }).logical.length === 1);
  const omittedNested = structuredClone(control); omittedNested.logical[1] = [2, 0, 0]; omittedNested.runs = [[1, 0, null, [[1, 0]]]]; omittedNested.scaffolds = [];
  reject("omitted zero text below a depth-one element exceeds depth one", encode(omittedNested), { maxDepth: 1 });
  check("omitted zero text below a depth-one element fits depth two", decode(encode(omittedNested), { maxDepth: 2 }).logical.length === 2);
  reject("bounded depth", valid, { maxDepth: 2 });
  reject("bounded nodes", valid, { maxNodes: 9 });
  reject("bounded envelope bytes", valid, { maxBytes: valid.length - 1 });
  reject("unknown limit", valid, { arbitrary: 1 });
  reject("binary input type", [...valid]);
  const detached = valid.slice(); structuredClone(detached, { transfer: [detached.buffer] }); reject("detached input is classified malformed", detached);
  const nonzeroOffset = new Uint8Array(valid.length + 8); nonzeroOffset.set(valid, 5); check("binary views honor byteOffset and byteLength", decode(nonzeroOffset.subarray(5, 5 + valid.length)).physicalCount === 10);
  reject("noninteger limit", valid, { maxDepth: 1.5 });
  reject("cannot enlarge protocol ceiling", valid, { maxBytes: 16 * 1024 * 1024 });
  reject("trailing bytes", Uint8Array.from([...valid, 0]));
  for (const [label, offset, value] of [["magic", 0, 0], ["schema", 4, 2], ["protocol", 6, 18], ["flags", 8, 1], ["invalid UTF-8", 16, 255]]) {
    const bytes = valid.slice(); bytes[offset] = value; reject(label, bytes);
  }
  for (let i = 0; i < valid.length; i++) {
    let error; try { decode(valid.subarray(0, i)); } catch (e) { error = e; }
    if (!error?.message.startsWith("picture envelope:")) { check(`truncation ${i}`, false); break; }
    if (i === valid.length - 1) check("every byte truncation is classified malformed", true);
  }
  const hugeCount = encode(empty); const containerOffset = 12 + name(empty.root).length + 4 + 64 + 4;
  hugeCount.set([255, 255, 255, 255], containerOffset); reject("count bomb rejected before allocation", hugeCount);
  return checks;
}
