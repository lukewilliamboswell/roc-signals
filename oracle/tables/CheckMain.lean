/-
Bounded exhaustive checking: a breadth-first search over every state a table
cell (and one table view site) can reach in a bounded number of turns, over a
tiny universe of keys and rows, with every named rule checked at every state.
-/
import Tables
import Std.Data.HashSet
open Tables

inductive Ck where
  -- the turn boundary (invariant 20, design.md:950-961)
  | clearedAtBegin | beginIdempotent | startsMonotone | rearmed | finishKeepsChanges
  -- the cell after each modifier (invariants 19, 23, T5 and its unstated facts)
  | phaseWriting | idKept | startIsEpoch | versionGeStart | opAddsOne
  | recordSound | recordCovers | inverseRestores | recordDistinct | recordExact
  | verEqStartMeansUnchanged | rewrittenVerGtStart
  -- the view site (invariants 21, 22, T6, T7)
  | noCrash | neverBehind | seqIsScratch | keysAreSpec | viewVersion | shownIsWindow
  | drawnIsWindow | enteredExact | leftExact | keptNotRecreated | movedOnlyKept
  | movesMinimal | changedExact | placedBound
  -- witnesses: reachability, not rules (a count of hits)
  | wVersionDecreased | wCopyAcceptedAsOwn | wStoredRewritten | wAbsorbed | wRebuiltMany
  | wRebuiltRewritten | wUnchangedAfterWrite | wMoved
  deriving Repr, DecidableEq, Inhabited

def Ck.all : Array Ck := #[.clearedAtBegin, .beginIdempotent, .startsMonotone, .rearmed,
  .finishKeepsChanges, .phaseWriting, .idKept, .startIsEpoch, .versionGeStart, .opAddsOne,
  .recordSound, .recordCovers, .inverseRestores, .recordDistinct, .recordExact,
  .verEqStartMeansUnchanged, .rewrittenVerGtStart, .noCrash, .neverBehind, .seqIsScratch,
  .keysAreSpec, .viewVersion, .shownIsWindow, .drawnIsWindow, .enteredExact, .leftExact,
  .keptNotRecreated, .movedOnlyKept, .movesMinimal, .changedExact, .placedBound,
  .wVersionDecreased, .wCopyAcceptedAsOwn, .wStoredRewritten, .wAbsorbed, .wRebuiltMany,
  .wRebuiltRewritten, .wUnchangedAfterWrite, .wMoved]

def Ck.idx (c : Ck) : Nat := (Ck.all.idxOf? c).getD 0

structure Ctr where
  n : Nat := 0
  bad : Nat := 0
  firstAt : Nat := 0      -- transitions explored when it first failed
  first : String := ""
  deriving Inhabited

structure Scope where
  bug : Bug := .none
  nk : Nat := 2
  nv : Nat := 2
  turns : Nat := 3
  mods : Nat := 2
  ops : Nat := 1
  maxSaved : Nat := 1
  site : Bool := true
  branching : Bool := false
  saveMid : Bool := false
  cfg : Cfg := {}
  queries : List Nat := [0, 1, 2]
  cap : Nat := 4000000

def cellId : Nat := 5

structure St where
  cell : Table
  saved : List Table
  site : Option Site
  deriving DecidableEq, Hashable

structure Mid where
  cell : Table
  saved : List Table
  E : Rows
  s0 : Nat
  wrote : Bool
  pure : Bool
  keys : List K
  deriving DecidableEq, Hashable

structure Run where
  stats : IO.Ref (Array Ctr)
  trans : IO.Ref Nat

def Run.chk (r : Run) (c : Ck) (ok : Bool) (trace : Unit → String) : IO Unit := do
  let i := c.idx
  let t ← r.trans.get
  r.stats.modify fun a =>
    let x := a[i]!
    a.set! i (if ok then { x with n := x.n + 1 }
      else if x.bad == 0 then { n := x.n + 1, bad := 1, firstAt := t, first := trace () }
      else { x with n := x.n + 1, bad := x.bad + 1 })

