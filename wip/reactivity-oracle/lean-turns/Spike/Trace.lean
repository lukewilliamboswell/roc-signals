/-
The bridge: a line-oriented text format for a program, its events and the
pages observed after each, and a checker of an observed trace against the
reference semantics alone.

  trace <name>
  alpha <lm> <cm>                 signature abstraction, for the evaluation count
  cells <v> ...                   the store at mount
  prog <node> ...                 the program, as s-expressions
  page <leaf> ...                 the page at mount: a text's integer, or B for a button
  step <k> | <leaf> ... | <n>     click the k-th live button in document order; the page
                                  observed after it; evaluations counted, or - for none
  end
-/
import Spike.Expect
namespace Spike

def Ref.sx : Ref → String
  | .layer i => s!"(L {i})"
  | .cell c => s!"(C {c})"

def Expr.sx : Expr → String
  | .lit n => toString n
  | .rd r => r.sx
  | .add a b => s!"(+ {a.sx} {b.sx})"
  | .mul a b => s!"(* {a.sx} {b.sx})"
  | .mod a b => s!"(% {a.sx} {b.sx})"
  | .eq a b => s!"(= {a.sx} {b.sx})"

mutual
partial def Node.sx : Node → String
  | .show e => s!"(show {e.sx})"
  | .bump h => "(bump" ++ String.join (h.map fun (r, e) => s!" ({r.sx} {e.sx})") ++ ")"
  | .state init body => s!"(state {init}{blockSx body})"
  | .derive e body => s!"(derive {e.sx}{blockSx body})"
  | .when sel yes no => s!"(when {sel.sx} ({listSx yes}) ({listSx no}))"
  | .switch sel a b c => s!"(switch {sel.sx} ({listSx a}) ({listSx b}) ({listSx c}))"
  | .each src body => s!"(each {src.sx}{blockSx body})"
partial def blockSx (ns : List Node) : String := String.join (ns.map fun n => " " ++ n.sx)
partial def listSx (ns : List Node) : String := " ".intercalate (ns.map Node.sx)
end

inductive Sx where
  | atom (s : String)
  | list (xs : List Sx)

instance : Inhabited Sx := ⟨.atom ""⟩

def words (s : String) : List String := (s.splitOn " ").filter (· ≠ "")

def tokens (s : String) : List String := words ((s.replace "(" " ( ").replace ")" " ) ")

mutual
partial def parseSx : List String → Option (Sx × List String)
  | "(" :: ts => parseSxs ts []
  | ")" :: _ => none
  | t :: ts => some (.atom t, ts)
  | [] => none
