/-
`lake exe vectors`: write the cover sets of the table targets from the
transliteration.

  vectors write <table-changes/vectors.txt> <view-follow/vectors.txt>

Histories are drawn from a seeded series over a small universe (three
keys, three row values) on a single history, as a mounted instance has one.
A history becomes a vector when it is the first to reach a cover class:
for `table-changes`, a kind of modifier, the state of the record it
received and what it left; for `view-follow`, how the view followed its
table and a kind of change of the rows drawn. `oracle/README.md` states the
grammar.

Each file is written within what its Roc target replays (`Target`): the
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

/-! ### Text -/

def rowsTok (rows : Rows) : String := " ".intercalate (rows.map fun (k, v) => s!"{k}:{v}")

def opTok : Op → String
  | .insert k v => s!"insert({k},{v})"
  | .put k v => s!"put({k},{v})"
  | .replace k v => s!"replace({k},{v})"
  | .update k => s!"update({k})"
  | .remove k => s!"remove({k})"
  | .updateAll => "update_all"
  | .undo => "undo"

def fnTok : Fn → String
  | .onArg os => "on " ++ " ".intercalate (os.map opTok)
  | .saved i os => s!"saved {i}" ++ String.join (os.map fun o => " " ++ opTok o)
  | .other i os => s!"other {i}" ++ String.join (os.map fun o => " " ++ opTok o)
  | .fresh rows => s!"fresh {rowsTok rows}"

def recordTok (t : Table) : String :=
  match t.whole with
  | .rewritten => "rewritten"
  | .keyed => "keyed" ++ String.join (t.record.map fun (k, b) =>
      match b with
      | .was v => s!" {k}=was:{v}"
      | .absent => s!" {k}=absent")

def tableTok (t : Table) : String :=
  s!"rows {rowsTok t.rows} | {recordTok t} | {t.version} {t.start}"

def howTok : How → String
  | .unchanged => "unchanged" | .absorbed => "absorbed" | .rebuiltMany => "rebuilt-many"
  | .rebuiltRewritten => "rebuilt-rewritten" | .rebuiltBehind => "rebuilt-behind"

def anchorTok : Option K → String
  | some k => toString k
  | none => "end"

def changeTok : Change → String
  | .left k => s!"left:{k}"
  | .entered k b => s!"entered:{k}@{anchorTok b}"
  | .moved k b => s!"moved:{k}@{anchorTok b}"
  | .changed k => s!"changed:{k}"

def keysTok (ks : List K) : String := " ".intercalate (ks.map toString)

/-! ### Histories -/

/-- One modifier and the class it reaches: its kind, the record it was
handed, and what it left. -/
def modClass (first : Bool) (began : Table) (fn : Fn) (out : Table) : String :=
  let kind := match fn with
    | .onArg [o] => (opTok o).takeWhile (· != '(')
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

/-- Replay a history: the vector's text for each target, and the classes
each reaches. `none` if the site crashes (a contract error, never part of a
cover set). -/
def replay (target : Target) (h : History) : Option (String × List String × String × List String) := Id.run do
  let cellId := 5
  let mut cell := cellStart h.start cellId
  let some site0 := (Site.mount cell h.q h.w).toOption | return none
  let mut site := site0
  let mut saved : List Table := []
  let mut tc := s!"start {rowsTok h.start}\n"
  let mut vf := s!"cfg {h.cfg.ratio} {h.cfg.floor}\ntable {rowsTok h.start}\nview {h.q} {h.w.start} {h.w.count}\n"
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
    let line := " ; ".intercalate (t.fns.map fnTok)
    tc := tc ++ s!"turn {line}\n  -> {tableTok after}\n"
    let extra := (match t.query with | some q => s!" ; query {q}" | none => "")
      ++ (match t.window with | some w => s!" ; window {w.start} {w.count}" | none => "")
    if wrote || t.query.isSome || t.window.isSome then
      match Site.changed .none h.cfg site after t.query t.window with
      | .error _ => return none
      | .ok (s', changes, how, _) =>
          let kinds := (changes.map fun
            | .left _ => "left" | .entered _ _ => "entered" | .moved _ _ => "moved"
            | .changed _ => "changed").eraseDups
          vcls := vcls ++ ((if kinds.isEmpty then ["none"] else kinds).map fun k => s!"{howTok how} {k}")
          vf := vf ++ s!"turn {line}{extra}\n  -> how {howTok how} | {tableTok after} | keys {keysTok (s'.view.seq.map (·.2))} | drawn {keysTok s'.drawn} | {" ".intercalate (changes.map changeTok)}\n"
          site := s'
    cell := after
    if t.keep then
      saved := saved ++ [cell]
      tc := tc ++ "keep\n"
      vf := vf ++ "keep\n"
  return some (tc, tcls, vf, vcls)

def writeVectors (changesOut viewOut : String) : IO UInt32 := do
  let mut tseen : List String := []
  let mut vseen : List String := []
  let mut tout := "# fuzz/table-changes vectors: written by oracle/tables (`lake exe vectors write`); do not edit.\n# Grammar: oracle/README.md.\n"
  let mut vout := "# fuzz/view-follow vectors: written by oracle/tables (`lake exe vectors write`); do not edit.\n# Grammar: oracle/README.md.\n"
  let mut nt := 0
  let mut nv' := 0
  for seed in [0:20000] do
    match replay changesTarget (randHistory changesTarget seed) with
    | none => pure ()
    | some (tc, tcls, _, _) =>
        let tnew := tcls.eraseDups.filter (!tseen.contains ·)
        if !tnew.isEmpty then
          tseen := tseen ++ tnew
          tout := tout ++ s!"vector {seed}\ncovers {", ".intercalate tnew}\n{tc}end\n"
          nt := nt + 1
    match replay followTarget (randHistory followTarget seed) with
    | none => pure ()
    | some (_, _, vf, vcls) =>
        let vnew := vcls.eraseDups.filter (!vseen.contains ·)
        if !vnew.isEmpty then
          vseen := vseen ++ vnew
          vout := vout ++ s!"vector {seed}\ncovers {", ".intercalate vnew}\n{vf}end\n"
          nv' := nv' + 1
  IO.FS.writeFile changesOut tout
  IO.FS.writeFile viewOut vout
  IO.println s!"wrote {nt} vectors covering {tseen.length} classes to {changesOut}"
  IO.println s!"wrote {nv'} vectors covering {vseen.length} classes to {viewOut}"
  let hows := ["unchanged", "absorbed", "rebuilt-rewritten"]
  let missing := hows.filter fun h => !(vseen.any (·.startsWith (h ++ " ")))
  if !missing.isEmpty then
    IO.eprintln s!"no vector for: {", ".intercalate missing}"
    return 1
  return 0

def main (args : List String) : IO UInt32 := do
  match args with
  | ["write", a, b] => writeVectors a b
  | _ => IO.eprintln "usage: vectors write <table-changes/vectors.txt> <view-follow/vectors.txt>"; return 2