/-- A witness counts hits in `bad` and keeps the first trace. -/
def Run.wit (r : Run) (c : Ck) (hit : Bool) (trace : Unit → String) : IO Unit :=
  r.chk c (!hit) trace

def insSorted (k : K) : List K → List K
  | [] => [k]
  | x :: xs => if k = x then x :: xs else if k < x then k :: x :: xs else x :: insSorted k xs

def sortKeys (ks : List K) : List K := ks.foldl (fun acc k => insSorted k acc) []

def showTable (t : Table) : String :=
  s!"rows={t.rows} record={repr t.record} whole={repr t.whole} v={t.version} start={t.start} id={t.id} {repr t.phase}"

def singleOps (sc : Scope) : List Op := Id.run do
  let mut out : List Op := []
  for k in [0:sc.nk] do
    for v in [0:sc.nv] do
      out := out ++ [.insert k v, .put k v, .replace k v]
    out := out ++ [.update k, .remove k]
  return out ++ [.updateAll, .undo]

def opSeqs (sc : Scope) (n : Nat) : List (List Op) := Id.run do
  let singles := singleOps sc
  let mut level : List (List Op) := [[]]
  let mut out : List (List Op) := [[]]
  for _ in [0:n] do
    level := level.flatMap fun os => singles.map fun o => os ++ [o]
    out := out ++ level
  return out

def freshRows (sc : Scope) : List Rows :=
  [[], [(0, 0)]] ++ (if sc.nk ≥ 2 && sc.nv ≥ 2 then [[(0, 1), (1, 0)]] else [])

def fns (sc : Scope) (nSaved : Nat) : List Fn := Id.run do
  let mut out : List Fn := (opSeqs sc sc.ops).map Fn.onArg
  let short := opSeqs sc 1
  for i in [0:nSaved] do
    out := out ++ short.map (Fn.saved i)
    out := out ++ [Fn.other i []]
  return out ++ (freshRows sc).map Fn.fresh

def windows (sc : Scope) : List Window :=
  [{ start := 0, count := 1 }, { start := 1, count := 2 }, { start := 0, count := 2 },
   { start := 0, count := 1000 }] ++
  (if sc.nk ≥ 3 then [{ start := 1, count := 1 }] else [])

def allKeys (sc : Scope) : List K := List.range sc.nk

/-- The rules a table cell must keep after every modifier of a turn. -/
def midChecks (r : Run) (sc : Scope) (m : Mid) (tr : Unit → String) : IO Unit := do
  let c := m.cell
  let say := fun (_ : Unit) => tr () ++ "\n   => " ++ showTable c ++ s!"\n   turn began with rows={m.E}"
  r.chk .phaseWriting (c.phase == .writing) say
  r.chk .idKept (c.id == cellId) say
  r.chk .startIsEpoch (c.start == m.s0) say
  r.chk .versionGeStart (c.version ≥ c.start) say
  r.chk .recordDistinct ((c.record.map (·.1)).eraseDups.length == c.record.length) say
  r.chk .verEqStartMeansUnchanged
    (c.version != c.start || (c.rows == m.E && c.record == [] && c.whole == .keyed)) say
  match c.whole with
  | .rewritten =>
    r.chk .rewrittenVerGtStart (c.version > c.start) say
    r.wit .wStoredRewritten true say
  | .keyed =>
    r.chk .recordSound (recordSound m.E c) say
    r.chk .recordCovers (recordCovers (allKeys sc) m.E c) say
    r.chk .inverseRestores (inverseRestores m.E c) say
    if m.pure then
      r.chk .recordExact (sortKeys (c.record.map (·.1)) == m.keys) say

def fnPure : Fn → Bool
  | .onArg os => os.all fun o => o != .updateAll && o != .undo
  | _ => false

