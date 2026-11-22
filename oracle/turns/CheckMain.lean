/-
`lake exe check`: P1–P5 for the incremental algorithm against the reference,
over seeded random programs or every program within bounds, with or without
a seeded bug; `check gate` runs the fixed set the oracle task requires.
-/
import Turns
open Turns

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

def bugs : List (String × Bug) :=
  ["none", "twoPassInner", "twoPassOuter", "noJoinKeep", "noJoinClear", "perWrite", "rowReset",
    "rowResurrect", "noWalk", "underSig", "pruneWakes"].filterMap fun n => (parseBug n).map (n, ·)

structure Stats where
  cases : Nat := 0
  steps : Nat := 0
  evals : Nat := 0
  caught : Nat := 0
  first : Option Nat := none
  -- What fired at the first step of a case that broke anything: after it the
  -- instance and the reference have parted, and only what an outside oracle
  -- goes on seeing (below) still means something.
  perTag : Array Nat := Array.replicate Tag.all.length 0
  firstTag : Array (Option Nat) := Array.replicate Tag.all.length none
  -- Over the whole case:
  pageEver : Nat := 0       -- the page differs at some step
  pageFirst : Option Nat := none
  missPage : Nat := 0       -- caught, the page never differs
  missStream : Nat := 0     -- caught, neither the page nor the stream's shape ever differs
  missCounter : Nat := 0    -- caught, and the evaluation count always agrees too
  sample : Option String := none

def Stats.add (st : Stats) (primary ever steps evals : Nat) (p : Prog) : Stats := Id.run do
  let n := st.cases + 1
  let mut st := { st with cases := n, steps := st.steps + steps, evals := st.evals + evals }
  if ever = 0 then return st
  let has := fun (t : Tag) => ever &&& t.bit != 0
  let page := has .page || has .cmd
  st := { st with
    caught := st.caught + 1
    first := st.first.or (some n)
    sample := st.sample.or (some (blockSx p.body))
    pageEver := st.pageEver + (if page then 1 else 0)
    pageFirst := if page then st.pageFirst.or (some n) else st.pageFirst
    missPage := st.missPage + (if page then 0 else 1)
    missStream := st.missStream + (if page || has .shape then 0 else 1)
    missCounter := st.missCounter + (if page || has .shape || has .count then 0 else 1) }
  for (i, t) in (List.range Tag.all.length).zip Tag.all do
    if primary &&& t.bit != 0 then
      st := { st with perTag := st.perTag.modify i (· + 1), firstTag := st.firstTag.modify i (·.or (some n)) }
  return st

def Stats.line (st : Stats) : String :=
  let tags := " ".intercalate (((List.range Tag.all.length).zip Tag.all).map fun (i, t) =>
    s!"{t.name}={st.perTag[i]!}" ++ (match st.firstTag[i]! with | some n => s!"@{n}" | none => ""))
  s!"cases={st.cases} steps={st.steps} evals={st.evals} caught={st.caught}"
    ++ (match st.first with | some n => s!" first@{n}" | none => "")
    ++ s!" | at first broken step: {tags} | whole case: pageEver={st.pageEver}"
    ++ (match st.pageFirst with | some n => s!"@{n}" | none => "")
    ++ s!" missPage={st.missPage} missStream={st.missStream} missCounter={st.missCounter}"

