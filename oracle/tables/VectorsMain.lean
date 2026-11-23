/-
`lake exe vectors`: write the cover sets of the table targets from the
transliteration, as the `vectors` list of each target's Roc module.

  vectors write <ChangeVectors.roc> <changes-out> <FollowVectors.roc> <follow-out>

Each module is read and kept as it is up to its line `\tvectors =`; what
follows is written here, so the types and comments above it are the
module's own and the list is never edited by hand.

Histories are drawn from a seeded series over a small universe (three
keys, three row values) on a single history, as a mounted instance has one.
A history becomes a vector when it is the first to reach a cover class:
for `table-changes`, a kind of modifier, the state of the record it
received and what it left; for `view-follow`, how the view followed its
table and a kind of change of the rows drawn.

Each list is written within what its Roc target replays (`Target`): the
modulus `update` and `update_all` add 1 under is the target's row space;
`view-follow`'s histories hold no `undo`, which its model does not
describe, and use the rebuild thresholds `View.roc` fixes, which a table of
three keys never reaches, so no view vector is `rebuilt-many`.
-/
import Tables
open Tables

/-! ### A seeded series -/

structure Rng where
  s : UInt64

def Rng.next (r : Rng) : Nat × Rng :=
  let s := r.s + 0x9E3779B97F4A7C15
  let z := (s ^^^ (s >>> 30)) * 0xBF58476D1CE4E5B9
  let z := (z ^^^ (z >>> 27)) * 0x94D049BB133111EB
  (((z ^^^ (z >>> 31)) >>> 16).toNat, { s })

def Rng.below (r : Rng) (n : Nat) : Nat × Rng :=
  let (x, r) := r.next
  (x % max n 1, r)

def nk : Nat := 3
def nv : Nat := 3

/-- What a vector file's Roc target replays: the modulus of `update`, whether
`undo` is in its vocabulary, and whether it may change the rebuild
thresholds. -/
structure Target where
  modulus : Nat
  undo : Bool
  anyCfg : Bool

/-- `fuzz/table-changes`: rows bump modulo its `row_space`. -/
def changesTarget : Target := { modulus := 4, undo := true, anyCfg := true }

/-- `fuzz/view-follow`: rows bump modulo its `row_space`; no `undo`; the
thresholds of `View.roc`. -/
def followTarget : Target := { modulus := 8, undo := false, anyCfg := false }

def ops (undo : Bool) : List Op := Id.run do
  let mut out : List Op := []
  for k in [0:nk] do
    for v in [0:nv] do
      out := out ++ [.insert k v, .put k v, .replace k v]
    out := out ++ [.update k, .remove k]
  return out ++ [.updateAll] ++ (if undo then [.undo] else [])

def starts : List Rows := [[], [(0, 0)], [(0, 1), (1, 0)], [(0, 2), (1, 0), (2, 1)]]

def windows : List Window :=
  [{ start := 0, count := 1 }, { start := 1, count := 2 }, { start := 0, count := 2 },
   { start := 1, count := 1 }, { start := 0, count := 1000 }]

/-! ### Roc values -/

def list (xs : List String) : String := "[" ++ ", ".intercalate xs ++ "]"

def rec (fields : List (String × String)) : String :=
  "{ " ++ ", ".intercalate (fields.map fun (k, v) => k ++ ": " ++ v) ++ " }"

def rowsRoc (rows : Rows) : String := list (rows.map fun (k, v) => s!"({k}, {v})")

def opRoc : Op → String
  | .insert k v => s!"Insert({k}, {v})"
  | .put k v => s!"Put({k}, {v})"
  | .replace k v => s!"Replace({k}, {v})"
  | .update k => s!"Update({k})"
  | .remove k => s!"Remove({k})"
  | .updateAll => "All"
  | .undo => "Undo"

