/-
`lake exe vectors`: write the structure target's vector files from the
reference, and check vector files against it.

  vectors structure <vectors.trace> <vectors-bad.trace>
  vectors check <file>...

A trace with no `variant` line must be accepted by the reference. A trace
with one must be rejected, by the observation and at the step it names.
-/
import Turns
open Turns Turns.Structure

def parseBug : String → Option Bug
  | "none" => some .none
  | "twoPassInner" => some .twoPassInner
  | "twoPassOuter" => some .twoPassOuter
  | "noJoinKeep" => some .noJoinKeep
  | "noJoinClear" => some .noJoinClear
  | "perWrite" => some .perWrite
  | "rowReset" => some .rowReset
  | "rowResurrect" => some .rowResurrect
  | "noWalk" => some .noWalk
  | "underSig" => some .underSig
  | "pruneWakes" => some .pruneWakes
  | _ => none

/-- The known-bad algorithms, by the name a `variant` line gives them. -/
def badAlgorithms : List (String × Bug) :=
  ["twoPassInner", "twoPassOuter", "noJoinKeep", "noJoinClear", "perWrite", "rowReset",
    "rowResurrect", "noWalk", "underSig", "pruneWakes"].filterMap fun n => (parseBug n).map (n, ·)

/-- A trace as the incremental algorithm `g` observes it: driven by the
same click choices on its own page, with its page and its evaluation log
recorded after each. -/
def modelTrace (g : Cfg) (tree : List RNode) (name : String) (clicks : List Nat) : Trace := Id.run do
  let p := toKernel tree
  let (s0, dom0, _) := mountProg g p
  let mut s := s0
  let mut dom := dom0
  let mut steps := #[]
  for r in clicks do
    let buttons := (flatDoms [] dom).filterMap fun
      | (id, .button _) => some id
      | _ => none
    if buttons.isEmpty then break
    let k := r % buttons.length
    match turn g p s (buttons.getD k []) with
    | none => break
    | some (s1, tx) =>
        s := s1
        dom := match applyCmds dom tx.cmds with
          | .ok d => d
          | .error _ => dom
        steps := steps.push { button := k, page := (flatDoms [] dom).map (·.2), evals := some tx.log.size }
  return { name, tree, page0 := (flatDoms [] dom0).map (·.2), steps := steps.toList }

/-- The structure target's own directed examples, as byte inputs: the tree
bytes and the event bytes, whose odd positions are the click choices. -/
def byteExamples : List (String × List Nat × List Nat) := [
  ("valued-when-of-two-writes",
    [1, 5, 0, 1, 5, 0, 2, 3, 130, 1, 5, 0, 0, 0, 12, 1, 2],
    [0, 3, 0, 3, 0, 4, 0, 1, 0, 1, 0, 3, 0, 4]),
  ("valued-rows-of-two-writes",
    [1, 5, 0, 1, 5, 0, 2, 7, 130, 1, 5, 0, 0, 12, 1, 2],
    [0, 1, 0, 3, 0, 3, 0, 4, 0, 5, 0, 5]),
  ("valued-rows-of-outer-derive",
    [1, 15, 0, 1, 5, 0, 2, 7, 130, 1, 5, 0, 0, 12, 0, 1],
    [0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 4, 0, 4, 0, 6, 0, 2]),
  ("valued-rows-of-inner-derive",
    [1, 5, 0, 1, 15, 1, 2, 7, 129, 1, 5, 0, 0, 12, 0, 1],
    [0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 4, 0, 4, 0, 6, 0, 2])]

def oddPositions (xs : List Nat) : List Nat :=
  ((List.range xs.length).zip xs).filterMap fun (i, x) => if i % 2 = 1 then some x else none

/-- Hand-written trees for shapes the byte examples do not hold. -/
def treeExamples : List (String × String × List Nat) := [
  -- Rows keyed by the root, each with a state of its own: a row kept across
  -- a change of the list keeps its state; a key removed and inserted again
  -- starts at 0.
  ("rows-kept-and-reinserted", "(Each 0 ((Layer 0 0 ())))", [0, 2, 0, 0, 3, 0, 0, 0, 2]),
  -- One click writes two nested states; a reader of the inner one only, which
  -- the outer write's pass does not reach, is refreshed by the walk.
  ("walk-to-inner-write", "(Layer 0 0 ((Layer 0 0 ((Show 2) (Bump2 1 2)))))", [4, 4, 2, 4]),
  -- A `Pair` of the inner state, its derived value and the outer state, all
  -- written by one click.
  ("pair-of-two-writes", "(Layer 0 0 ((Layer 0 0 ((Pair 2 1) (Bump2 1 2)))))", [4, 4, 3, 4]),
  -- A `when` on the outer state and a `derive` of the inner one, both
  -- written by one click, with local state in the branch.
  ("when-of-outer-and-inner-derive",
    "(Layer 0 0 ((Layer 0 0 ((Layer 1 2 ((When 177 ((Layer 0 0 ())) ()))) (Bump2 1 2)))))",
    [5, 3, 5, 5, 3, 5])]