/-- One random case: what broke at the first broken step, what broke at any
step, the steps taken and the evaluations made. -/
def runRandom (g : Cfg) (gp : GenP) (seed nsteps : Nat) : Prog × Nat × Nat × Nat × Nat := Id.run do
  let (p, _) := decode gp (randoms seed 256)
  let rs := randoms (seed + 1000003) nsteps
  let (sim0, v0) := mountSim g p
  let mut sim := sim0
  let mut primary := v0
  let mut ever := v0
  let mut steps := 0
  let mut evals := 0
  for r in rs do
    let buttons := buttonsOf (view p sim.w)
    if buttons.isEmpty then break
    let (sim', v, e) := checkStep g p sim (buttons.getD (r % buttons.length) [])
    sim := sim'
    if primary = 0 then primary := v
    ever := ever ||| v
    steps := steps + 1
    evals := evals + e
  return (p, primary, ever, steps, evals)

def randomStats (g : Cfg) (gp : GenP) (seed0 count nsteps : Nat) : Stats := Id.run do
  let mut st : Stats := {}
  for i in [0:count] do
    let (p, primary, ever, steps, evals) := runRandom g gp (seed0 + i) nsteps
    st := st.add primary ever steps evals p
  return st

/-- Every sequence of clicks of length `depth` from `sim`. -/
partial def explore (g : Cfg) (p : Prog) (sim : Sim) (depth : Nat) (acc : Nat × Nat × Nat × Nat) :
    Nat × Nat × Nat × Nat :=
  let buttons := buttonsOf (view p sim.w)
  if depth = 0 || buttons.isEmpty then (acc.1, acc.2.1, acc.2.2.1, acc.2.2.2 + 1)
  else buttons.foldl (fun (viol, steps, evals, seqs) ev =>
    let (sim', v, e) := checkStep g p sim ev
    explore g p sim' (depth - 1) (viol ||| v, steps + 1, evals + e, seqs)) acc

def exhaustiveStats (g : Cfg) (gp : GenP) (depth limit : Nat) : Stats × Nat := Id.run do
  let mut st : Stats := {}
  let mut digits : Array Nat := #[]
  let mut seqs := 0
  for _ in [0:limit] do
    let (p, radices) := decode gp digits
    let (sim, v0) := mountSim g p
    let (viol, steps, evals, s) := explore g p sim depth (v0, 0, 0, 0)
    st := st.add viol viol steps evals p
    seqs := seqs + s
    match nextDigits digits radices with
    | some d => digits := d
    | none => break
  return (st, seqs)

def nat (s : String) : Nat := s.toNat?.getD 0

/-- Hand-written programs, one for each gap the audit named, with the
clicks that expose it. -/
def scenarios : List (String × String × List Nat) := [
  ("G2-when: a `when` on two layers one event writes; local state inside the branch",
   "(state 0 (state 0 (when (= (L 0) (L 1)) ((state 0 (show (L 2)) (bump ((L 2) (+ (L 2) 1))))) ()) (bump ((L 0) (+ (L 0) 1)) ((L 1) (+ (L 1) 1)))))",
   [0, 1]),
  ("G2-each: an `each` list on two layers one event writes; local state in the row",
   "(state 1 (state 0 (each (+ (L 0) (L 1)) (state 0 (show (L 3)) (bump ((L 3) (+ (L 3) 1))))) (bump ((L 0) (+ (L 0) 1)) ((L 1) (+ (L 1) -1)))))",
   [0, 1]),
  ("G2-derive-outer: a `when` on an outer layer and a `derive` of an inner one",
   "(state 0 (state 0 (derive (L 1) (when (= (L 0) (L 2)) ((state 0 (show (L 3)) (bump ((L 3) (+ (L 3) 1))))) ())) (bump ((L 0) (+ (L 0) 1)) ((L 1) (+ (L 1) 1)))))",
   [0, 1]),
  ("G2-derive-inner: a `when` on an inner layer and a `derive` of an outer one",
   "(state 0 (derive (L 0) (state 0 (when (= (L 1) (L 2)) ((state 0 (show (L 3)) (bump ((L 3) (+ (L 3) 1))))) ()) (bump ((L 0) (+ (L 0) 1)) ((L 2) (+ (L 2) 1))))))",
   [0, 1]),
  ("G1-rows: a row kept across a list change, and a key removed and reinserted",
   "(state 1 (each (L 0) (state 0 (show (L 2)) (bump ((L 2) (+ (L 2) 1))))) (bump ((L 0) (+ (L 0) 1))))",
   [0, 1, 0, 2]),
  ("walk: an inner written layer the outer write's pass does not reach",
   "(state 0 (state 0 (show (L 1)) (bump ((L 0) (+ (L 0) 1)) ((L 1) (+ (L 1) 1)))))",
   [0]),
  ("G3-prune: a `derive` that recomputes equal, with a reader of it alone",
   "(state 0 (derive (% (L 0) 2) (show (L 1))) (bump ((L 0) (+ (L 0) 2))))",
   [0]),
  ("glitch: a reader of an outer layer and a `derive` of an inner one, both written",
   "(state 0 (state 0 (derive (L 1) (show (+ (L 0) (L 2)))) (bump ((L 0) (+ (L 0) 1)) ((L 1) (+ (L 1) 1)))))",
   [0])]

def tagsOf (v : Nat) : String :=
  if v = 0 then "-" else "+".intercalate ((Tag.all.filter fun t => v &&& t.bit != 0).map Tag.name)

def directed (α : Alpha) : IO Unit := do
  for (name, text, clicks) in scenarios do
    let some body := parseBody text | IO.eprintln s!"does not parse: {text}"
    let p : Prog := { cells := [0, 0], body }
    IO.println s!"{name}"
    IO.println s!"  prog{blockSx p.body}"
    let mut w := World.init p
    IO.println s!"  page {leavesTok (leavesOf p w)}"
    for k in clicks do
      let v := view p w
      let buttons := buttonsOf v
      let ev := buttons.getD (k % buttons.length) []
      let ws := match v.lookup ev with
        | some (.button ws) => ws
        | _ => []
      let w1 := (stepRef p w ev).getD w
      let due := ((expect α p w w1 ws).readers.filter (·.due)).length
      IO.println s!"  step {k % buttons.length} | {leavesTok (leavesOf p w1)} | {due}"
      w := w1
    for (bname, b) in bugs do
      let g : Cfg := { α, bug := b }
      let (sim0, v0) := mountSim g p
      let mut sim := sim0
      let mut out := [tagsOf v0]
      for k in clicks do
        let buttons := buttonsOf (view p sim.w)
        let (sim', v, _) := checkStep g p sim (buttons.getD (k % buttons.length) [])
        sim := sim'
        out := out ++ [tagsOf v]
      if b = .none || out.any (· ≠ "-") then IO.println s!"  {bname}: {" | ".intercalate out}"

def timed (act : Unit → α) : IO (α × Nat) := do
  let t0 ← IO.monoMsNow
  let x := act ()
  let t1 ← IO.monoMsNow
  return (x, t1 - t0)

/-- The fixed set `blueprint run oracle` runs. Every program within small
bounds, and seeded random programs at two signature abstractions, must
break no rule under the design's algorithm; every known-bad algorithm must
be caught by the seeded series; and the proof's model must agree with the
executable algorithm. Answers whether every line held. -/
def gate : IO Bool := do
  let mut ok := true
  let say := fun (good : Bool) (line : String) => IO.println s!"{if good then "ok  " else "FAIL"} {line}"
  let small : GenP := { auto := true, maxDepth := 3, maxLen := 2, fuel := 5, cells := 1, menu := 3,
                        kinds := 7, inits := 1, amounts := 1 }
  let (st, seqs) := exhaustiveStats {} small 2 20000
  ok := ok && st.caught == 0
  say (st.caught == 0) s!"exhaustive none depth=3 len=2 fuel=5 cells=1 menu=3 events=2: programs={st.cases} sequences={seqs} caught={st.caught}"
  for α in [Alpha.exact, ⟨2, 1⟩] do
    let st := randomStats { α } {} 1 20000 20
    ok := ok && st.caught == 0
    say (st.caught == 0) s!"random none alpha={α.lm},{α.cm}: cases={st.cases} steps={st.steps} caught={st.caught}"
  for (name, b) in bugs do
    if b ≠ .none then
      let st := randomStats { bug := b } {} 1 20000 20
      ok := ok && st.caught > 0
      say (st.caught > 0) s!"random {name}: cases={st.cases} caught={st.caught}{match st.first with | some n => s!" first@{n}" | none => ""}"
  let g : Cfg := { α := ⟨64, 64⟩ }
  let gp : GenP := { kinds := 4, maxDepth := 5, fuel := 16 }
  let mut checked := 0
  let mut differ := 0
  for i in [0:2000] do
    let (p, _) := decode gp (randoms (1 + i) 256)
    let mut sim := (mountSim g p).1
    for r in randoms (1 + i + 1000003) 20 do
      let buttons := buttonsOf (view p sim.w)
      if buttons.isEmpty then break
      let ev := buttons.getD (r % buttons.length) []
      if let some (same, _) := linkStep g p sim.s ev then
        checked := checked + 1
        if !same then differ := differ + 1
      sim := (checkStep g p sim ev).1
  ok := ok && differ == 0 && checked > 0
  say (differ == 0 && checked > 0) s!"link: programs=2000 turns={checked} differ={differ}"
  return ok

def main (args : List String) : IO UInt32 := do
  match args with
  | ["gate"] => return (if (← gate) then 0 else 1)
  | ["random", bug, lm, cm, auto, seed0, count, steps, depth, len, fuel] =>
      let some b := parseBug bug | IO.eprintln "unknown bug"; return 2
      let g : Cfg := { α := ⟨nat lm, nat cm⟩, bug := b }
      let gp : GenP := { auto := auto = "1", maxDepth := nat depth, maxLen := nat len, fuel := nat fuel }
      let t0 ← IO.monoMsNow
      let st := randomStats g gp (nat seed0) (nat count) (nat steps)
      IO.println s!"random bug={bug} alpha={lm},{cm} auto={auto} depth={depth} len={len} fuel={fuel}: {st.line}"
      let t1 ← IO.monoMsNow
      IO.println s!"  {t1 - t0} ms"
      if let some s := st.sample then IO.println s!"  first caught: prog{s}"
      return 0
  | ["link", lm, cm, seed0, count, steps] =>
      -- The proof's model against the executable algorithm, on static programs.
      let g : Cfg := { α := ⟨nat lm, nat cm⟩ }
      let gp : GenP := { kinds := 4, maxDepth := 5, fuel := 16 }
      let mut checked := 0
      let mut multi := 0
      let mut differ := 0
      let mut skipped := 0
      for i in [0:nat count] do
        let (p, _) := decode gp (randoms (nat seed0 + i) 256)
        let mut sim := (mountSim g p).1
        for r in randoms (nat seed0 + i + 1000003) (nat steps) do
          let buttons := buttonsOf (view p sim.w)
          if buttons.isEmpty then break
          let ev := buttons.getD (r % buttons.length) []
          match linkStep g p sim.s ev with
          | some (same, many) =>
              checked := checked + 1
              if many then multi := multi + 1
              if !same then differ := differ + 1
          | none => skipped := skipped + 1
          sim := (checkStep g p sim ev).1
      IO.println s!"link alpha={lm},{cm}: programs={count} turns={checked} twoWrites={multi} differ={differ} skipped={skipped}"
      return 0
  | ["directed", lm, cm] =>
      directed ⟨nat lm, nat cm⟩
      return 0
  | ["table", auto, count, steps] =>
      let gp : GenP := { auto := auto = "1" }
      for (name, b) in bugs do
        for α in [Alpha.exact, ⟨2, 1⟩] do
          let t0 ← IO.monoMsNow
          let st := randomStats { α, bug := b } gp 1 (nat count) (nat steps)
          IO.println s!"{name} alpha={α.lm},{α.cm}: {st.line}"
          let t1 ← IO.monoMsNow
          IO.println s!"  {t1 - t0} ms"
      return 0
  | ["exhaustive", bug, lm, cm, auto, depth, len, fuel, cells, menu, kinds, evdepth, limit] =>
      let some b := parseBug bug | IO.eprintln "unknown bug"; return 2
      let g : Cfg := { α := ⟨nat lm, nat cm⟩, bug := b }
      let gp : GenP := { auto := auto = "1", maxDepth := nat depth, maxLen := nat len, fuel := nat fuel,
                         cells := nat cells, menu := nat menu, kinds := nat kinds, inits := 1, amounts := 1 }
      let t0 ← IO.monoMsNow
      let (st, seqs) := exhaustiveStats g gp (nat evdepth) (nat limit)
      IO.println s!"exhaustive bug={bug} alpha={lm},{cm} auto={auto} depth={depth} len={len} fuel={fuel} cells={cells} menu={menu} kinds={kinds} events={evdepth}: programs={st.cases} sequences={seqs} {st.line}"
      let t1 ← IO.monoMsNow
      IO.println s!"  {t1 - t0} ms"
      if let some s := st.sample then IO.println s!"  first caught: prog{s}"
      return 0
  | _ =>
      IO.eprintln "usage: check random <bug> <lm> <cm> <auto> <seed0> <count> <steps> <depth> <len> <fuel>"
      IO.eprintln "       check table <auto> <count> <steps>"
      IO.eprintln "       check exhaustive <bug> <lm> <cm> <auto> <depth> <len> <fuel> <cells> <menu> <kinds> <events> <limit>"
      return 2