/-- A modifier. The generator hands `other` no operations, and the Roc
targets' `Other` takes none. -/
def fnRoc : Fn → String
  | .onArg os => "On(" ++ list (os.map opRoc) ++ ")"
  | .saved i os => s!"Saved({i}, " ++ list (os.map opRoc) ++ ")"
  | .other i _ => s!"Other({i})"
  | .fresh rows => "Fresh(" ++ rowsRoc rows ++ ")"

def recordRoc (t : Table) : String :=
  match t.whole with
  | .rewritten => "Rewritten"
  | .keyed => "Keyed(" ++ list (t.record.map fun (k, b) =>
      rec [("key", toString k), ("before", match b with | .was v => s!"Was({v})" | .absent => "Absent")]) ++ ")"

def tableFields (t : Table) : List (String × String) :=
  [("rows", rowsRoc t.rows), ("record", recordRoc t), ("version", toString t.version), ("start", toString t.start)]

def boolRoc (b : Bool) : String := if b then "Bool.True" else "Bool.False"

def howRoc : How → String
  | .unchanged => "Unchanged" | .absorbed => "Absorbed" | .rebuiltMany => "Rebuilt(Many)"
  | .rebuiltRewritten => "Rebuilt(Rewritten)" | .rebuiltBehind => "Rebuilt(Behind)"

def anchorRoc : Option K → String
  | some k => s!"Row({k})"
  | none => "End"

def changeRoc : Change → String
  | .left k => s!"Left({k})"
  | .entered k b => "Entered(" ++ rec [("key", toString k), ("before", anchorRoc b)] ++ ")"
  | .moved k b => "Moved(" ++ rec [("key", toString k), ("before", anchorRoc b)] ++ ")"
  | .changed k => s!"Changed({k})"

def keysRoc (ks : List K) : String := list (ks.map toString)

def windowRoc (w : Window) : String := rec [("start", toString w.start), ("count", toString w.count)]

/-- One element of a `vectors` list: its comment naming the classes it is
the first to reach, then the record, at the list's indentation. -/
def vectorRoc (covers : List String) (fields : List (String × String)) (turns : List String) : String :=
  let c := ", ".intercalate covers
  s!"\t\t\t# Covers {c}.\n\t\t\t\{\n"
    ++ String.join (fields.map fun (k, v) => s!"\t\t\t\t{k}: {v},\n")
    ++ "\t\t\t\tturns: [\n" ++ String.join (turns.map fun l => "\t\t\t\t\t" ++ l ++ ",\n") ++ "\t\t\t\t],\n\t\t\t},\n"

/-! ### Histories -/

/-- The name a cover class gives a single operation. -/
def opKind : Op → String
  | .insert _ _ => "insert" | .put _ _ => "put" | .replace _ _ => "replace"
  | .update _ => "update" | .remove _ => "remove" | .updateAll => "update_all" | .undo => "undo"


/-- One modifier and the class it reaches: its kind, the record it was
handed, and what it left. -/
def modClass (first : Bool) (began : Table) (fn : Fn) (out : Table) : String :=
  let kind := match fn with
    | .onArg [o] => opKind o
    | .onArg _ => "ops"
    | .saved _ _ => "saved"
    | .other _ _ => "other"
    | .fresh _ => "fresh"
  let handed :=
    if first then "turn-start"
    else match began.whole with
      | .rewritten => "rewritten"
      | .keyed =>
          match fn with
          | .onArg [o] =>
              match o.key with
              | some k => if (cget began.record k).isSome then "key-recorded" else "key-unrecorded"
              | none => "keyed"
          | _ => "keyed"
  let left :=
    if out.whole == .rewritten && began.whole == .keyed then "rewritten"
    else if out.version == began.version then "no-write" else "writes"
  s!"{kind} {handed} {left}"

structure Turn where
  fns : List Fn
  query : Option Nat
  window : Option Window
  keep : Bool

/-- A history: where the cell and the view start, and its turns. -/
structure History where
  start : Rows
  q : Nat
  w : Window
  cfg : Cfg
  turns : List Turn