/-- One modifier of the cell (Core.roc:427-435), with its checks. -/
def stepMod (r : Run) (sc : Scope) (m : Mid) (fn : Fn) (tr : Unit → String) : IO Mid := do
  r.trans.modify (· + 1)
  let began := beginChanges sc.bug m.cell
  let say := fun (_ : Unit) => tr () ++ "\n   began: " ++ showTable began
  if !m.wrote then
    r.chk .clearedAtBegin (began.record == [] && began.whole == .keyed
      && began.start == began.version && began.phase == .writing) say
    r.chk .startsMonotone (began.start ≥ m.cell.start) say
  else
    r.chk .beginIdempotent (began == m.cell) say
  -- each single operation adds exactly one to the count when it writes
  match fn with
  | .onArg [op] =>
    match op.writes began with
    | some w => r.chk .opAddsOne ((op.run sc.bug sc.nv began).version == began.version + (if w then 1 else 0)) say
    | none => pure ()
  | _ => pure ()
  let out := fn.run sc.bug sc.nv m.saved began
  let res := kept sc.bug out (mark began)
  let own := out.id == began.id && out.start == began.start && out.phase == .writing
  let E := if m.wrote then m.E else began.rows
  let s0 := if m.wrote then m.s0 else began.version
  -- keys written by a plain sequence of keyed operations
  let keys := match fn with
    | .onArg os => (os.foldl (fun (acc : Table × List K) o =>
        let t := acc.1
        let ks := match o.key, o.writes t with
          | some k, some true => insSorted k acc.2
          | _, _ => acc.2
        (o.run .none sc.nv t, ks)) (began, m.keys)).2
    | _ => m.keys
  let m' : Mid := { cell := res, saved := m.saved, E, s0, wrote := true,
                    pure := m.pure && fnPure fn, keys }
  let say' := fun (_ : Unit) => tr () ++ "\n   began: " ++ showTable began
  r.wit .wVersionDecreased (res.version < m.cell.version) say'
  match fn with
  | .saved _ _ => r.wit .wCopyAcceptedAsOwn own fun _ => say' () ++ "\n   => " ++ showTable res
  | _ => pure ()
  midChecks r sc m' tr
  return m'

def setEq (a b : List K) : Bool := sortKeys a == sortKeys b

