/-
`lake exe bridge`: write traces, and check trace files against the
reference semantics.
-/
import Spike
open Spike

def nat (s : String) : Nat := s.toNat?.getD 0

def parseBug : String → Option Bug
  | "none" => some .none
  | "twoPassInner" => some .twoPassInner
  | "twoPassOuter" => some .twoPassOuter
  | "noJoinKeep" => some .noJoinKeep
  | "noJoinClear" => some .noJoinClear
  | "perWrite" => some .perWrite
  | "rowReset" => some .rowReset
  | "rowResurrect" => some .rowResurrect
  | "noWalk" => some .noWalk
  | "underSig" => some .underSig
  | "pruneWakes" => some .pruneWakes
  | _ => none

/-- A trace as an engine would produce it: the incremental model is driven
by clicks on its own page, and its page and evaluation count are recorded. -/
def modelTrace (g : Cfg) (gp : GenP) (name : String) (seed nsteps : Nat) : Trace := Id.run do
  let (p, _) := decode gp (randoms seed 256)
  let (s0, dom0, _) := mountProg g p
  let mut s := s0
  let mut dom := dom0
  let mut steps := #[]
  for r in randoms (seed + 1000003) nsteps do
    let buttons := (flatDoms [] dom).filterMap fun
      | (id, .button) => some id
      | _ => none
    if buttons.isEmpty then break
    let k := r % buttons.length
    match turn g p s (buttons.getD k []) with
    | none => break
    | some (s1, tx) =>
        s := s1
        dom := match applyCmds dom tx.cmds with
          | .ok d => d
          | .error _ => dom
        steps := steps.push { button := k, page := (flatDoms [] dom).map (·.2), evals := some tx.log.size }
  return { name, α := g.α, prog := p, page0 := (flatDoms [] dom0).map (·.2), steps := steps.toList }

/-- A test vector: the same format, written by the reference alone. -/
def vector (α : Alpha) (gp : GenP) (name : String) (seed nsteps : Nat) : Trace :=
  refTrace α (decode gp (randoms seed 256)).1 name (randoms (seed + 1000003) nsteps).toList

def main (args : List String) : IO UInt32 := do
  match args with
  | ["gen", out, bug, lm, cm, auto, seed0, count, steps] =>
      let some b := parseBug bug | IO.eprintln "unknown bug"; return 2
      let g : Cfg := { α := ⟨nat lm, nat cm⟩, bug := b }
      let gp : GenP := { auto := auto = "1" }
      let h ← IO.FS.Handle.mk out .write
      let mut n := 0
      for i in [0:nat count] do
        let t := modelTrace g gp s!"{bug}-{nat seed0 + i}" (nat seed0 + i) (nat steps)
        n := n + t.steps.length
        h.putStr t.text
      IO.println s!"wrote {count} traces, {n} steps to {out}"
      return 0
  | ["vectors", out, lm, cm, seed0, count, steps, minSteps] =>
      let h ← IO.FS.Handle.mk out .write
      let mut seed := nat seed0
      let mut made := 0
      while made < nat count do
        let t := vector ⟨nat lm, nat cm⟩ {} s!"vector-{seed}" seed (nat steps)
        seed := seed + 1
        if t.steps.length ≥ nat minSteps then
          h.putStr t.text
          made := made + 1
      IO.println s!"wrote {made} vectors to {out}"
      return 0
  | "check" :: files =>
      let mut failed := false
      for file in files do
        let t0 ← IO.monoNanosNow
        let text ← IO.FS.readFile file
        match parseTraces text with
        | .error e => IO.eprintln s!"{file}: {e}"; return 2
        | .ok traces =>
            let t1 ← IO.monoNanosNow
            let mut steps := 0
            let mut pages := 0
            let mut counts := 0
            let mut shown := 0
            for t in traces do
              let (verdict, n) := checkTrace t
              steps := steps + n
              let say := fun (msg : String) => if shown < 3 then IO.println s!"  {t.name}: {msg}" else pure ()
              match verdict with
              | .ok => pure ()
              | .page step expected =>
                  pages := pages + 1
                  let observed := if step = 0 then t.page0 else ((t.steps.drop (step - 1)).head?.map (·.page)).getD []
                  say s!"page differs at step {step}: expected [{leavesTok expected}] observed [{leavesTok observed}]"
                  shown := shown + 1
              | .evals step expected =>
                  counts := counts + 1
                  let observed := ((t.steps.drop (step - 1)).head?.bind (·.evals)).getD 0
                  say s!"pages agree; evaluations differ at step {step}: expected {expected} observed {observed}"
                  shown := shown + 1
              | .noButton step =>
                  pages := pages + 1
                  say s!"step {step} clicks a button the reference does not draw"
                  shown := shown + 1
            let t2 ← IO.monoNanosNow
            let parseMs := (t1 - t0) / 1000000
            let checkMs := (t2 - t1) / 1000000
            let total := (t2 - t0).toFloat / 1e9
            if pages + counts > 0 then failed := true
            IO.println s!"{file}: traces={traces.size} steps={steps} pageMismatch={pages} countMismatch={counts} parse={parseMs}ms check={checkMs}ms {(traces.size.toFloat / total).round} traces/s {(steps.toFloat / total).round} steps/s"
      return (if failed then 1 else 0)
  | _ =>
      IO.eprintln "usage: bridge gen <out> <bug> <lm> <cm> <auto> <seed0> <count> <steps>"
      IO.eprintln "       bridge vectors <out> <lm> <cm> <seed0> <count> <steps> <minSteps>"
      IO.eprintln "       bridge check <file>..."
      return 2
