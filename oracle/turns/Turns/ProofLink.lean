/-
The proof is about `Static.go`, a model of the static fragment written for
proving. This file ties it to the executable algorithm by test, not by
proof: on a static program, one turn of `Incr.turn` must leave the same
storage as `Static.walk` after `Static.pass`.
-/
import Turns.Incr
import Turns.Proof
namespace Turns

/-- A mounted static block as the proof's chain of sites. Buttons hold no
storage and are left out. `none`: the block is not in the fragment. -/
partial def toS : List Node → List Inst → Option Static.S
  | [], [] => some .nil
  | .show e :: ns, .hole last :: is => (toS ns is).map (.hole e last)
  | .bump _ :: ns, .button :: is => toS ns is
  | .state _ body :: ns, .state v w kids :: is => do pure (.state v w (← toS body kids) (← toS ns is))
  | .derive e body :: ns, .derive v kids :: is => do pure (.derive e v (← toS body kids) (← toS ns is))
  | _, _ => none

/-- One event both ways. Answers whether they agree, and whether the event
wrote more than one thing. -/
def linkStep (g : Cfg) (p : Prog) (s : Instance) (ev : Ident) : Option (Bool × Bool) := do
  let (h, env, sites) ← locate p.body s.root ⟨s.cells, []⟩ [] ev
  let ws := h.writes env fun i => sites.getD i false
  let lw := ws.filterMap fun
    | (.layer i, v) => some (i, v)
    | _ => none
  let cw := ws.filterMap fun
    | (.cell c, v) => some (c, v)
    | _ => none
  let cells := cw.foldl (fun cs (c, v) => cs.set c v) s.cells
  -- `Wrote`: every written state site takes its value and waits.
  let (marked, _) := (along (fun d _ _ _ (v, w, kids) =>
      match lw.reverse.lookup d with
      | some v' => pure (v', true, kids)
      | none => pure (v, w, kids)) p.body s.root ⟨cells, []⟩ [] ev).run {}
  let t ← toS p.body marked
  let (s1, _) ← turn g p s ev
  let want ← toS p.body s1.root
  let ρ : Static.E := fun r => match r with
    | .cell c => cells.getD c 0
    | .layer _ => 0
  let m : Static.Mask := fun b => cw.any fun (c, _) => g.α.bit (.cell c) == b
  pure (decide (Static.walk g.α.bit ρ 0 (Static.pass g.α.bit m ρ 0 t) = want), lw.length + cw.length > 1)

end Turns
