/-
The abstract incremental algorithm, after design.md "Propagation: Turns,
Ordering, and Pruning": a mounted tree of sites that own their storage, one
`Changed` pass per turn from the outermost write under abstracted
signatures, waiting and joining, `derive` before what is below it, equality
pruning, the walk down the event's path, and reconciliation of branches and
rows. Its output is patch commands and a log of every evaluation.

Trusted for nothing: this is the algorithm under test, not a reference.
`Bug.none` follows the design; every other `Bug` is a known-bad algorithm,
a deliberate defect the checks and the vectors are measured against.
-/
import Turns.Spec
namespace Turns

inductive Bug where
  | none
  | twoPassInner    -- (a) a pass per written thing, innermost first
  | twoPassOuter    -- (a) a pass per written thing, outermost first
  | noJoinKeep      -- (b) a waiting layer the pass reaches does not join; the walk refreshes it
  | noJoinClear     -- (b) a waiting layer the pass reaches does not join and stops waiting
  | perWrite        -- (c) each write of an event is settled before the next is applied
  | rowReset        -- (d) a list change rebuilds the rows it keeps
  | rowResurrect    -- (d) a key that returns finds its old local state
  | noWalk          -- (e) no walk after the pass
  | underSig        -- (f) a reader's signature keeps only its first read
  | pruneWakes      -- (g) an equal `derive` still adds its bit
  deriving DecidableEq, Repr, Inhabited

structure Cfg where
  α : Alpha := Alpha.exact
  bug : Bug := .none

/-- The signature of a reader of `rs`. -/
def Cfg.sigOf (g : Cfg) (rs : List Ref) : Mask :=
  g.α.sig (if g.bug = .underSig then rs.take 1 else rs)

/-- A reader's own signature. -/
def Cfg.sig (g : Cfg) (e : Expr) : Mask := g.sigOf e.reads

/-- A mounted site and its storage, parallel to its `Node`. -/
inductive Inst where
  | hole (last : Val)
  | holes (last : List Val)
  | button
  | state (v : Val) (waiting : Bool) (kids : List Inst)
  | derive (v : Val) (kids : List Inst)
  | branch (cur : Nat) (kids : List Inst)
  | rows (rs : List (Val × List Inst))

instance : Inhabited Inst := ⟨.button⟩

/-- The page model the commands patch. -/
inductive Dom where
  | text (v : Val)
  | texts (vs : List Val)
  | button (writes : Nat)
  | box (kids : List Dom)
  | branch (cur : Option Nat) (kids : List Dom)
  | rows (rs : List (Val × List Dom))

instance : Inhabited Dom := ⟨.button 0⟩

inductive Cmd where
  | setText (id : Ident) (v : Val)
  | setTexts (id : Ident) (vs : List Val)
  | remove (id : Ident)                   -- a branch (`… b k`) or a row (`… r k`)
  | create (id : Ident) (frag : List Dom)
  | order (id : Ident) (keys : List Val)  -- the rows of an `each` site, in order

/-- A turn's accumulator. `dead` is used by `rowResurrect` alone. -/
structure Tx where
  cmds : Array Cmd := #[]
  log : Array (Ident × Env) := #[]
  dead : Rho := []

abbrev M := StateM Tx

def emit (c : Cmd) : M Unit := modify fun t => { t with cmds := t.cmds.push c }

/-- Every evaluation of app code goes through here and is logged with the
environment it saw. -/
def evalAt (id : Ident) (env : Env) (e : Expr) : M Val := do
  modify fun t => { t with log := t.log.push (id, env) }
  pure (e.eval env.get)

/-- One evaluation of a `joined` hole: one entry in the log, as one hole. -/
def evalAllAt (id : Ident) (env : Env) (es : List Expr) : M (List Val) := do
  modify fun t => { t with log := t.log.push (id, env) }
  pure (es.map (·.eval env.get))

def indexed (xs : List α) : List (Nat × α) := (List.range xs.length).zip xs