partial def parseSxs : List String → List Sx → Option (Sx × List String)
  | ")" :: ts, acc => some (.list acc.reverse, ts)
  | ts, acc =>
      match parseSx ts with
      | some (x, ts') => parseSxs ts' (x :: acc)
      | none => none
end

def toRef : Sx → Option Ref
  | .list [.atom "L", .atom i] => i.toNat?.map .layer
  | .list [.atom "C", .atom i] => i.toNat?.map .cell
  | _ => none

partial def toExpr : Sx → Option Expr
  | .atom s => s.toInt?.map .lit
  | .list [.atom "+", a, b] => do pure (.add (← toExpr a) (← toExpr b))
  | .list [.atom "*", a, b] => do pure (.mul (← toExpr a) (← toExpr b))
  | .list [.atom "%", a, b] => do pure (.mod (← toExpr a) (← toExpr b))
  | .list [.atom "=", a, b] => do pure (.eq (← toExpr a) (← toExpr b))
  | x => (toRef x).map .rd

partial def toNode : Sx → Option Node
  | .list [.atom "show", e] => do pure (.show (← toExpr e))
  | .list (.atom "bump" :: ws) => do
      pure (.bump (← ws.mapM fun
        | .list [r, e] => do pure (← toRef r, ← toExpr e)
        | _ => none))
  | .list (.atom "state" :: .atom i :: body) => do pure (.state (← i.toInt?) (← body.mapM toNode))
  | .list (.atom "derive" :: e :: body) => do pure (.derive (← toExpr e) (← body.mapM toNode))
  | .list [.atom "when", e, .list yes, .list no] => do
      pure (.when (← toExpr e) (← yes.mapM toNode) (← no.mapM toNode))
  | .list [.atom "switch", e, .list a, .list b, .list c] => do
      pure (.switch (← toExpr e) (← a.mapM toNode) (← b.mapM toNode) (← c.mapM toNode))
  | .list (.atom "each" :: e :: body) => do pure (.each (← toExpr e) (← body.mapM toNode))
  | _ => none

def parseBody (s : String) : Option (List Node) :=
  match parseSx (tokens ("(" ++ s ++ ")")) with
  | some (.list xs, []) => xs.mapM toNode
  | _ => none

def Leaf.tok : Leaf → String
  | .text v => toString v
  | .button => "B"

def leavesTok (ls : List Leaf) : String := " ".intercalate (ls.map Leaf.tok)

def parseLeaves (s : String) : Option (List Leaf) :=
  (words s).mapM fun t => if t = "B" then some .button else t.toInt?.map .text

structure TStep where
  button : Nat
  page : List Leaf
  evals : Option Nat

structure Trace where
  name : String
  α : Alpha
  prog : Prog
  page0 : List Leaf
  steps : List TStep

def Trace.text (t : Trace) : String :=
  s!"trace {t.name}\nalpha {t.α.lm} {t.α.cm}\ncells {" ".intercalate (t.prog.cells.map toString)}\n"
    ++ s!"prog{blockSx t.prog.body}\npage {leavesTok t.page0}\n"
    ++ String.join (t.steps.map fun s =>
        s!"step {s.button} | {leavesTok s.page} | {match s.evals with | some n => toString n | none => "-"}\n")
    ++ "end\n"

/-- The traces of a file, or the line that does not parse. -/
def parseTraces (text : String) : Except String (Array Trace) := do
  let mut out := #[]
  let mut cur : Trace := { name := "", α := Alpha.exact, prog := ⟨[], []⟩, page0 := [], steps := [] }
  let mut steps : Array TStep := #[]
  let mut n := 0
  for line in text.splitOn "\n" do
    n := n + 1
    let bad : Except String Unit := throw s!"line {n}: {line}"
    match line.splitOn " " with
    | ["end"] =>
        out := out.push { cur with steps := steps.toList }
        steps := #[]
    | "trace" :: rest => cur := { cur with name := " ".intercalate rest }
    | ["alpha", a, b] =>
        match a.toNat?, b.toNat? with
        | some a, some b => cur := { cur with α := ⟨a, b⟩ }
        | _, _ => bad
    | "cells" :: vs =>
        match (vs.filter (· ≠ "")).mapM String.toInt? with
        | some vs => cur := { cur with prog := { cur.prog with cells := vs } }
        | none => bad
    | "prog" :: rest =>
        match parseBody (" ".intercalate rest) with
        | some body => cur := { cur with prog := { cur.prog with body } }
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

inductive Verdict where
  | ok
  | page (step : Nat) (expected : List Leaf)    -- the first step whose page differs (0 is the mount)
  | evals (step : Nat) (expected : Nat)         -- the pages agree; the first evaluation count that differs
  | noButton (step : Nat)                       -- the trace clicks a button the reference does not draw

def leavesOf (p : Prog) (w : World) : List Leaf := (pageOf (view p w)).map (·.2)

/-- Replay a trace against the reference. Answers the verdict and the steps
replayed. A page that differs ends the replay; an evaluation count that
differs is kept while the pages go on agreeing. -/
def checkTrace (t : Trace) : Verdict × Nat := Id.run do
  let mut w := World.init t.prog
  if leavesOf t.prog w != t.page0 then return (.page 0 (leavesOf t.prog w), 0)
  let mut n := 0
  let mut verdict := Verdict.ok
  for s in t.steps do
    n := n + 1
    let v := view t.prog w
    let some ev := (buttonsOf v)[s.button]? | return (.noButton n, n)
    let ws := match v.lookup ev with
      | some (.button ws) => ws
      | _ => []
    let some w1 := stepRef t.prog w ev | return (.noButton n, n)
    let page := leavesOf t.prog w1
    if page != s.page then return (.page n page, n)
    if let (.ok, some observed) := (verdict, s.evals) then
      let due := ((expect t.α t.prog w w1 ws).readers.filter (·.due)).length
      if due != observed then verdict := .evals n due
    w := w1
  return (verdict, n)

/-- A test vector: the trace the reference alone writes for a program and a
list of clicks (each taken modulo the live buttons). -/
def refTrace (α : Alpha) (p : Prog) (name : String) (clicks : List Nat) : Trace := Id.run do
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
    let due := ((expect α p w w1 ws).readers.filter (·.due)).length
    steps := steps.push { button := k, page := leavesOf p w1, evals := some due }
    w := w1
  return { name, α, prog := p, page0 := leavesOf p (World.init p), steps := steps.toList }

end Spike
