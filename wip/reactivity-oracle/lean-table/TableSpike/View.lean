/-
A transliteration of `platform/View.roc` (445 lines) and of the table view
site's `Changed` in `platform/Core.roc:7915-7962`.

Abstractions:
* `Seq` (`platform/Seq.roc`): the chunked sequence is a flat sorted list.
  `insert`, `remove` and `slice` keep their contract (lower bound, crash on a
  tie, crash on a missing entry); chunk splitting and merging is not modelled.
* a query is a number; `plan` turns it into `keep`, `sort`, `compare`.
* a crash is `Except.error`.
-/
import TableSpike.Table
namespace TableSpike

structure Window where
  start : Nat
  count : Nat
  deriving DecidableEq, Repr, Hashable

abbrev S := Nat × Nat
abbrev Entry := S × K
abbrev Seq := List Entry

structure Plan where
  keep : K → V → Bool
  sort : K → V → S
  compare : S → S → Ordering

def lex (a b : S) : Ordering := (compare a.1 b.1).then (compare a.2 b.2)

/-- The queries of the spike. 0-2 are total orders (key breaks ties); 3 ties. -/
def plan : Nat → Plan
  | 0 => { keep := fun _ _ => true, sort := fun k v => (v, k), compare := lex }
  | 1 => { keep := fun _ v => v ≥ 1, sort := fun k v => (v, k), compare := lex }
  | 2 => { keep := fun _ _ => true, sort := fun k _ => (0, k), compare := fun a b => lex b a }
  | _ => { keep := fun _ _ => true, sort := fun _ v => (v, 0), compare := lex }

/-- Seq.roc:229-246 over a flat list. -/
def lowerBound (cmp : S → S → Ordering) (seq : Seq) (s : S) : Nat :=
  (seq.takeWhile fun e => cmp e.1 s == .lt).length

/-- Seq.roc:53-96 (flat). -/
def seqInsert (cmp : S → S → Ordering) (seq : Seq) (e : Entry) : Except String Seq :=
  let i := lowerBound cmp seq e.1
  match seq[i]? with
  | some there =>
    if cmp there.1 e.1 == .eq then
      .error "contract: two rows of a table view compare Same"
    else .ok (seq.take i ++ [e] ++ seq.drop i)
  | none => .ok (seq ++ [e])

/-- Seq.roc:101-135 (flat). -/
def seqRemove (cmp : S → S → Ordering) (seq : Seq) (s : S) : Except String Seq :=
  let i := lowerBound cmp seq s
  match seq[i]? with
  | some there =>
    if cmp there.1 s == .eq then .ok (seq.eraseIdx i)
    else .error "Seq.remove: no entry has this sort value"
  | none => .error "Seq.remove: no entry has this sort value"

/-- Seq.roc:141-163 (flat). -/
def seqSlice (seq : Seq) (w : Window) : List Entry := (seq.drop w.start).take w.count

/-- View.roc:208-229. -/
def scratch (p : Plan) (t : Table) : Except String Seq := do
  let kept := t.rows.filterMap fun (k, v) => if p.keep k v then some (p.sort k v, k) else none
  let sorted := kept.mergeSort fun a b => p.compare a.1 b.1 != .gt
  for (a, b) in sorted.zip (sorted.drop 1) do
    if p.compare a.1 b.1 == .eq then
      throw "contract: two rows of a table view compare Same"
  return sorted

/-- View.roc:28-35. `site` is dropped; `q` stands for the plan's functions. -/
structure View where
  q : Nat
  seq : Seq
  window : Window
  shown : List Entry
  version : Nat
  deriving DecidableEq, Repr, Hashable

/-- View.roc:41-45. -/
def View.build (t : Table) (q : Nat) (window : Window) : Except String View := do
  let seq ← scratch (plan q) t
  return { q, seq, window, shown := seqSlice seq window, version := t.version }

inductive How where
  | unchanged | absorbed | rebuiltMany | rebuiltRewritten | rebuiltBehind
  deriving DecidableEq, Repr

inductive Wrote where
  | noRow | rows (r : Rec) | everyRow
  deriving DecidableEq, Repr

structure Followed where
  view : View
  how : How
  placed : Nat
  reached : Bool
  touched : List K
  wrote : Wrote

/-- View.roc:233-237. -/
def resorted (view : View) (t : Table) : Except String View := do
  let seq ← scratch (plan view.q) t
  return { view with seq, version := t.version }

