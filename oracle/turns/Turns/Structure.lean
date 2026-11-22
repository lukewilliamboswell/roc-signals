/-
The Roc generator's programs, and what each means in the kernel.

`RNode` is the `Node` type of `fuzz/structure/FuzzStructureProperty.roc`,
with its byte decoder, as the value model reads it in its valued mode:
every state is written by clicks, starts at 0, and nothing is awaited (a
`resource` issues nothing, so its layer is its `pending` value). The Roc
type is the authority for what can be generated; `toKernel` says what a
generated tree means, and the reference (`Turns.Spec`) gives the page.

Trusted for: the shape of the Roc generator's trees (`RNode`, `decode`),
its selector rules (`chosen`), its row keys (the kernel's `keysOf`, which
is the generator's `row_keys`) and its typed levels (`Level.below`). This
file follows the generator as `wip/reactivity-oracle/patches/value-model.patch`
leaves it: a `when`, `switch` or `each` whose index is 128 or more reads
two signals, `chosen`. When that generator changes, this file changes with
it and the vectors are regenerated.

What the translation leaves out, because the valued page does not show it:
`Guard`, `Control` and `Watch` draw no text and become nothing, so they are
neither on the page nor counted as evaluations; the wrapper elements of
every block are not modelled.
-/
import Turns.Text
namespace Turns.Structure

open Turns

/-- `Node` of `fuzz/structure/FuzzStructureProperty.roc`. -/
inductive RNode where
  | show (i : Nat)
  | guard (i : Nat)
  | control (i : Nat)
  | bump (i : Nat)
  | bump2 (i j : Nat)
  | pair (i j : Nat)
  | when (i : Nat) (yes no : List RNode)
  | switch (i : Nat) (a b c : List RNode)
  | layer (kind i : Nat) (body : List RNode)
  | each (i : Nat) (body : List RNode)
  | watch (k i : Nat)
  deriving Repr, BEq, Inhabited

/-! ### The byte decoder (`nodes`, `node`, `decode`) -/

structure Reader where
  bytes : Array Nat
  pos : Nat
  left : Nat

def Reader.next (d : Reader) : Nat × Reader := (d.bytes.getD d.pos 0, { d with pos := d.pos + 1 })

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
      let (yes, d3) := nodes d2 depth
      let (no, d4) := nodes d3 depth
      (.when i yes no, d4)
  | 4 =>
      let (a, d3) := nodes d2 depth
      let (b1, d4) := nodes d3 depth
      let (c, d5) := nodes d4 depth
      (.switch i a b1 c, d5)
  | 5 | 6 =>
      let (body, d3) := nodes d2 depth
      (.layer (b / 10) i body, d3)
  | 7 | 8 =>
      let (body, d3) := nodes d2 depth
      (.each i body, d3)
  | _ => (.watch (b / 10) i, d2)
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

/-- What a node can read and write where it is built: the layers on its
path (the generator's `vals`, one per layer, so the kernel's layer index is
the position in `vals`) and the layers of those that are states (`wrs`). -/
structure Scope where
  depth : Nat
  wrs : List Nat

/-- `pick(vals, i)`: the layer a node's index names. -/
def Scope.seen (s : Scope) (i : Nat) : Expr := .rd (.layer (i % max s.depth 1))

/-- `pick(wrs, i)`: the state a button's index names. The root is always
writable, so `wrs` is never empty. -/
def Scope.wrote (s : Scope) (i : Nat) : Nat := s.wrs.getD (i % max s.wrs.length 1) 0

/-- `chosen_of`: what a `when`, a `switch` or an `each` follows. An index of
128 or more reads two layers, as their sum. -/
def Scope.chosen (s : Scope) (i : Nat) : Expr :=
  if i ≥ 128 then .add (s.seen i) (s.seen (i / 16)) else s.seen i

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
  | .when i yes no =>
      [.when (.eq (.mod (s.chosen i) (.lit 2)) (.lit 0)) (toBlock s level yes) (toBlock s level no)]
  | .switch i a b c =>
      [.switch (s.chosen i) (toBlock s level a) (toBlock s level b) (toBlock s level c)]
  | .layer kind i body =>
      match level.below with
      | none => toBlock s level body
      | some (inner, _) =>
          let d := s.depth
          if kind % 5 = 0 then
            [.state 0 ([.show (.rd (.layer d)), .bump [plusOne d]]
              ++ toBlock { depth := d + 1, wrs := s.wrs ++ [d] } inner body)]
          else
            let e := if kind % 5 = 1 then .add (.mul (s.seen i) (.lit 2)) (.lit 1) else .add (s.seen i) (.lit 7)
            [.derive e (.show (.rd (.layer d)) :: toBlock { s with depth := d + 1 } inner body)]
  | .each i body =>
      match level.below with
      | none => toBlock s level body
      | some (_, row) =>
          [.each (s.chosen i) (.show (.rd (.layer s.depth)) :: toBlock { s with depth := s.depth + 1 } row body)]
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

mutual
partial def RNode.sx : RNode → String
  | .show i => s!"(Show {i})"
  | .guard i => s!"(Guard {i})"
  | .control i => s!"(Control {i})"
  | .bump i => s!"(Bump {i})"
  | .bump2 i j => s!"(Bump2 {i} {j})"
  | .pair i j => s!"(Pair {i} {j})"
  | .when i yes no => s!"(When {i} {rlistSx yes} {rlistSx no})"
  | .switch i a b c => s!"(Switch {i} {rlistSx a} {rlistSx b} {rlistSx c})"
  | .layer k i body => s!"(Layer {k} {i} {rlistSx body})"
  | .each i body => s!"(Each {i} {rlistSx body})"
  | .watch k i => s!"(Watch {k} {i})"
/-- A `List(Node)`: its nodes in parentheses. -/
partial def rlistSx (ns : List RNode) : String := "(" ++ " ".intercalate (ns.map RNode.sx) ++ ")"
end

/-- A tree: its nodes, separated by spaces. -/
def treeSx (ns : List RNode) : String := " ".intercalate (ns.map RNode.sx)

partial def toRNode : Sx → Option RNode
  | .list [.atom "Show", .atom i] => i.toNat?.map .show
  | .list [.atom "Guard", .atom i] => i.toNat?.map .guard
  | .list [.atom "Control", .atom i] => i.toNat?.map .control
  | .list [.atom "Bump", .atom i] => i.toNat?.map .bump
  | .list [.atom "Bump2", .atom i, .atom j] => do pure (.bump2 (← i.toNat?) (← j.toNat?))
  | .list [.atom "Pair", .atom i, .atom j] => do pure (.pair (← i.toNat?) (← j.toNat?))
  | .list [.atom "Watch", .atom k, .atom i] => do pure (.watch (← k.toNat?) (← i.toNat?))
  | .list [.atom "When", .atom i, .list yes, .list no] => do
      pure (.when (← i.toNat?) (← yes.mapM toRNode) (← no.mapM toRNode))
  | .list [.atom "Switch", .atom i, .list a, .list b, .list c] => do
      pure (.switch (← i.toNat?) (← a.mapM toRNode) (← b.mapM toRNode) (← c.mapM toRNode))
  | .list [.atom "Layer", .atom k, .atom i, .list body] => do
      pure (.layer (← k.toNat?) (← i.toNat?) (← body.mapM toRNode))
  | .list [.atom "Each", .atom i, .list body] => do pure (.each (← i.toNat?) (← body.mapM toRNode))
  | _ => none

/-- A tree in text form, or `none` if it does not parse. -/
def parseTree (s : String) : Option (List RNode) :=
  match parseSx (tokens ("(" ++ s ++ ")")) with
  | some (.list xs, []) => xs.mapM toRNode
  | _ => none

end Turns.Structure
