/-
The kernel: a first-order AST of programs, with the app code (expressions,
handlers) first-order too, so a program is data. Trusted for: what a
program is and what its expressions read and evaluate to. Every model in
this project (the reference, the second specification, the incremental
algorithms, the proof) is written over it. The Roc generator's programs
reach it through `Turns.Structure`, which is the only place that knows the
Roc `Node` type.
-/
namespace Turns

/-- One untyped value universe. -/
abbrev Val := Int

/-- What a reader can read: a layer, named by its index on the path from the
root (a `state`, a `derive` and a row each add one), or a store cell. -/
inductive Ref where
  | layer (i : Nat)
  | cell (c : Nat)
  deriving DecidableEq, Repr, Inhabited

inductive Expr where
  | lit (n : Val)
  | rd (r : Ref)
  | add (a b : Expr)
  | mul (a b : Expr)
  | mod (a b : Expr)
  | eq (a b : Expr)
  deriving DecidableEq, Repr, Inhabited

/-- Evaluation over any environment `get`. -/
def Expr.eval (get : Ref → Val) : Expr → Val
  | .lit n => n
  | .rd r => get r
  | .add a b => a.eval get + b.eval get
  | .mul a b => a.eval get * b.eval get
  | .mod a b => a.eval get % b.eval get
  | .eq a b => if a.eval get = b.eval get then 1 else 0

/-- The exact read signature of an expression. -/
def Expr.reads : Expr → List Ref
  | .lit _ => []
  | .rd r => [r]
  | .add a b => a.reads ++ b.reads
  | .mul a b => a.reads ++ b.reads
  | .mod a b => a.reads ++ b.reads
  | .eq a b => a.reads ++ b.reads

/-- A handler: writes applied as one event, in order. -/
abbrev Handler := List (Ref × Expr)

/-- A site. `show` is a text hole; `joined` is one text hole showing several
values together (the Roc generator's `Pair` text); `bump` a button;
`state`, `derive` and each row of `each` add a layer for their body; `when`
and `switch` select a branch. `Turns.Structure` says which Roc `Node`
becomes which. -/
inductive Node where
  | show (e : Expr)
  | joined (es : List Expr)
  | bump (h : Handler)
  | state (init : Val) (body : List Node)
  | derive (e : Expr) (body : List Node)
  | when (sel : Expr) (yes no : List Node)
  | switch (sel : Expr) (a b c : List Node)
  | each (src : Expr) (body : List Node)

instance : Inhabited Node := ⟨.show (.lit 0)⟩

structure Prog where
  cells : List Val
  body : List Node

/-- The keys an `each` draws for a value: the Roc generator's permutation. -/
def keysOf (v : Val) : List Val :=
  let x := v.toNat
  ((List.range (x % 5)).map fun j => (((j * (x + 3) + x) % 7 : Nat) : Int)).eraseDups

/-- An environment: the cells and the layers on the path, outermost first. -/
structure Env where
  cells : List Val
  layers : List Val
  deriving DecidableEq, Repr, Inhabited

def Env.get (e : Env) : Ref → Val
  | .layer i => e.layers.getD i 0
  | .cell c => e.cells.getD c 0

def Env.push (e : Env) (v : Val) : Env := { e with layers := e.layers ++ [v] }
def Env.depth (e : Env) : Nat := e.layers.length

/-- The writes a handler makes where its button is drawn, in order, with the
value each stores. Writes compose (design decision D4, as handlers composed
with `also` compose): each right-hand side reads the environment with the
event's earlier writes applied to what they wrote. Nothing else follows
them within the event: a `derive` or a row read by a later right-hand side
holds its value from before the event. A write to a layer that is not
writable (a `derive` or a row) or to a cell the store does not have is no
write. -/
def Handler.writes (h : Handler) (env : Env) (writable : Nat → Bool) : List (Ref × Val) :=
  (h.foldl (fun (acc : Env × List (Ref × Val)) (r, e) =>
    let (now, out) := acc
    let v := e.eval now.get
    match r with
    | .cell c =>
        if c < now.cells.length then ({ now with cells := now.cells.set c v }, out ++ [(r, v)]) else acc
    | .layer i =>
        if writable i then ({ now with layers := now.layers.set i v }, out ++ [(r, v)]) else acc)
    (env, [])).2

/-- Structural identity: child positions through blocks (`c`), the branch
taken (`b`) and the row's key (`r`). -/
inductive Step where
  | c (i : Nat)
  | b (k : Nat)
  | r (k : Val)
  deriving DecidableEq, Repr, Inhabited

abbrev Ident := List Step

/-- What a write names once the button is placed: a state site or a cell. -/
inductive Target where
  | state (id : Ident)
  | cell (c : Nat)
  deriving DecidableEq, Repr, Inhabited

/-! ### Signatures, exact and abstracted -/

abbrev Mask := Nat

/-- A signature abstraction: layer `i` is bit `i mod lm`, cell `c` is bit
`c mod cm`, in two separate words (`0` means exact, no wrapping). The engine
is `⟨64, 64⟩`. It may alias and never drops a read. -/
structure Alpha where
  lm : Nat
  cm : Nat
  deriving DecidableEq, Repr, Inhabited

def Alpha.exact : Alpha := ⟨0, 0⟩

def Alpha.bit (α : Alpha) : Ref → Nat
  | .layer i => 2 * (if α.lm = 0 then i else i % α.lm)
  | .cell c => 2 * (if α.cm = 0 then c else c % α.cm) + 1

def Alpha.mask (α : Alpha) (r : Ref) : Mask := 1 <<< α.bit r
def Alpha.sig (α : Alpha) (rs : List Ref) : Mask := rs.foldl (fun m r => m ||| α.mask r) 0
def hit (a b : Mask) : Bool := a &&& b != 0

-- The static reads of a site, unmounted branches included.
mutual
def readsNode : Node → List Ref
  | .show e => e.reads
  | .joined es => es.flatMap Expr.reads
  | .bump _ => []
  | .state _ body => readsBlock body
  | .derive e body => e.reads ++ readsBlock body
  | .when sel yes no => sel.reads ++ readsBlock yes ++ readsBlock no
  | .switch sel a b c => sel.reads ++ readsBlock a ++ readsBlock b ++ readsBlock c
  | .each src body => src.reads ++ readsBlock body
def readsBlock : List Node → List Ref
  | [] => []
  | n :: ns => readsNode n ++ readsBlock ns
end

end Turns