/-- The rules a table view site must keep after its `Changed`. -/
def siteStep (r : Run) (sc : Scope) (site : Site) (cell : Table) (wrote : Bool)
    (askQ : Option Nat) (askW : Option Window) (tr : Unit → String) : IO (Option Site) := do
  let say := fun (_ : Unit) => tr () ++ s!"\n   table: {showTable cell}\n   site before: q={site.q} window=({site.view.window.start},{site.view.window.count}) drawn={site.drawn} view.version={site.view.version}"
  match Site.changed sc.bug sc.cfg site cell askQ askW with
  | .error e =>
    r.chk .noCrash false fun _ => say () ++ "\n   crash: " ++ e
    return none
  | .ok (site', changes, how, placed) =>
    let say' := fun (_ : Unit) => say () ++ s!"\n   changes={repr changes} how={repr how}\n   site after: drawn={site'.drawn} keys={site'.view.seq.map (·.2)} view.version={site'.view.version}"
    r.chk .noCrash true say'
    r.chk .neverBehind (how != .rebuiltBehind) say'
    r.wit .wAbsorbed (how == .absorbed) say'
    r.wit .wRebuiltMany (how == .rebuiltMany) say'
    r.wit .wRebuiltRewritten (how == .rebuiltRewritten) say'
    r.wit .wUnchangedAfterWrite (how == .unchanged && wrote) say'
    let q2 := site'.q
    let w2 := site'.view.window
    let specK := specKeys q2 cell.rows
    let specW := specWindow specK w2
    r.chk .seqIsScratch (match scratch (plan q2) cell with
      | .ok s => s == site'.view.seq
      | .error _ => false) say'
    r.chk .keysAreSpec (site'.view.seq.map (·.2) == specK) say'
    r.chk .viewVersion (site'.view.version == cell.version && site'.view.q == q2
      && q2 == askQ.getD site.q && w2 == askW.getD site.view.window) say'
    r.chk .shownIsWindow (site'.view.shown.map (·.2) == specW) say'
    r.chk .drawnIsWindow (site'.drawn == specW) say'
    let before := site.drawn
    let entered := changes.filterMap fun | .entered k _ => some k | _ => none
    let left := changes.filterMap fun | .left k => some k | _ => none
    let moved := changes.filterMap fun | .moved k _ => some k | _ => none
    let changed := changes.filterMap fun | .changed k => some k | _ => none
    let both := before.filter specW.contains
    r.chk .enteredExact (setEq entered (specW.filter (!before.contains ·))
      && entered.eraseDups.length == entered.length) say'
    r.chk .leftExact (setEq left (before.filter (!specW.contains ·))
      && left.eraseDups.length == left.length) say'
    r.chk .keptNotRecreated (both.all fun k => !entered.contains k && !left.contains k) say'
    r.chk .movedOnlyKept (moved.all both.contains) say'
    let positions := both.map fun k => (specW.idxOf? k).getD 0
    r.chk .movesMinimal (moved.length == both.length - lisLength positions) say'
    r.wit .wMoved (moved.length > 0) say'
    let written := fun (k : K) => wrote && (cell.whole == .rewritten || (cget cell.record k).isSome)
    r.chk .changedExact (setEq changed (both.filter written)) say'
    r.chk .placedBound (how != .absorbed || placed ≤ 2 * cell.record.length) say'
    return some site'

/-- Explore every state within `sc`, check every rule, print the result,
and answer the names of the rules that failed. -/
partial def explore (sc : Scope) (verbose : Bool := true) : IO (List String) := do
  -- A `writing` table exists only inside one turn of one history: a pure
  -- `Store` hands its writes closures built before the turn, so no copy
  -- saved mid-turn reaches another history. Branching with mid-turn copies
  -- explores histories no program has.
  if sc.branching && sc.saveMid then
    throw (IO.userError "explore: branching histories take up only copies kept between turns (saveMid must be 0)")
  let r : Run := { stats := ← IO.mkRef (Array.replicate Ck.all.size {}), trans := ← IO.mkRef 0 }
  let t0 ← IO.monoMsNow
  let mut visited : Std.HashSet St := {}
  let mut frontier : Array (St × List String) := #[]
  let roots : List Rows := [[], [(0, 0)], [(0, 1), (1, 0)]]
  for rows in roots do
    let cell := cellStart rows cellId
    let sites : List (Option Site) :=
      if sc.site then
        (sc.queries.take 1).flatMap fun q => (windows sc).filterMap fun w =>
          match Site.mount cell q w with
          | .ok s => some (some s)
          | .error _ => none
      else [none]
    for site in sites do
      let st : St := { cell, saved := [], site }
      if !visited.contains st then
        visited := visited.insert st
        frontier := frontier.push (st, [s!"start rows={rows}" ++ (match site with
          | some s => s!" q={s.q} window=({s.view.window.start},{s.view.window.count})"
          | none => "")])
  let fnTable := (List.range (sc.maxSaved + 1)).map fun n => fns sc n
  let mut stopped := false
  for turn in [0:sc.turns] do
    if stopped then break
    let mut next : Array (St × List String) := #[]
    for (st, tr) in frontier do
      if visited.size > sc.cap then
        stopped := true
        break
      -- a pure `Store` value can be taken up again: the cell goes back to a kept snapshot
      let bases : List (Table × String) := [(st.cell, "")] ++
        (if sc.branching then
          (st.saved.zipIdx.filter fun (t, _) => t.phase == .ready).map fun (t, i) => (t, s!"take up snapshot saved{i}; ")
        else [])
      for (base, baseNote) in bases do
        let m0 : Mid := { cell := base, saved := st.saved, E := base.rows, s0 := base.version,
                          wrote := false, pure := true, keys := [] }
        let mut level : Array (Mid × List String) := #[(m0, [])]
        let mut ends : Array (Mid × List String) := #[(m0, [])]
        let mut seen : Std.HashSet Mid := {}
        for _ in [0:sc.mods] do
          let mut nxt : Array (Mid × List String) := #[]
          for (m, mtr) in level do
            for fn in fnTable[m.saved.length]! do
              let mtr' := mtr ++ [fn.show]
              let say := fun (_ : Unit) =>
                "\n   ".intercalate (tr.reverse ++ [s!"turn {turn + 1}: {baseNote}" ++ "; ".intercalate mtr'])
              let m' ← stepMod r sc m fn say
              let variants : List Mid := [m'] ++
                (if sc.saveMid && m'.saved.length < sc.maxSaved && !m'.saved.contains m'.cell
                 then [{ m' with saved := m'.saved ++ [m'.cell] }] else [])
              for v in variants do
                if !seen.contains v then
                  seen := seen.insert v
                  let note := if v.saved.length > m'.saved.length then mtr' ++ ["(copy kept mid-turn)"] else mtr'
                  nxt := nxt.push (v, note)
          level := nxt
          ends := ends ++ nxt
        for (m, mtr) in ends do
          let cell' := if m.wrote then finishChanges m.cell else m.cell
          let line := s!"turn {turn + 1}: {baseNote}" ++ "; ".intercalate mtr
          let say := fun (_ : Unit) => "\n   ".intercalate (tr.reverse ++ [line])
          if m.wrote then
            r.chk .rearmed (cell'.phase == .ready) say
            r.chk .finishKeepsChanges (cell'.record == m.cell.record && cell'.whole == m.cell.whole
              && cell'.rows == m.cell.rows && cell'.version == m.cell.version && cell'.start == m.cell.start) say
          let asks : List (Option Nat × Option Window) :=
            match st.site with
            | none => [(none, none)]
            | some s =>
              let qs : List (Option Nat) := [none, some s.q] ++ (sc.queries.filter (· != s.q)).map some
              let ws : List (Option Window) := [none] ++ ((windows sc).filter (· != s.view.window)).map some
              qs.flatMap fun q => ws.map fun w => (q, w)
          for (askQ, askW) in asks do
            let reached := m.wrote || askQ.isSome || askW.isSome
            let line' := line ++ (match askQ with | some q => s!" ; query:={q}" | none => "")
              ++ (match askW with | some w => s!" ; window:=({w.start},{w.count})" | none => "")
            let say' := fun (_ : Unit) => "\n   ".intercalate (tr.reverse ++ [line'])
            let site' ← match st.site with
              | some s => if reached then siteStep r sc s cell' m.wrote askQ askW say' else pure (some s)
              | none => pure none
            if st.site.isSome && site'.isNone then continue
            let savedChoices : List (List Table) := [m.saved] ++
              (if m.saved.length < sc.maxSaved && !m.saved.contains cell' then [m.saved ++ [cell']] else [])
            for sv in savedChoices do
              let st' : St := { cell := cell', saved := sv, site := site' }
              if !visited.contains st' then
                visited := visited.insert st'
                next := next.push (st', (line' ++ (if sv.length > m.saved.length then " ; (copy kept)" else "")) :: tr)
    if verbose then IO.println s!"turn {turn + 1}: frontier {frontier.size} -> new states {next.size}, total {visited.size}, transitions {← r.trans.get}"
    frontier := next
  let t1 ← IO.monoMsNow
  IO.println s!"bug={repr sc.bug} keys={sc.nk} rows={sc.nv} turns={sc.turns} mods={sc.mods} ops={sc.ops} saved={sc.maxSaved} site={sc.site} branching={sc.branching} saveMid={sc.saveMid} ratio={sc.cfg.ratio} floor={sc.cfg.floor} queries={sc.queries}"
  IO.println s!"states={visited.size} modifier-applications={← r.trans.get} time={t1 - t0}ms{if stopped then " (stopped at the state cap)" else ""}"
  let stats ← r.stats.get
  let mut failed := 0
  for c in Ck.all do
    let x := stats[c.idx]!
    let name := (reprStr c).replace "Ck." ""
    if name.startsWith "w" then
      IO.println s!"  witness {name}: {x.bad} of {x.n}"
    else
      IO.println s!"  {if x.bad == 0 then "ok  " else "FAIL"} {name}: {x.n} checked, {x.bad} failed{if x.bad > 0 then s!" (first at application {x.firstAt})" else ""}"
      if x.bad > 0 then failed := failed + 1
  IO.println s!"rules failed: {failed}"
  let mut names : List String := []
  for c in Ck.all do
    let x := stats[c.idx]!
    let name := (reprStr c).replace "Ck." ""
    if x.bad > 0 && !name.startsWith "w" then
      names := names ++ [name]
      if verbose then IO.println s!"--- first {name}:\n   {x.first}"
  return names

def parseBug : String → Bug
  | "latestRow" => .latestRow | "noClear" => .noClear | "staleOk" => .staleOk
  | "idOk" => .idOk | "twoDraws" => .twoDraws | "noReach" => .noReach
  | "noPhase" => .noPhase | _ => .none

/-- The design's tie between keyed writes (design.md:862-866): a plan whose
sort value does not include the key, and two rows that trade places. -/
def tie : IO Unit := do
  let cell := cellStart [(0, 1), (1, 2)] cellId
  match Site.mount cell 3 { start := 0, count := 10 } with
  | .error e => IO.println s!"mount: {e}"
  | .ok site =>
    let t := cellModify .none cell fun t => (t.put .none 0 2).put .none 1 1
    let res := Site.changed .none {} site (finishChanges t) none none
    IO.println s!"rows before {cell.rows}, after {t.rows} (distinct sort values before and after)"
    match res with
    | .error e => IO.println s!"absorb: crash: {e}"
    | .ok (s, _, how, _) => IO.println s!"absorb: ok {repr how} drawn={s.drawn}"

/-- The fixed set `blueprint run oracle` runs, each scope with the rules it
is expected to fail. Every scope is one the exploration of the table's
changes used. Over the branching histories of a pure `Store` value two
histories share the cell's identity and can reach one count with different
rows; `kept` takes only a table still recording as the cell's own (design
decision D7), so no rule fails. The seeded `noPhase`, which judges by the
identity and the count alone, must still fail four. -/
def gates : List (String × Scope × List String) := [
  ("view, 2 keys, 2 rows, 2 turns", { turns := 2 }, []),
  ("view, rebuilt for many changes", { turns := 2, cfg := { ratio := 1, floor := 0 } }, []),
  ("view, 3 turns, no copies", { turns := 3, maxSaved := 0 }, []),
  ("branching histories, 3 turns", { turns := 3, maxSaved := 2, site := false, branching := true }, []),
  ("branching histories, 5 turns", { turns := 5, mods := 1, maxSaved := 2, site := false, branching := true }, []),
  ("branching histories, 5 turns, kept without the phase", { bug := .noPhase, turns := 5, mods := 1, maxSaved := 2, site := false, branching := true },
    ["recordSound", "recordCovers", "inverseRestores", "verEqStartMeansUnchanged"])]

def gate : IO Bool := do
  let mut ok := true
  for (name, sc, expected) in gates do
    IO.println s!"== {name}"
    let failed ← explore sc false
    let good := failed == expected
    ok := ok && good
    IO.println s!"{if good then "ok  " else "FAIL"} {name}: failed [{", ".intercalate failed}], expected [{", ".intercalate expected}]"
  return ok

def main (args : List String) : IO UInt32 := do
  match args with
  | ["tie"] => do tie; return 0
  | ["gate"] => return (if (← gate) then 0 else 1)
  | "explore" :: bug :: nk :: nv :: turns :: mods :: ops :: saved :: site :: branching :: saveMid :: ratio :: floor :: rest =>
    let sc : Scope :=
      { bug := parseBug bug, nk := nk.toNat!, nv := nv.toNat!, turns := turns.toNat!,
        mods := mods.toNat!, ops := ops.toNat!, maxSaved := saved.toNat!,
        site := site == "1", branching := branching == "1", saveMid := saveMid == "1",
        cfg := { ratio := ratio.toNat!, floor := floor.toNat! },
        cap := (rest.head?.map String.toNat!).getD 4000000 }
    let _ ← explore sc
    return 0
  | _ =>
    IO.println "usage: check explore <bug> <keys> <rows> <turns> <mods> <ops> <saved> <site> <branching> <saveMid> <ratio> <floor> [cap] | tie | gate"
    return 2
