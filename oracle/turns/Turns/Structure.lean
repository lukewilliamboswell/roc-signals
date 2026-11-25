/-
The Roc generator's programs, and what each means in the kernel.

`RNode` is `Reference.Node` of `fuzz/structure/Reference.roc`, and `decode`
is the byte decoder of `fuzz/structure/FuzzStructureProperty.roc` with its
biased `two_writes` shape, as the valued modes build them: every state is
written by clicks, starts at 0, and nothing is awaited (a `resource` issues
nothing, so its layer is its `pending` value, its input plus 7). The Roc
type is the authority for what can be generated; `toKernel` says what a
generated tree means, and the reference (`Turns.Spec`) gives the page.

Trusted for: the shape of the Roc generator's trees (`RNode`, `Sel`,
`decode`), its index rule (`place`), its selectors (`Scope.chosen`), its
rows (the kernel's `rowsOf`, which is `Reference.rows_of`), its derived
layers (`derived`) and its typed levels (`Level.below`). When that
generator changes, this file changes with it and the vectors are written
again.

What the translation leaves out, because the valued page does not show it:
`Guard`, `Control` and `Watch` draw no text and become nothing, so they are
neither on the page nor counted as evaluations; the wrapper elements of
every block and the generator's document key handlers, which draw no text,
are not modelled.
-/
import Turns.Text
namespace Turns.Structure

open Turns

/-- `Reference.Sel`: what a `when`, a `switch` or an `each` follows, one
value or the sum of two. -/
inductive Sel where
  | one (i : Nat)
  | two (i j : Nat)
  deriving Repr, BEq, Inhabited

/-- `Reference.Node`. -/
inductive RNode where
  | show (i : Nat)
  | guard (i : Nat)
  | control (i : Nat)
  | bump (i : Nat)
  | bump2 (i j : Nat)
  | pair (i j : Nat)
  | when (sel : Sel) (yes no : List RNode)
  | switch (sel : Sel) (a b c : List RNode)
  | layer (kind i : Nat) (body : List RNode)
  | each (sel : Sel) (body : List RNode)
  | watch (k i : Nat)
  deriving Repr, BEq, Inhabited

/-! ### The byte decoder (`nodes`, `node`, `selector`, `two_writes`, `decode`) -/

structure Reader where
  bytes : Array Nat
  pos : Nat
  left : Nat

def Reader.next (d : Reader) : Nat × Reader := (d.bytes.getD d.pos 0, { d with pos := d.pos + 1 })

/-- `selector`: two values when the tens digit of the node byte is odd. -/
def selector (b i : Nat) (d : Reader) : Sel × Reader :=
  if (b / 10) % 2 = 1 then let (j, d2) := d.next; (.two i j, d2) else (.one i, d)

mutual
partial def nodes (d0 : Reader) (depth : Nat) : List RNode × Reader := Id.run do
  let (b, d1) := d0.next
  let count := if depth = 0 then 0 else b % 4
  let mut d := d1
  let mut out := #[]
  let mut k := 0
  while k < count && d.left > 0 do
    let (n, d2) := node { d with left := d.left - 1 } (depth - 1)
    out := out.push n
    d := d2
    k := k + 1
  return (out.toList, d)
partial def node (d0 : Reader) (depth : Nat) : RNode × Reader :=
  let (b, d1) := d0.next
  let (i, d2) := d1.next
  match b % 10 with
  | 0 | 1 =>
      if b ≥ 100 then (.guard i, d2)
      else if b ≥ 20 then (.control i, d2)
      else if (b / 10) % 2 = 0 then (.show i, d2)
      else let (j, d3) := d2.next; (.pair i j, d3)
  | 2 =>
      if (b / 10) % 2 = 0 then (.bump i, d2)
      else let (j, d3) := d2.next; (.bump2 i j, d3)
  | 3 =>
      let (sel, d3) := selector b i d2
      let (yes, d4) := nodes d3 depth
      let (no, d5) := nodes d4 depth
      (.when sel yes no, d5)
  | 4 =>
      let (sel, d3) := selector b i d2
      let (a, d4) := nodes d3 depth
      let (b1, d5) := nodes d4 depth
      let (c, d6) := nodes d5 depth
      (.switch sel a b1 c, d6)
  | 5 | 6 =>
      let (body, d3) := nodes d2 depth
      (.layer (b / 10) i body, d3)
  | 7 | 8 =>
      let (sel, d3) := selector b i d2
      let (body, d4) := nodes d3 depth
      (.each sel body, d4)
  | _ => if b ≥ 100 then twoWrites i d2 depth else (.watch (b / 10) i, d2)
/-- `two_writes`: a button writing the root and a state below it, with a
structural reader of both below them, one through a derived value, holding
a state; the nodes after the reader are decoded from what follows. -/
partial def twoWrites (v : Nat) (d0 : Reader) (depth : Nat) : RNode × Reader :=
  let (rest, d1) := nodes { d0 with left := d0.left - min d0.left 6 } depth
  let held := [RNode.layer 0 0 []]
  let reader := fun (sel : Sel) => match (v / 2) % 3 with
    | 0 => RNode.when sel held held
    | 1 => RNode.switch sel held held held
    | _ => RNode.each sel held
  if v % 2 = 0 then
    let inner := RNode.layer 0 0 ([.bump2 0 128, reader (.two 129 128)] ++ rest)
    let outer := match (v / 6) % 3 with
      | 0 => RNode.layer 1 0 [inner]
      | 1 => RNode.layer 2 0 [inner]
      | _ => RNode.each (.one 0) [inner]
    (outer, d1)
  else
    (.layer 0 0 [.layer 1 128 ([.bump2 0 128, reader (.two 0 128)] ++ rest)], d1)
end

/-- `decode`: at most 5 deep and 40 nodes. -/
def decode (bytes : List Nat) : List RNode :=
  (nodes { bytes := bytes.toArray, pos := 0, left := 40 } 5).1

/-! ### Typed levels (`Level`, `level_below`) -/

/-- Where the generator's typed contexts put a body. Below `last`, and
below a row's own layer, a `Layer` or an `Each` draws its body in place
and adds no scope. -/
inductive Level where
  | root | second | third | last | inRow | flat
  deriving DecidableEq, Repr

/-- The levels a layer's body and a row's body are built at. -/
def Level.below : Level → Option (Level × Level)
  | .root => some (.second, .inRow)
  | .second => some (.third, .inRow)
  | .third => some (.last, .inRow)
  | .last => some (.flat, .flat)
  | .inRow => some (.last, .flat)
  | .flat => none

/-! ### Meaning -/

/-- `Reference.place`: the position index `i` names in a list of `len`
entries, from the start below 128 and from the end at 128 and above. -/
def place (len i : Nat) : Nat :=
  let n := max len 1
  if i ≥ 128 then n - 1 - (i - 128) % n else i % n

/-- `Reference.derived`: a `derive` layer of kind `kind` computes `2x + 1`
when `(kind / 5)` is even and `x / 2` when it is odd. -/
def derived (kind : Nat) (x : Expr) : Expr :=
  if (kind / 5) % 2 = 0 then .add (.mul x (.lit 2)) (.lit 1) else .div x (.lit 2)

/-- What a node can read and write where it is built: the layers on its
path (the generator's `vals`, one per layer, so the kernel's layer index is
the position in `vals`) and the layers of those that are states (`wrs`). -/
structure Scope where
  depth : Nat
  wrs : List Nat

/-- `pick(vals, i)`: the layer a node's index names. -/
def Scope.seen (s : Scope) (i : Nat) : Expr := .rd (.layer (place s.depth i))

/-- `pick(wrs, i)`: the state a button's index names. The root is always
writable, so `wrs` is never empty. -/
def Scope.wrote (s : Scope) (i : Nat) : Nat := s.wrs.getD (place s.wrs.length i) 0

/-- `chosen`: what a `when`, a `switch` or an `each` follows. -/
def Scope.chosen (s : Scope) : Sel → Expr
  | .one i => s.seen i
  | .two i j => .add (s.seen i) (s.seen j)

/-- A click's write of one state: add 1. -/
def plusOne (d : Nat) : Ref × Expr := (.layer d, .add (.rd (.layer d)) (.lit 1))

mutual
/-- The kernel nodes one generated node becomes, spliced into its block. -/
partial def toNodes (s : Scope) (level : Level) : RNode → List Node
  | .show i => [.show (s.seen i)]
  | .guard _ | .control _ | .watch _ _ => []
  | .bump i => [.bump [plusOne (s.wrote i)]]
  | .bump2 i j => [.bump [plusOne (s.wrote i), plusOne (s.wrote j)]]
  | .pair i j =>
      -- A `derive` of layer `i` as `x * 2 + 1`, and below it one text of
      -- layer `i`, the derived value and layer `j`.
      [.derive (.add (.mul (s.seen i) (.lit 2)) (.lit 1))
        [.joined [s.seen i, .rd (.layer s.depth), s.seen j]]]
  | .when sel yes no =>
      [.when (.eq (.mod (s.chosen sel) (.lit 2)) (.lit 0)) (toBlock s level yes) (toBlock s level no)]
  | .switch sel a b c =>
      [.switch (s.chosen sel) (toBlock s level a) (toBlock s level b) (toBlock s level c)]
  | .layer kind i body =>
      match level.below with
      | none => toBlock s level body
      | some (inner, _) =>
          let d := s.depth
          if kind % 5 = 0 then
            [.state 0 ([.show (.rd (.layer d)), .bump [plusOne d]]
              ++ toBlock { depth := d + 1, wrs := s.wrs ++ [d] } inner body)]
          else
            let e := if kind % 5 = 1 then derived kind (s.seen i) else .add (s.seen i) (.lit 7)
            [.derive e (.show (.rd (.layer d)) :: toBlock { s with depth := d + 1 } inner body)]
  | .each sel body =>
      match level.below with
      | none => toBlock s level body
      | some (_, row) =>
          [.each (s.chosen sel) (.keyed (.rd (.layer s.depth)) :: toBlock { s with depth := s.depth + 1 } row body)]
partial def toBlock (s : Scope) (level : Level) (ns : List RNode) : List Node :=
  ns.flatMap (toNodes s level)
end

/-- The page `view` builds: the root state at 0, its text and its button,
then the tree at the first level. The store has no cells. -/
def toKernel (tree : List RNode) : Prog :=
  { cells := [],
    body := [.state 0 ([.show (.rd (.layer 0)), .bump [plusOne 0]]
      ++ toBlock { depth := 1, wrs := [0] } .root tree)] }

/-! ### Text form, in the Roc tag names -/

def Sel.sx : Sel → String
  | .one i => s!"(One {i})"
  | .two i j => s!"(Two {i} {j})"

mutual
partial def RNode.sx : RNode → String
  | .show i => s!"(Show {i})"
  | .guard i => s!"(Guard {i})"
  | .control i => s!"(Control {i})"
  | .bump i => s!"(Bump {i})"
  | .bump2 i j => s!"(Bump2 {i} {j})"
  | .pair i j => s!"(Pair {i} {j})"
  | .when sel yes no => s!"(When {sel.sx} {rlistSx yes} {rlistSx no})"
  | .switch sel a b c => s!"(Switch {sel.sx} {rlistSx a} {rlistSx b} {rlistSx c})"
  | .layer k i body => s!"(Layer {k} {i} {rlistSx body})"
  | .each sel body => s!"(Each {sel.sx} {rlistSx body})"
  | .watch k i => s!"(Watch {k} {i})"
/-- A `List(Node)`: its nodes in parentheses. -/
partial def rlistSx (ns : List RNode) : String := "(" ++ " ".intercalate (ns.map RNode.sx) ++ ")"
end

/-- A tree: its nodes, separated by spaces. -/
def treeSx (ns : List RNode) : String := " ".intercalate (ns.map RNode.sx)

def toSel : Sx → Option Sel
  | .list [.atom "One", .atom i] => i.toNat?.map .one
  | .list [.atom "Two", .atom i, .atom j] => do pure (.two (← i.toNat?) (← j.toNat?))
  | _ => none

partial def toRNode : Sx → Option RNode
  | .list [.atom "Show", .atom i] => i.toNat?.map .show
  | .list [.atom "Guard", .atom i] => i.toNat?.map .guard
  | .list [.atom "Control", .atom i] => i.toNat?.map .control
  | .list [.atom "Bump", .atom i] => i.toNat?.map .bump
  | .list [.atom "Bump2", .atom i, .atom j] => do pure (.bump2 (← i.toNat?) (← j.toNat?))
  | .list [.atom "Pair", .atom i, .atom j] => do pure (.pair (← i.toNat?) (← j.toNat?))
  | .list [.atom "Watch", .atom k, .atom i] => do pure (.watch (← k.toNat?) (← i.toNat?))
  | .list [.atom "When", sel, .list yes, .list no] => do
      pure (.when (← toSel sel) (← yes.mapM toRNode) (← no.mapM toRNode))
  | .list [.atom "Switch", sel, .list a, .list b, .list c] => do
      pure (.switch (← toSel sel) (← a.mapM toRNode) (← b.mapM toRNode) (← c.mapM toRNode))
  | .list [.atom "Layer", .atom k, .atom i, .list body] => do
      pure (.layer (← k.toNat?) (← i.toNat?) (← body.mapM toRNode))
  | .list [.atom "Each", sel, .list body] => do pure (.each (← toSel sel) (← body.mapM toRNode))
  | _ => none

/-- A tree in text form, or `none` if it does not parse. -/
def parseTree (s : String) : Option (List RNode) :=
  match parseSx (tokens ("(" ++ s ++ ")")) with
  | some (.list xs, []) => xs.mapM toRNode
  | _ => none

end Turns.Structure