def randFn (target : Target) (r : Rng) (saved : Nat) : Fn × Rng := Id.run do
  let ops := ops target.undo
  let (c, r) := r.below 10
  let (o1, r) := r.below ops.length
  let (o2, r) := r.below ops.length
  let (two, r) := r.below 3
  let (i, r) := r.below (max saved 1)
  let (st, r) := r.below starts.length
  let op1 := ops.getD o1 .undo
  let op2 := ops.getD o2 .undo
  if saved > 0 && c == 7 then return (.saved i (if two == 0 then [op1] else []), r)
  if saved > 0 && c == 8 then return (.other i [], r)
  if c == 9 then return (.fresh (starts.getD st []), r)
  return (.onArg (if two == 0 then [op1, op2] else [op1]), r)

def randHistory (target : Target) (seed : Nat) : History := Id.run do
  let mut r : Rng := { s := UInt64.ofNat (seed * 2654435761 + 7) }
  let (st, r1) := r.below starts.length
  let (q, r2) := r1.below 3
  let (w, r3) := r2.below windows.length
  let (c, r4) := r3.below 4
  let (n, r5) := r4.below 3
  r := r5
  let mut turns : Array Turn := #[]
  let mut saved := 0
  for _ in [0:n + 1] do
    let (m, r') := r.below 2
    r := r'
    let mut fns : Array Fn := #[]
    for _ in [0:m + 1] do
      let (fn, r') := randFn target r saved
      r := r'
      fns := fns.push fn
    let (aq, r') := r.below 5
    let (aw, r'') := r'.below 4
    let (qv, r3) := r''.below 3
    let (wv, r4) := r3.below windows.length
    let (k, r5) := r4.below 3
    r := r5
    let keep := k == 0 && saved < 2
    turns := turns.push { fns := fns.toList, query := if aq == 0 then some qv else none,
                          window := if aw == 0 then windows[wv]? else none, keep }
    if keep then saved := saved + 1
  return { start := starts.getD st [], q, w := windows.getD w { start := 0, count := 1 },
           cfg := if c == 0 && target.anyCfg then { ratio := 1, floor := 0 } else {}, turns := turns.toList }

/-- The name a cover class gives how a view followed its table. -/
def howClass : How → String
  | .unchanged => "unchanged" | .absorbed => "absorbed" | .rebuiltMany => "rebuilt-many"
  | .rebuiltRewritten => "rebuilt-rewritten" | .rebuiltBehind => "rebuilt-behind"

/-- Replay a history: its fields and turns as Roc values for each target,
and the classes each reaches. `none` if the site crashes (a contract error,
never part of a cover set). -/
def replay (target : Target) (h : History) :
    Option (List (String × String) × List String × List String × List (String × String) × List String × List String) := Id.run do
  let cellId := 5
  let mut cell := cellStart h.start cellId
  let some site0 := (Site.mount cell h.q h.w).toOption | return none
  let mut site := site0
  let mut saved : List Table := []
  let tfields := [("start", rowsRoc h.start)]
  let vfields := [("ratio", toString h.cfg.ratio), ("floor", toString h.cfg.floor), ("rows", rowsRoc h.start),
                  ("query", toString h.q), ("window", windowRoc h.w)]
  let mut tturns : List String := []
  let mut vturns : List String := []
  let mut tcls : List String := []
  let mut vcls : List String := []
  for t in h.turns do
    let mut first := true
    let mut t0 := cell
    for fn in t.fns do
      let began := beginChanges .none t0
      let out := kept .none (fn.run .none target.modulus saved began) (mark began)
      tcls := tcls ++ [modClass first began fn out]
      first := false
      t0 := out
    let wrote := !t.fns.isEmpty
    let after := finishChanges t0
    let mods := ("modifiers", list (t.fns.map fnRoc))
    let keep := ("keep", boolRoc t.keep)
    tturns := tturns ++ [rec [mods, ("outcome", rec (tableFields after)), keep]]
    if wrote || t.query.isSome || t.window.isSome then
      match Site.changed .none h.cfg site after t.query t.window with
      | .error _ => return none
      | .ok (s', changes, how, _) =>
          let kinds := (changes.map fun
            | .left _ => "left" | .entered _ _ => "entered" | .moved _ _ => "moved"
            | .changed _ => "changed").eraseDups
          vcls := vcls ++ ((if kinds.isEmpty then ["none"] else kinds).map fun k => s!"{howClass how} {k}")
          let q := match t.query with | some q => s!"Ok({q})" | none => "Err(Same)"
          let w := match t.window with | some w => "Ok(" ++ windowRoc w ++ ")" | none => "Err(Same)"
          let outcome := rec ([("how", howRoc how)] ++ tableFields after
            ++ [("keys", keysRoc (s'.view.seq.map (·.2))), ("drawn", keysRoc s'.drawn), ("changes", list (changes.map changeRoc))])
          vturns := vturns ++ [rec [mods, ("query", q), ("window", w), ("outcome", outcome), keep]]
          site := s'
    cell := after
    if t.keep then
      saved := saved ++ [cell]
  return some (tfields, tturns, tcls, vfields, vturns, vcls)

/-- A Roc module up to and including its line `\tvectors =`, which must
appear once. -/
def head (path : String) : IO String := do
  let text ← IO.FS.readFile path
  match text.splitOn "\n\tvectors =\n" with
  | [before, _] => return before ++ "\n\tvectors =\n"
  | _ => throw (IO.userError s!"{path}: expected one line `\tvectors =`")

def writeVectors (changesIn changesOut followIn followOut : String) : IO UInt32 := do
  let mut tseen : List String := []
  let mut vseen : List String := []
  let mut tout := ""
  let mut vout := ""
  let mut nt := 0
  let mut nv' := 0
  for seed in [0:20000] do
    match replay changesTarget (randHistory changesTarget seed) with
    | none => pure ()
    | some (fields, turns, tcls, _, _, _) =>
        let tnew := tcls.eraseDups.filter (!tseen.contains ·)
        if !tnew.isEmpty then
          tseen := tseen ++ tnew
          tout := tout ++ vectorRoc tnew ([("seed", toString seed)] ++ fields) turns
          nt := nt + 1
    match replay followTarget (randHistory followTarget seed) with
    | none => pure ()
    | some (_, _, _, fields, turns, vcls) =>
        let vnew := vcls.eraseDups.filter (!vseen.contains ·)
        if !vnew.isEmpty then
          vseen := vseen ++ vnew
          vout := vout ++ vectorRoc vnew ([("seed", toString seed)] ++ fields) turns
          nv' := nv' + 1
  let close := "\t\t]\n}\n"
  IO.FS.writeFile changesOut ((← head changesIn) ++ "\t\t[\n" ++ tout ++ close)
  IO.FS.writeFile followOut ((← head followIn) ++ "\t\t[\n" ++ vout ++ close)
  IO.println s!"wrote {nt} vectors covering {tseen.length} classes to {changesOut}"
  IO.println s!"wrote {nv'} vectors covering {vseen.length} classes to {followOut}"
  let hows := ["unchanged", "absorbed", "rebuilt-rewritten"]
  let missing := hows.filter fun h => !(vseen.any (·.startsWith (h ++ " ")))
  if !missing.isEmpty then
    IO.eprintln s!"no vector for: {", ".intercalate missing}"
    return 1
  return 0

def main (args : List String) : IO UInt32 := do
  match args with
  | ["write", a, b, c, d] => writeVectors a b c d
  | _ => IO.eprintln "usage: vectors write <ChangeVectors.roc> <changes-out> <FollowVectors.roc> <follow-out>"; return 2