def Node.cases? : Node → Option (Expr × (Val → Nat) × List (List Node))
  | .when sel yes no => some (sel, fun v => if v ≠ 0 then 0 else 1, [yes, no])
  | .switch sel a b c => some (sel, fun v => min (v % 3).toNat 2, [a, b, c])
  | _ => none

mutual
/-- The local state a mounted block holds, by identity. -/
partial def instRho (id : Ident) (is : List Inst) : Rho :=
  (indexed is).flatMap fun (i, x) => instRho1 (id ++ [.c i]) x
partial def instRho1 (id : Ident) : Inst → Rho
  | .state v _ kids => (id, v) :: instRho id kids
  | .derive _ kids => instRho id kids
  | .branch cur kids => instRho (id ++ [.b cur]) kids
  | .rows rs => rs.flatMap fun (k, is) => instRho (id ++ [.r k]) is
  | _ => []
end

mutual
partial def mountNode (g : Cfg) (env : Env) (id : Ident) (n : Node) : M (Inst × Dom) := do
  match n with
  | .show e => let v ← evalAt id env e; pure (.hole v, .text v)
  | .joined es => let vs ← evalAllAt id env es; pure (.holes vs, .texts vs)
  | .bump h => pure (.button, .button h.length)
  | .state init body =>
      let dead := (← get).dead
      let v := if g.bug = .rowResurrect then (dead.lookup id).getD init else init
      let (is, ds) ← mountBlock g (env.push v) id body
      pure (.state v false is, .box ds)
  | .derive e body =>
      let v ← evalAt id env e
      let (is, ds) ← mountBlock g (env.push v) id body
      pure (.derive v is, .box ds)
  | .each src body =>
      let ks := keysOf (← evalAt id env src)
      let rows ← ks.mapM fun k => do
        let (is, ds) ← mountBlock g (env.push k) (id ++ [.r k]) body
        pure ((k, is), (k, ds))
      pure (.rows (rows.map (·.1)), .rows (rows.map (·.2)))
  | n =>
      match n.cases? with
      | none => pure (.button, .button 0)
      | some (sel, idx, cases) =>
          let k := idx (← evalAt id env sel)
          let (is, ds) ← mountBlock g env (id ++ [.b k]) (cases.getD k [])
          pure (.branch k is, .branch (some k) ds)
partial def mountBlock (g : Cfg) (env : Env) (id : Ident) (ns : List Node) : M (List Inst × List Dom) := do
  let out ← (indexed ns).mapM fun (i, n) => mountNode g env (id ++ [.c i]) n
  pure (out.map (·.1), out.map (·.2))
end