/-- View.roc:239-292. -/
def absorb (bug : Bug) (view : View) (t : Table) (record : Rec) :
    Except String (View × Bool × List K × Nat) := do
  let p := plan view.q
  let full := view.shown.length ≥ view.window.count
  let first := view.shown.head?
  let last := view.shown.getLast?
  let reachesWindow (s : S) : Bool :=
    if bug = .noReach then false
    else if full then
      match last with
      | some boundary => p.compare s boundary.1 != .gt
      | none => true
    else true
  let inWindow (s : S) : Bool :=
    match first, last with
    | some low, some high => p.compare low.1 s != .gt && p.compare s high.1 != .gt
    | _, _ => false
  let placed (k : K) (row : V) : Option S := if p.keep k row then some (p.sort k row) else none
  let mut seq := view.seq
  let mut moved := false
  let mut touched : List K := []
  let mut count := 0
  for (key, before) in record do
    let (old, was) := match before with
      | .was row => (placed key row, 1)
      | .absent => (none, 0)
    let (new, is) := match rget t.rows key with
      | some row => (placed key row, 1)
      | none => (none, 0)
    count := count + was + is
    match old, new with
    | some a, some b =>
      if p.compare a b == .eq then
        if inWindow b then touched := touched ++ [key]
      else
        seq ← seqRemove p.compare seq a
        seq ← seqInsert p.compare seq (b, key)
        moved := moved || reachesWindow a || reachesWindow b
    | some a, none =>
      seq ← seqRemove p.compare seq a
      moved := moved || reachesWindow a
    | none, some b =>
      seq ← seqInsert p.compare seq (b, key)
      moved := moved || reachesWindow b
    | none, none => pure ()
  return ({ view with seq, version := t.version }, moved, if moved then [] else touched, count)

/-- `rebuild_ratio`, `rebuild_floor` (View.roc:187-191), as parameters so
that a small table can reach `Many`. -/
structure Cfg where
  ratio : Nat := 8
  floor : Nat := 64

/-- View.roc:72-90. -/
def follow (bug : Bug) (cfg : Cfg) (view : View) (t : Table) : Except String Followed := do
  if view.version == t.version then
    return { view, how := .unchanged, placed := 0, reached := false, touched := [], wrote := .noRow }
  else if view.version != t.start then
    return { view := ← resorted view t, how := .rebuiltBehind, placed := t.rows.length,
             reached := true, touched := [], wrote := .everyRow }
  else
    match t.whole with
    | .rewritten =>
      return { view := ← resorted view t, how := .rebuiltRewritten, placed := t.rows.length,
               reached := true, touched := [], wrote := .everyRow }
    | .keyed =>
      if t.record.length * cfg.ratio > t.rows.length + cfg.floor then
        return { view := ← resorted view t, how := .rebuiltMany, placed := t.rows.length,
                 reached := true, touched := [], wrote := .rows t.record }
      else
        let (v, reached, touched, placed) ← absorb bug view t t.record
        return { view := v, how := .absorbed, placed, reached, touched, wrote := .rows t.record }

inductive Change where
  | left (k : K)
  | entered (k : K) (before : Option K)   -- `none` is `End`
  | moved (k : K) (before : Option K)
  | changed (k : K)
  deriving DecidableEq, Repr

/-- View.roc:343-377: the indices of a longest strictly increasing subsequence. -/
def longestRun (values : Array Nat) : List Nat := Id.run do
  let none := values.size   -- stands for `U64.highest`
  let mut tails : Array Nat := #[]
  let mut previous : Array Nat := Array.replicate values.size none
  for i in [0:values.size] do
    let value := values[i]!
    let mut lo := 0
    let mut hi := tails.size
    for _ in [0:values.size + 1] do
      if lo < hi then
        let mid := lo + (hi - lo) / 2
        let tail := values[tails[mid]!]!
        if tail < value then lo := mid + 1 else hi := mid
    if lo > 0 then previous := previous.set! i tails[lo - 1]!
    tails := if lo == tails.size then tails.push i else tails.set! lo i
  let mut out : List Nat := []
  let mut cur := tails.back?.getD none
  for _ in [0:values.size + 1] do
    if cur != none then
      out := cur :: out
      cur := previous[cur]!
  return out

