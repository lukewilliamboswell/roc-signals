/-
A generator of programs from a stream of choices. Random digits give a
seeded random program; counting through every stream the generator can ask
for (`nextDigits`) gives every program within the bounds (a program repeats
where the size bound cuts a block short of the length chosen for it).
-/
import Spike.Kernel
namespace Spike

structure GenP where
  maxDepth : Nat := 4    -- nesting of sites (a `state` can nest to any depth)
  maxLen : Nat := 3      -- children of a block
  fuel : Nat := 14       -- sites in a program
  cells : Nat := 2
  menu : Nat := 5        -- reader expressions: 2 has one read, 5 has two
  kinds : Nat := 7       -- site kinds: 6 leaves out `switch`
  inits : Nat := 2       -- a state starts at 0 .. inits-1
  auto : Bool := true    -- a state shows itself and has a button; a row shows its key
  amounts : Nat := 2     -- a write adds 1 .. amounts

structure GS where
  digits : Array Nat
  pos : Nat := 0
  radices : Array Nat := #[]
  fuel : Nat

abbrev G := StateM GS

/-- A choice among `n`. Its radix is recorded, so the streams that reach
different programs can be counted through. -/
def choose (n : Nat) : G Nat := do
  if n ≤ 1 then return 0
  let s ← get
  let d := s.digits.getD s.pos 0 % n
  set { s with pos := s.pos + 1, radices := s.radices.push n }
  return d

/-- `sc`: the layers in scope, `true` for a `state` (writable). -/
def pickRef (sc : List Bool) (nc : Nat) : G (Option Ref) := do
  let n := sc.length + nc
  if n = 0 then return none
  let k ← choose n
  -- Innermost layers first, so a short stream reads what is nearest.
  return some (if k < sc.length then .layer (sc.length - 1 - k) else .cell (k - sc.length))

def genExpr (p : GenP) (sc : List Bool) : G Expr := do
  match ← pickRef sc p.cells with
  | none => return .lit 1
  | some a =>
      match ← choose p.menu with
      | 0 => return .rd a
      | 1 => return .mod (.rd a) (.lit 2)
      | k =>
          let some b ← pickRef sc p.cells | return .rd a
          return match k with
            | 2 => .add (.rd a) (.rd b)
            | 3 => .eq (.rd a) (.rd b)
            | _ => .mod (.add (.rd a) (.rd b)) (.lit 2)

def bumpOf (r : Ref) (amount : Nat) : Ref × Expr := (r, .add (.rd r) (.lit (amount + 1)))

def genHandler (p : GenP) (sc : List Bool) : G (Option Handler) := do
  let layers := ((List.range sc.length).zip sc).filterMap fun (i, st) => if st then some (Ref.layer i) else none
  let targets := layers.reverse ++ (List.range p.cells).map Ref.cell
  if targets.isEmpty then return none
  let a ← choose targets.length
  let amount ← choose p.amounts
  let first := targets.getD a (.cell 0)
  if targets.length > 1 && (← choose 2) = 1 then
    let rest := targets.filter (· ≠ first)
    let second := rest.getD (← choose rest.length) (.cell 0)
    return some [bumpOf first amount, bumpOf second amount]
  return some [bumpOf first amount]

mutual
partial def genNode (p : GenP) (sc : List Bool) (depth : Nat) : G Node := do
  match ← choose (if depth = 0 then 2 else p.kinds) with
  | 0 => return .show (← genExpr p sc)
  | 1 =>
      match ← genHandler p sc with
      | some h => return .bump h
      | none => return .show (← genExpr p sc)
  | 2 =>
      let init ← choose p.inits
      let d := sc.length
      let own := if p.auto then [Node.show (.rd (.layer d)), .bump [bumpOf (.layer d) 0]] else []
      return .state init (own ++ (← genBlock p (sc ++ [true]) (depth - 1)))
  | 3 =>
      let e ← genExpr p sc
      return .derive e (← genBlock p (sc ++ [false]) (depth - 1))
  | 4 =>
      let sel ← genExpr p sc
      let yes ← genBlock p sc (depth - 1)
      return .when sel yes (← genBlock p sc (depth - 1))
  | 5 =>
      let src ← genExpr p sc
      let own := if p.auto then [Node.show (.rd (.layer sc.length))] else []
      return .each src (own ++ (← genBlock p (sc ++ [false]) (depth - 1)))
  | _ =>
      let sel ← genExpr p sc
      let a ← genBlock p sc (depth - 1)
      let b ← genBlock p sc (depth - 1)
      return .switch sel a b (← genBlock p sc (depth - 1))
partial def genBlock (p : GenP) (sc : List Bool) (depth : Nat) : G (List Node) := do
  let n ← choose (p.maxLen + 1)
  let mut out := #[]
  for _ in [0:n] do
    if (← get).fuel = 0 then break
    modify fun s => { s with fuel := s.fuel - 1 }
    out := out.push (← genNode p sc depth)
  return out.toList
end

/-- The program a stream of digits decodes to, and the radices it was asked. -/
def decode (p : GenP) (digits : Array Nat) : Prog × Array Nat :=
  let (body, s) := (genBlock p [] p.maxDepth).run { digits, fuel := p.fuel }
  ({ cells := List.replicate p.cells 0, body }, s.radices)

/-- The next stream in the count through every stream, or `none` at the end. -/
def nextDigits (digits radices : Array Nat) : Option (Array Nat) := Id.run do
  let mut i := radices.size
  while i > 0 do
    i := i - 1
    let d := digits.getD i 0 % radices[i]!
    if d + 1 < radices[i]! then
      return some (((List.range i).map fun j => digits.getD j 0 % radices[j]!).toArray.push (d + 1))
  return none

/-- SplitMix64. -/
def mix (s : UInt64) : UInt64 × UInt64 :=
  let s := s + 0x9E3779B97F4A7C15
  let z := (s ^^^ (s >>> 30)) * 0xBF58476D1CE4E5B9
  let z := (z ^^^ (z >>> 27)) * 0x94D049BB133111EB
  (z ^^^ (z >>> 31), s)

def randoms (seed : Nat) (n : Nat) : Array Nat := Id.run do
  let mut s : UInt64 := UInt64.ofNat (seed * 2654435761 + 12345)
  let mut out := Array.mkEmpty n
  for _ in [0:n] do
    let (z, s') := mix s
    s := s'
    out := out.push (z >>> 16).toNat
  return out

end Spike
