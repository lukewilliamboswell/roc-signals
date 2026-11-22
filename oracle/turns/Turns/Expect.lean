/-
What a turn may do, said from the reference alone: for every reader live
after the turn, the environment an evaluation of it must see (P1), whether
the turn evaluates it at all (P5 and the evaluation count), which texts it
sets and which scopes it creates. It compares the world before with the
world after; it is a specification, not an algorithm, and carries no state.

This is a second specification, beside `Turns.Spec`: Spec says what the
page is, this file says how much work a turn may do and which reader may
see what. Trusted for: the due set (the readers a turn must evaluate,
under a signature abstraction), the environment each evaluation must see,
the texts set and the scopes created. Its evaluation count is the
kernel's: holes, `joined` holes, selectors, list reads and `derive`
inputs. It is not the engine's counter of evaluations, which also counts
what the kernel leaves out; relating the two is the count model's work.
-/
import Turns.Spec
namespace Turns

structure Reading where
  id : Ident
  reads : List Ref -- what it reads
  env : Env        -- the environment after the turn: what an evaluation must see of its reads
  due : Bool       -- whether the turn evaluates it
  text : Bool      -- a hole of a surviving scope whose text changes
  deriving Repr

inductive Fact where
  | reader (r : Reading)
  | created (id : Ident)   -- a branch or a row the turn creates
  deriving Repr

/-- The turn: both worlds, the state sites it wrote, and the abstraction. -/
structure Delta where
  α : Alpha
  w0 : World
  w1 : World
  written : List Ident

def scope (old : Option Env) (same : Bool) (sid : Ident) : Option Env × List Fact :=
  if old.isSome && !same then (none, [.created sid]) else (if same then old else none, [])

mutual
/-- `old` is the environment before the turn, or `none` in a scope the turn
creates; `m` is the abstracted signature of what changed above. -/
def expNode (x : Delta) (old : Option Env) (new : Env) (m : Mask) (id : Ident) : Node → List Fact
  | .show e =>
      let v1 := e.eval new.get
      [.reader ⟨id, e.reads, new, old.isNone || hit (x.α.sig e.reads) m,
        match old with | some o => e.eval o.get != v1 | none => false⟩]
  | .joined es =>
      let rs := es.flatMap Expr.reads
      let v1 := es.map (·.eval new.get)
      [.reader ⟨id, rs, new, old.isNone || hit (x.α.sig rs) m,
        match old with | some o => es.map (·.eval o.get) != v1 | none => false⟩]
  | .bump _ => []
  | .state init body =>
      let v0 := (x.w0.rho.lookup id).getD init
      let v1 := (x.w1.rho.lookup id).getD init
      let m' := if x.written.contains id then m ||| x.α.mask (.layer new.depth) else m
      expBlock x (old.map (·.push v0)) (new.push v1) m' id 0 body
  | .derive e body =>
      let v1 := e.eval new.get
      let due := old.isNone || hit (x.α.sig e.reads) m
      let changed := match old with | some o => e.eval o.get != v1 | none => false
      let m' := if due && changed then m ||| x.α.mask (.layer new.depth) else m
      .reader ⟨id, e.reads, new, due, false⟩ ::
        expBlock x (old.map fun o => o.push (e.eval o.get)) (new.push v1) m' id 0 body
  | .when sel yes no =>
      let k := sel.eval new.get ≠ 0
      let same := match old with | some o => decide (sel.eval o.get ≠ 0) == decide k | none => false
      let rd := Fact.reader ⟨id, sel.reads, new, old.isNone || hit (x.α.sig sel.reads) m, false⟩
      if k then
        let (old', mk) := scope old same (id ++ [.b 0])
        rd :: mk ++ expBlock x old' new m (id ++ [.b 0]) 0 yes
      else
        let (old', mk) := scope old same (id ++ [.b 1])
        rd :: mk ++ expBlock x old' new m (id ++ [.b 1]) 0 no
  | .switch sel a b c =>
      let k := (sel.eval new.get % 3).toNat
      let same := match old with | some o => (sel.eval o.get % 3).toNat == k | none => false
      let rd := Fact.reader ⟨id, sel.reads, new, old.isNone || hit (x.α.sig sel.reads) m, false⟩
      let (old', mk) := scope old same (id ++ [.b (min k 2)])
      match k with
      | 0 => rd :: mk ++ expBlock x old' new m (id ++ [.b 0]) 0 a
      | 1 => rd :: mk ++ expBlock x old' new m (id ++ [.b 1]) 0 b
      | _ => rd :: mk ++ expBlock x old' new m (id ++ [.b 2]) 0 c
  | .each src body =>
      let keys0 := match old with | some o => keysOf (src.eval o.get) | none => []
      .reader ⟨id, src.reads, new, old.isNone || hit (x.α.sig src.reads) m, false⟩ ::
        (keysOf (src.eval new.get)).flatMap fun k =>
          let (old', mk) := scope old (keys0.contains k) (id ++ [.r k])
          mk ++ expBlock x (old'.map (·.push k)) (new.push k) m (id ++ [.r k]) 0 body
def expBlock (x : Delta) (old : Option Env) (new : Env) (m : Mask) (id : Ident) (i : Nat) :
    List Node → List Fact
  | [] => []
  | n :: ns => expNode x old new m (id ++ [.c i]) n ++ expBlock x old new m id (i + 1) ns
end

structure Expected where
  readers : List Reading
  created : List Ident

/-- What the turn from `w0` to `w1` that wrote `ws` may do. -/
def expect (α : Alpha) (p : Prog) (w0 w1 : World) (ws : List (Target × Val)) : Expected :=
  let written := ws.filterMap fun | (.state id, _) => some id | _ => none
  let cells := ws.filterMap fun | (.cell c, _) => some (Ref.cell c) | _ => none
  let facts := expBlock ⟨α, w0, w1, written⟩ (some ⟨w0.cells, []⟩) ⟨w1.cells, []⟩ (α.sig cells) [] 0 p.body
  { readers := facts.filterMap fun | .reader r => some r | _ => none
    created := facts.filterMap fun | .created id => some id | _ => none }

end Turns
