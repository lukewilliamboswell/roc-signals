/-
The vector format of `fuzz/structure`: a generated tree, its clicks and the
page after each, as the reference gives them; and a checker of a trace
against the reference alone. `oracle/README.md` states the grammar.

  trace <name>
  variant <algorithm> <observation> <step>   only in vectors-bad: the
                                             known-bad algorithm that
                                             observed this trace, and the
                                             first observation the
                                             reference rejects
  prog <node> ...                            the tree, in the Roc `Node`
                                             tag names
  page <leaf> ...                            the page at mount
  step <k> | <leaf> ... | <n>                click the k-th live button in
                                             document order; the page after
                                             it; the evaluations the turn
                                             makes, or - for none recorded
  end

A leaf is a text's integer, a `Pair` text as `x~d~y`, or a button as one
`+` per write its click makes.

Trusted for: the format, and what replaying a trace against the reference
answers. It holds no semantics of its own.
-/
import Turns.Expect
import Turns.Structure
namespace Turns

open Structure

def Leaf.tok : Leaf → String
  | .text v => toString v
  | .texts vs => "~".intercalate (vs.map toString)
  | .button n => String.ofList (List.replicate (max n 1) '+')

def leavesTok (ls : List Leaf) : String := " ".intercalate (ls.map Leaf.tok)

def parseLeaf (t : String) : Option Leaf :=
  if t ≠ "" && t.all (· = '+') then some (.button t.length)
  else if t.contains '~' then ((t.splitOn "~").mapM String.toInt?).map .texts
  else t.toInt?.map .text

def parseLeaves (s : String) : Option (List Leaf) := (words s).mapM parseLeaf

structure TStep where
  button : Nat
  page : List Leaf
  evals : Option Nat

/-- What a known-bad algorithm's trace is rejected by: the page, the
evaluation count, or a click on a button the reference does not draw. -/
inductive Observation where
  | page | count | button
  deriving DecidableEq, Repr

def Observation.name : Observation → String
  | .page => "page" | .count => "count" | .button => "button"

def Observation.parse : String → Option Observation
  | "page" => some .page | "count" => some .count | "button" => some .button
  | _ => none

structure Trace where
  name : String
  variant : Option (String × Observation × Nat) := none
  tree : List RNode
  page0 : List Leaf
  steps : List TStep

def Trace.prog (t : Trace) : Prog := toKernel t.tree

def Trace.text (t : Trace) : String :=
  s!"trace {t.name}\n"
    ++ (match t.variant with
        | some (v, o, n) => s!"variant {v} {o.name} {n}\n"
        | none => "")
    ++ s!"prog {treeSx t.tree}\npage {leavesTok t.page0}\n"
    ++ String.join (t.steps.map fun s =>
        s!"step {s.button} | {leavesTok s.page} | {match s.evals with | some n => toString n | none => "-"}\n")
    ++ "end\n"

/-- The traces of a file, or the line that does not parse. A line that
starts with `#` is a comment. -/
def parseTraces (text : String) : Except String (Array Trace) := do
  let mut out := #[]
  let mut cur : Trace := { name := "", tree := [], page0 := [], steps := [] }
  let mut steps : Array TStep := #[]
  let mut n := 0
  for line in text.splitOn "\n" do
    n := n + 1
    let bad : Except String Unit := throw s!"line {n}: {line}"
    if line.startsWith "#" then continue
    match line.splitOn " " with
    | ["end"] =>
        out := out.push { cur with steps := steps.toList }
        cur := { name := "", tree := [], page0 := [], steps := [] }
        steps := #[]
    | "trace" :: rest => cur := { cur with name := " ".intercalate rest }
    | ["variant", v, o, k] =>
        match Observation.parse o, k.toNat? with
        | some o, some k => cur := { cur with variant := some (v, o, k) }
        | _, _ => bad
    | "prog" :: rest =>
        match parseTree (" ".intercalate rest) with
        | some tree => cur := { cur with tree }
        | none => bad
    | "page" :: rest =>
        match parseLeaves (" ".intercalate rest) with
        | some ls => cur := { cur with page0 := ls }
        | none => bad
    | "step" :: rest =>
        match (" ".intercalate rest).splitOn "|" with
        | [k, page, evals] =>
            match (words k).head?.bind String.toNat?, parseLeaves page with
            | some k, some ls =>
                steps := steps.push { button := k, page := ls, evals := (words evals).head?.bind String.toNat? }
            | _, _ => bad
        | _ => bad
    | [""] => pure ()
    | _ => bad
  return out

/-- The first observation of a trace the reference rejects, or `ok`. -/
inductive Verdict where
  | ok
  | page (step : Nat) (expected : List Leaf)    -- the first step whose page differs (0 is the mount)
  | evals (step : Nat) (expected : Nat)         -- the pages agree; the first evaluation count that differs
  | noButton (step : Nat)                       -- the trace clicks a button the reference does not draw

def Verdict.observation : Verdict → Option (Observation × Nat)
  | .ok => none
  | .page n _ => some (.page, n)
  | .evals n _ => some (.count, n)
  | .noButton n => some (.button, n)

def leavesOf (p : Prog) (w : World) : List Leaf := (pageOf (view p w)).map (·.2)

/-- The turn's due evaluations, by the second specification, with exact
signatures (the engine's signature words are exact at the generator's
depths). -/
def dueCount (p : Prog) (w0 w1 : World) (ws : List (Target × Val)) : Nat :=
  ((expect Alpha.exact p w0 w1 ws).readers.filter (·.due)).length

/-- Replay a trace against the reference. A page that differs ends the
replay; an evaluation count that differs is kept while the pages go on
agreeing. -/
def checkTrace (t : Trace) : Verdict := Id.run do
  let p := t.prog
  let mut w := World.init p
  if leavesOf p w != t.page0 then return .page 0 (leavesOf p w)
  let mut n := 0
  let mut verdict := Verdict.ok
  for s in t.steps do
    n := n + 1
    let v := view p w
    let some ev := (buttonsOf v)[s.button]? | return .noButton n
    let ws := match v.lookup ev with
      | some (.button ws) => ws
      | _ => []
    let some w1 := stepRef p w ev | return .noButton n
    let page := leavesOf p w1
    if page != s.page then return .page n page
    if let (.ok, some observed) := (verdict, s.evals) then
      let due := dueCount p w w1 ws
      if due != observed then verdict := .evals n due
    w := w1
  return verdict

/-- A vector: the trace the reference alone writes for a tree and a list
of click choices, each taken modulo the live buttons, as the structure
target's valued session takes its event bytes. -/
def refTrace (tree : List RNode) (name : String) (clicks : List Nat) : Trace := Id.run do
  let p := toKernel tree
  let mut w := World.init p
  let mut steps := #[]
  for r in clicks do
    let v := view p w
    let buttons := buttonsOf v
    if buttons.isEmpty then break
    let k := r % buttons.length
    let ev := buttons.getD k []
    let ws := match v.lookup ev with
      | some (.button ws) => ws
      | _ => []
    let some w1 := stepRef p w ev | break
    steps := steps.push { button := k, page := leavesOf p w1, evals := some (dueCount p w w1 ws) }
    w := w1
  return { name, tree, page0 := leavesOf p (World.init p), steps := steps.toList }

end Turns