/-- Known-bad algorithms the generator's trees cannot tell from the
reference, and why. -/
def unreachable : List (String × String) := [
  ("pruneWakes", "since every derived layer the generator builds (x * 2 + 1, x + 7) is injective, a derive it wakes never recomputes an equal value")]

def seedTrees (seed : Nat) : List RNode × List Nat :=
  let bytes := (randoms seed 80).toList.map (· % 256)
  (decode bytes, (randoms (seed + 1000003) 8).toList.map (· % 256))

def writeStructure (good bad : String) : IO UInt32 := do
  let mut traces : Array Trace := #[]
  for (name, tree, events) in byteExamples do
    traces := traces.push (refTrace (decode tree) name (oddPositions events))
  for (name, text, clicks) in treeExamples do
    let some tree := parseTree text | IO.eprintln s!"does not parse: {text}"; return 2
    traces := traces.push (refTrace tree name clicks)
  for i in [0:16] do
    let (tree, clicks) := seedTrees (100 + i)
    traces := traces.push (refTrace tree s!"seeded-{100 + i}" clicks)
  -- A program on which each known-bad algorithm is rejected, from the
  -- first seed that has one.
  let mut missing : List String := []
  for (vname, b) in badAlgorithms do
    let rejected := traces.any fun t =>
      (checkTrace (modelTrace { bug := b } t.tree t.name (t.steps.map (·.button)))).observation.isSome
    if !rejected then
      let mut found := false
      for seed in [1000:4000] do
        let (tree, clicks) := seedTrees seed
        if (checkTrace (modelTrace { bug := b } tree "" clicks)).observation.isSome then
          traces := traces.push (refTrace tree s!"witness-{vname}-{seed}" clicks)
          found := true
          break
      if !found then missing := missing ++ [vname]
  let hg ← IO.FS.Handle.mk good .write
  hg.putStr "# fuzz/structure vectors: written by oracle/turns (`lake exe vectors structure`); do not edit.\n"
  hg.putStr "# Grammar and the generator these trees follow: oracle/README.md.\n"
  for t in traces do hg.putStr t.text
  -- The same programs and clicks, as each known-bad algorithm observes
  -- them: at most three rejected traces per algorithm.
  let hb ← IO.FS.Handle.mk bad .write
  hb.putStr "# fuzz/structure known-bad observations: written by oracle/turns (`lake exe vectors structure`); do not edit.\n"
  hb.putStr "# Every trace here must be rejected by the reference, by the observation and at the step its variant line names.\n"
  let mut nbad := 0
  for (vname, b) in badAlgorithms do
    let mut n := 0
    for t in traces do
      if n ≥ 3 then break
      let m := modelTrace { bug := b } t.tree t.name (t.steps.map (·.button))
      match (checkTrace m).observation with
      | some (o, step) =>
          hb.putStr { m with variant := some (vname, o, step) }.text
          n := n + 1
      | none => pure ()
    nbad := nbad + n
  IO.println s!"wrote {traces.size} traces to {good} and {nbad} to {bad}"
  for vname in missing do
    if !(unreachable.any (·.1 == vname)) then
      IO.eprintln s!"no program rejects {vname}"
      return 1
  for (vname, why) in unreachable do
    IO.println s!"{vname}: no vector, {why}"
  return 0

def checkFiles (files : List String) : IO UInt32 := do
  let mut failed := false
  for file in files do
    let text ← IO.FS.readFile file
    match parseTraces text with
    | .error e => IO.eprintln s!"{file}: {e}"; return 2
    | .ok traces =>
        let mut steps := 0
        let mut bad := 0
        for t in traces do
          steps := steps + t.steps.length
          let got := (checkTrace t).observation
          match t.variant, got with
          | none, none => pure ()
          | none, some (o, n) =>
              bad := bad + 1
              IO.println s!"  {t.name}: rejected by the {o.name} at step {n}"
          | some (v, o, n), some (o', n') =>
              if o != o' || n != n' then
                bad := bad + 1
                IO.println s!"  {t.name} ({v}): rejected by the {o'.name} at step {n'}, not the {o.name} at step {n}"
          | some (v, _, _), none =>
              bad := bad + 1
              IO.println s!"  {t.name} ({v}): accepted, but it is a known-bad observation"
        if bad > 0 then failed := true
        IO.println s!"{file}: traces={traces.size} steps={steps} wrong={bad}"
  return (if failed then 1 else 0)

def main (args : List String) : IO UInt32 := do
  match args with
  | ["structure", good, bad] => writeStructure good bad
  | "check" :: files => checkFiles files
  | ["show", text] =>
      match parseTree text with
      | some tree =>
          IO.println s!"prog{blockSx (toKernel tree).body}"
          return 0
      | none => IO.eprintln "does not parse"; return 2
  | ["decode", bytes] =>
      let tree := decode ((bytes.splitOn ",").filterMap String.toNat?)
      IO.println (treeSx tree)
      IO.println s!"kernel{blockSx (toKernel tree).body}"
      return 0
  | _ =>
      IO.eprintln "usage: vectors structure <vectors.trace> <vectors-bad.trace>"
      IO.eprintln "       vectors check <file>..."
      IO.eprintln "       vectors show <tree> | decode <byte,byte,...>"
      return 2