mutual
/-- `Changed(m)` at one site. `all` is the settle check's pass, which names
everything. The caller has already tested the site's static reads. -/
partial def refreshNode (g : Cfg) (all : Bool) (m : Mask) (env : Env) (id : Ident) (n : Node) (x : Inst) :
    M Inst := do
  let woke := fun (e : Expr) => all || hit (g.sig e) m
  let bit := g.α.mask (.layer env.depth)
  match n, x with
  | .show e, .hole last =>
      if woke e then
        let v ← evalAt id env e
        if v ≠ last then emit (.setText id v)
        pure (.hole v)
      else pure x
  | .joined es, .holes last =>
      if all || hit (g.sigOf (es.flatMap Expr.reads)) m then
        let vs ← evalAllAt id env es
        if vs ≠ last then emit (.setTexts id vs)
        pure (.holes vs)
      else pure x
  | .state _ body, .state v w kids =>
      -- A waiting layer joins the pass here: its bit, for its own subtree.
      let join := w && g.bug ≠ .noJoinKeep && g.bug ≠ .noJoinClear
      let kids ← refreshBlock g all (if join then m ||| bit else m) (env.push v) id body kids
      pure (.state v (w && g.bug = .noJoinKeep) kids)
  | .derive e body, .derive v kids =>
      if woke e then
        -- Recomputed before anything below reads it; equal stops its bit.
        let v2 ← evalAt id env e
        let m' := if v2 ≠ v || g.bug = .pruneWakes then m ||| bit else m
        pure (.derive v2 (← refreshBlock g all m' (env.push v2) id body kids))
      else pure (.derive v (← refreshBlock g all m (env.push v) id body kids))
  | .each src body, .rows rs =>
      let rowDue := all || hit (g.α.sig (readsBlock body)) m
      let keep := fun (k : Val) (is : List Inst) =>
        if rowDue then refreshBlock g all m (env.push k) (id ++ [.r k]) body is else pure is
      let ks ← if woke src then pure (keysOf (← evalAt id env src)) else pure (rs.map (·.1))
      if ks == rs.map (·.1) then
        pure (.rows (← rs.mapM fun (k, is) => do pure (k, ← keep k is)))
      else
        -- One change of the rows: a kept key keeps its row, a new key is
        -- created once, a removed key is disposed.
        let reset := g.bug = .rowReset
        for (k, is) in rs do
          if reset || !ks.contains k then
            emit (.remove (id ++ [.r k]))
            if g.bug = .rowResurrect then
              modify fun t => { t with dead := instRho (id ++ [.r k]) is ++ t.dead }
        let rows ← ks.mapM fun k => do
          match (if reset then none else rs.lookup k) with
          | some is => pure (k, ← keep k is)
          | none =>
              let (is, ds) ← mountBlock g (env.push k) (id ++ [.r k]) body
              emit (.create (id ++ [.r k]) ds)
              pure (k, is)
        emit (.order id ks)
        pure (.rows rows)
  | n, .branch cur kids =>
      match n.cases? with
      | none => pure x
      | some (sel, idx, cases) =>
          let k ← if woke sel then pure (idx (← evalAt id env sel)) else pure cur
          if k = cur then
            pure (.branch cur (← refreshBlock g all m env (id ++ [.b cur]) (cases.getD cur []) kids))
          else
            -- The branch decision comes before the branch's holes.
            emit (.remove (id ++ [.b cur]))
            let (is, ds) ← mountBlock g env (id ++ [.b k]) (cases.getD k [])
            emit (.create (id ++ [.b k]) ds)
            pure (.branch k is)
  | _, _ => pure x
/-- A block refreshes the children whose static reads meet the mask. -/
partial def refreshBlock (g : Cfg) (all : Bool) (m : Mask) (env : Env) (id : Ident) (ns : List Node)
    (is : List Inst) : M (List Inst) :=
  (indexed (ns.zip is)).mapM fun (i, n, x) =>
    if all || hit (g.α.sig (readsNode n)) m then refreshNode g all m env (id ++ [.c i]) n x else pure x
end

/-- The button at `path`, with the environment and the state sites on its
path (by layer index). `none` is an event with no route. -/
partial def locate (ns : List Node) (is : List Inst) (env : Env) (sites : List Bool) :
    Ident → Option (Handler × Env × List Bool)
  | .c i :: rest =>
      match ns[i]?, is[i]?, rest with
      | some (.bump h), some .button, [] => some (h, env, sites)
      | some (.state _ body), some (.state v _ kids), _ => locate body kids (env.push v) (sites ++ [true]) rest
      | some (.derive _ body), some (.derive v kids), _ => locate body kids (env.push v) (sites ++ [false]) rest
      | some (.each _ body), some (.rows rs), .r k :: rest' =>
          (rs.lookup k).bind fun is => locate body is (env.push k) (sites ++ [false]) rest'
      | some n, some (.branch cur kids), .b k :: rest' =>
          match n.cases? with
          | some (_, _, cases) => if k = cur then locate (cases.getD cur []) kids env sites rest' else none
          | none => none
      | _, _, _ => none
  | _ => none

/-- Down the event's path: `act` at every state site on it, outermost first,
then on into what `act` left. A path the turn broke (a branch switched, a
row removed) ends there. -/
partial def along (act : Nat → Ident → Env → List Node → Val × Bool × List Inst → M (Val × Bool × List Inst))
    (ns : List Node) (is : List Inst) (env : Env) (id : Ident) : Ident → M (List Inst)
  | .c i :: rest => do
      let id' := id ++ [.c i]
      match ns[i]?, is[i]?, rest with
      | some (.state _ body), some (.state v w kids), _ =>
          let (v, w, kids) ← act env.depth id' env body (v, w, kids)
          let kids ← along act body kids (env.push v) id' rest
          pure (is.set i (.state v w kids))
      | some (.derive _ body), some (.derive v kids), _ =>
          pure (is.set i (.derive v (← along act body kids (env.push v) id' rest)))
      | some (.each _ body), some (.rows rs), .r k :: rest' =>
          let rs ← rs.mapM fun (k', row) => do
            if k' = k then pure (k', ← along act body row (env.push k) (id' ++ [.r k]) rest') else pure (k', row)
          pure (is.set i (.rows rs))
      | some n, some (.branch cur kids), .b k :: rest' =>
          match n.cases? with
          | some (_, _, cases) =>
              if k = cur then
                pure (is.set i (.branch cur (← along act (cases.getD cur []) kids env (id' ++ [.b k]) rest')))
              else pure is
          | none => pure is
      | _, _, _ => pure is
  | _ => pure is

/-- A live instance: the store beside the site tree. -/
structure Instance where
  cells : List Val
  root : List Inst
  dead : Rho := []

def mountProg (g : Cfg) (p : Prog) : Instance × List Dom × Tx :=
  let ((is, ds), tx) := (mountBlock g ⟨p.cells, []⟩ [] p.body).run {}
  ({ cells := p.cells, root := is }, ds, tx)

/-- Settle the writes of one event at `ev`: `lw` to the state layers at
those depths of its path, `cw` to cells. -/
def settle (g : Cfg) (p : Prog) (ev : Ident) (lw cw : List (Nat × Val)) (s : Instance) : M Instance := do
  let cells := cw.foldl (fun cs (c, v) => cs.set c v) s.cells
  let env0 : Env := ⟨cells, []⟩
  let depths := (lw.map (·.1)).eraseDups
  let wroteCell := !cw.isEmpty
  let outer := depths.foldl min (depths.headD 0)
  let two := g.bug = .twoPassInner || g.bug = .twoPassOuter
  -- Fire: every write is in place before anything is observed. A written
  -- layer with something written above it (a layer, or a cell) waits.
  let root ← along (fun d _ _ _ (v, w, kids) =>
      match lw.reverse.lookup d with
      | some v' => pure (v', !two && (wroteCell || d ≠ outer), kids)
      | none => pure (v, w, kids)) p.body s.root env0 [] ev
  let rootPass := fun (root : List Inst) =>
    refreshBlock g false (g.α.sig (cw.map fun (c, _) => .cell c)) env0 [] p.body root
  -- A pass at the state site at depth `start`, and the walk for the layers
  -- that still wait.
  let pathPass := fun (root : List Inst) (start : Option Nat) (walk : Bool) =>
    along (fun d id env body (v, w, kids) => do
      if start = some d || (walk && w) then
        pure (v, false, ← refreshBlock g false (g.α.mask (.layer d)) (env.push v) id body kids)
      else pure (v, w, kids)) p.body root env0 [] ev
  let root ←
    if two then do
      let sorted := (depths.toArray.qsort (· < ·)).toList
      if g.bug = .twoPassOuter then
        let root ← if wroteCell then rootPass root else pure root
        sorted.foldlM (fun root d => pathPass root (some d) false) root
      else
        let root ← sorted.reverse.foldlM (fun root d => pathPass root (some d) false) root
        if wroteCell then rootPass root else pure root
    else if wroteCell then do
      -- One pass from the root; then the walk.
      let root ← rootPass root
      if g.bug = .noWalk then pure root else pathPass root none true
    else if depths.isEmpty then pure root
    else
      -- One pass from the outermost written layer's site; then the walk.
      pathPass root (some outer) (g.bug ≠ .noWalk)
  pure { s with cells, root }

/-- One turn. `none`: the event has no route. -/
def turn (g : Cfg) (p : Prog) (s : Instance) (ev : Ident) : Option (Instance × Tx) :=
  match locate p.body s.root ⟨s.cells, []⟩ [] ev with
  | none => none
  | some (h, env, sites) =>
      let ws := h.writes env fun i => sites.getD i false
      let lw := ws.filterMap fun
        | (.layer i, v) => some (i, v)
        | _ => none
      let cw := ws.filterMap fun
        | (.cell c, v) => some (c, v)
        | _ => none
      let run : M Instance :=
        if g.bug = .perWrite then do
          let s ← lw.foldlM (fun s w => settle g p ev [w] [] s) s
          cw.foldlM (fun s w => settle g p ev [] [w] s) s
        else settle g p ev lw cw s
      let (s', tx) := run.run { dead := s.dead }
      some ({ s' with dead := tx.dead }, tx)

/-- The settle check: a pass that names everything, on a copy. -/
def settleCmds (g : Cfg) (p : Prog) (s : Instance) : Array Cmd :=
  ((refreshBlock g true 0 ⟨s.cells, []⟩ [] p.body s.root).run {}).2.cmds

/-! ### The page model -/

mutual
partial def patchBlock (cmd : Cmd) : Ident → List Dom → Except String (List Dom)
  | .c i :: rest, ds =>
      match ds[i]? with
      | some d => do pure (ds.set i (← patchDom cmd rest d))
      | none => throw "no such child"
  | _, _ => throw "path does not name a child"
partial def patchDom (cmd : Cmd) : Ident → Dom → Except String Dom
  | [], .text _ => match cmd with
      | .setText _ v => pure (.text v)
      | _ => throw "not a text command"
  | [], .texts _ => match cmd with
      | .setTexts _ vs => pure (.texts vs)
      | _ => throw "not a text command"
  | [], .rows rs => match cmd with
      | .order _ keys =>
          if keys.length = rs.length && keys.all (fun k => (rs.lookup k).isSome) then
            pure (.rows (keys.filterMap fun k => (rs.lookup k).map (k, ·)))
          else throw "order names other rows than are drawn"
      | _ => throw "not a rows command"
  | [.b k], .branch cur _ => match cmd with
      | .remove _ => if cur = some k then pure (.branch none []) else throw "remove of a branch not drawn"
      | .create _ frag => if cur = none then pure (.branch (some k) frag) else throw "create over a live branch"
      | _ => throw "not a branch command"
  | [.r k], .rows rs => match cmd with
      | .remove _ =>
          if (rs.lookup k).isSome then pure (.rows (rs.filter (·.1 ≠ k))) else throw "remove of a row not drawn"
      | .create _ frag =>
          if (rs.lookup k).isNone then pure (.rows (rs ++ [(k, frag)])) else throw "create over a live row"
      | _ => throw "not a row command"
  | rest@(.c _ :: _), .box kids => do pure (.box (← patchBlock cmd rest kids))
  | .b k :: rest, .branch cur kids =>
      if cur = some k then do pure (.branch cur (← patchBlock cmd rest kids)) else throw "path through a branch not drawn"
  | .r k :: rest, .rows rs =>
      if (rs.lookup k).isSome then do
        pure (.rows (← rs.mapM fun (k', ds) => do
          if k' = k then pure (k', ← patchBlock cmd rest ds) else pure (k', ds)))
      else throw "path through a row not drawn"
  | _, _ => throw "path does not fit the page"
end

def Cmd.id : Cmd → Ident
  | .setText id _ => id
  | .setTexts id _ => id
  | .remove id => id
  | .create id _ => id
  | .order id _ => id

def applyCmds (dom : List Dom) (cmds : Array Cmd) : Except String (List Dom) :=
  cmds.foldlM (fun d c => patchBlock c c.id d) dom

mutual
partial def flatDom (id : Ident) : Dom → List (Ident × Leaf)
  | .text v => [(id, .text v)]
  | .texts vs => [(id, .texts vs)]
  | .button n => [(id, .button n)]
  | .box kids => flatDoms id kids
  | .branch (some k) kids => flatDoms (id ++ [.b k]) kids
  | .branch none _ => []
  | .rows rs => rs.flatMap fun (k, ds) => flatDoms (id ++ [.r k]) ds
partial def flatDoms (id : Ident) (ds : List Dom) : List (Ident × Leaf) :=
  (indexed ds).flatMap fun (i, d) => flatDom (id ++ [.c i]) d
end

end Turns