/-- View.roc:301-340. -/
def windowChanges (old new : List K) (isChanged : K → Bool) : List Change := Id.run do
  let newAt (key : K) : Option Nat := new.idxOf? key
  let lefts := (old.filter fun key => (newAt key).isNone).map Change.left
  let retained := old.filter fun key => (newAt key).isSome
  let positions := retained.map fun key => (newAt key).getD 0
  let staying := (longestRun positions.toArray).map fun i => retained[i]!
  let mut anchors : Array (Option K) := #[]
  let mut anchor : Option K := none
  for key in new.reverse do
    anchors := anchors.push anchor
    if staying.contains key then anchor := some key
  let mut placed : List Change := []
  let mut j := 0
  for key in new do
    let before := anchors[new.length - 1 - j]!
    if !old.contains key then placed := placed ++ [.entered key before]
    else if !staying.contains key then placed := placed ++ [.moved key before]
    j := j + 1
  let changed := (new.filter fun key => old.contains key && isChanged key).map Change.changed
  return lefts ++ placed ++ changed

/-- View.roc:193-205. -/
def place (keys : List K) (key : K) (before : Option K) : Except String (List K) :=
  match before with
  | none => .ok (keys ++ [key])
  | some anchor =>
    match keys.idxOf? anchor with
    | some i => .ok (keys.take i ++ [key] ++ keys.drop i)
    | none => .error "View.place: the anchor row is not in the window"

/-- View.roc:169-179. -/
def applyChanges (start : List K) (changes : List Change) : Except String (List K) :=
  changes.foldlM (fun current change => match change with
    | .left key => pure (current.filter (· != key))
    | .entered key before => place current key before
    | .moved key before => place (current.filter (· != key)) key before
    | .changed _ => pure current) start

/-- View.roc:106-122. `query` is `none` for `Same`, `some q` for `New`. -/
def draw (view : View) (t : Table) (query : Option Nat) (window : Window) (wrote : Wrote) :
    Except String (View × List Change) := do
  if view.version != t.version then
    throw "View.draw: follow the table before drawing the view"
  let (q, seq) ← match query with
    | none => pure (view.q, view.seq)
    | some next => do pure (next, ← scratch (plan next) t)
  let nextShown := seqSlice seq window
  let oldKeys := view.shown.map (·.2)
  let newKeys := nextShown.map (·.2)
  let changes := match wrote with
    | .noRow => windowChanges oldKeys newKeys fun _ => false
    | .rows record => windowChanges oldKeys newKeys fun key => (cget record key).isSome
    | .everyRow => windowChanges oldKeys newKeys fun _ => true
  return ({ view with q, seq, window, shown := nextShown }, changes)

/-- What a table view site holds: the query it last read, its view, and the
keys of its drawn rows in order (`cols.order` in Core.roc). -/
structure Site where
  q : Nat
  view : View
  drawn : List K
  deriving DecidableEq, Repr, Hashable

def Site.mount (t : Table) (q : Nat) (w : Window) : Except String Site := do
  let view ← View.build t q w
  return { q, view, drawn := view.shown.map (·.2) }

/-- Core.roc:7915-7962: one `Changed` at a table view site. `askQ`/`askW` are
`some` when the pass names the query / the window (its value as read now). -/
def Site.changed (bug : Bug) (cfg : Cfg) (site : Site) (t : Table)
    (askQ : Option Nat) (askW : Option Window) :
    Except String (Site × List Change × How × Nat) := do
  let window := site.view.window
  let f ← follow bug cfg site.view t
  let q2 := askQ.getD site.q
  let w2 := askW.getD window
  let draws := f.reached || (askQ.isSome && q2 != site.q) || (askW.isSome && w2 != window)
  let (v2, changes) ←
    if !draws then pure (f.view, f.touched.map Change.changed)
    else if bug = .twoDraws && f.reached && w2 != window then do
      -- seeded: one draw for the table, a second for the window
      let (va, ca) ← draw f.view t (if q2 == site.q then none else some q2) window f.wrote
      let (vb, cb) ← draw va t none w2 .noRow
      pure (vb, ca ++ cb)
    else if q2 == site.q then draw f.view t none w2 f.wrote
    else draw f.view t (some q2) w2 f.wrote
  let drawn ← applyChanges site.drawn changes
  return ({ q := q2, view := v2, drawn }, changes, f.how, f.placed)

end TableSpike
