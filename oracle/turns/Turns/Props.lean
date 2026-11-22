/-
The checks: P1–P5 for one turn of the incremental algorithm against the
reference, and what an oracle that sees less would still see.
-/
import Turns.Expect
import Turns.Incr
namespace Turns

/-- What a step can break. The first three need nothing but the command
stream (and, for `CNT`, the engine's evaluation counter); the rest need the
evaluation log or the engine's storage. -/
inductive Tag where
  | page     -- P3 as the DOM shows it: the leaves in document order
  | shape    -- the stream's shape: how many texts set, which scopes created
  | count    -- how many evaluations (G3)
  | p1       -- an evaluation read something other than its value after the turn, or was of a reader the turn leaves dead
  | p2       -- a reader evaluated twice, a node written twice, a created node updated, a scope removed and created
  | p3       -- P3 with identities: local state, cells and the page by identity
  | p4       -- the settle check emits a command
  | p5       -- an evaluation nothing justified
  | cmd      -- a command that does not fit the page
  deriving DecidableEq, Repr, Inhabited

def Tag.all : List Tag := [.page, .shape, .count, .p1, .p2, .p3, .p4, .p5, .cmd]
def Tag.bit (t : Tag) : Nat := 1 <<< (Tag.all.idxOf t)
def Tag.name : Tag → String
  | .page => "page" | .shape => "shape" | .count => "count" | .p1 => "P1" | .p2 => "P2"
  | .p3 => "P3id" | .p4 => "P4" | .p5 => "P5" | .cmd => "cmd"

/-- The reference and the incremental instance, side by side. -/
structure Sim where
  w : World
  s : Instance
  dom : List Dom

def hasDup : List Ident → Bool
  | [] => false
  | x :: xs => xs.contains x || hasDup xs

def flag (t : Tag) (bad : Bool) : Nat := if bad then t.bit else 0

/-- The page and the storage against the reference: P3 and P4. -/
def checkState (g : Cfg) (p : Prog) (sim : Sim) : Nat :=
  let v := view p sim.w
  let page := flatDoms [] sim.dom
  flag .page (page.map (·.2) != (pageOf v).map (·.2))
    ||| flag .p3 (page != pageOf v || instRho [] sim.s.root != sim.w.rho || sim.s.cells != sim.w.cells)
    ||| flag .p4 ((settleCmds g p sim.s).size != 0)

def mountSim (g : Cfg) (p : Prog) : Sim × Nat :=
  let (s, dom, _) := mountProg g p
  let sim : Sim := { w := World.init p, s, dom }
  (sim, checkState g p sim)

/-- One event at `ev`, a live button of the reference. Answers the next
state, the violations as a set of tags, and the evaluations made. -/
def checkStep (g : Cfg) (p : Prog) (sim : Sim) (ev : Ident) : Sim × Nat × Nat :=
  let ws := match (view p sim.w).lookup ev with
    | some (.button ws) => ws
    | _ => []
  let w1 := (stepRef p sim.w ev).getD sim.w
  match turn g p sim.s ev with
  | none => ({ sim with w := w1 }, Tag.page.bit ||| Tag.p3.bit, 0)
  | some (s1, tx) =>
      let exp := expect g.α p sim.w w1 ws
      let (dom1, bad) := match applyCmds sim.dom tx.cmds with
        | .ok d => (d, false)
        | .error _ => (sim.dom, true)
      let sim1 : Sim := { w := w1, s := s1, dom := dom1 }
      let log := tx.log.toList
      let cmds := tx.cmds.toList
      let texts := cmds.filterMap fun | .setText id _ => some id | _ => none
      let created := cmds.filterMap fun | .create id _ => some id | _ => none
      let removed := cmds.filterMap fun | .remove id => some id | _ => none
      let due := exp.readers.filter (·.due)
      let v :=
        checkState g p sim1
        ||| flag .cmd bad
        ||| flag .p1 (!log.all fun (id, env) => exp.readers.any fun r =>
              r.id = id && r.reads.all fun x => env.get x = r.env.get x)
        ||| flag .p2 (hasDup (log.map (·.1)) || hasDup texts
              || created.any (fun c => texts.any fun t => c.isPrefixOf t)
              || created.any removed.contains)
        ||| flag .p5 (!log.all fun (id, _) => due.any fun r => r.id = id)
        ||| flag .count (log.length != due.length)
        ||| flag .shape (texts.length != (exp.readers.filter (·.text)).length
              || !(created.all exp.created.contains && exp.created.all created.contains))
      (sim1, v, log.length)

end Turns
