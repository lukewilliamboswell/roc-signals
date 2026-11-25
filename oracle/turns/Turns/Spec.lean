/-
The reference: the page from scratch, and a turn as "apply the writes,
render again". Nothing here is incremental.

Trusted for: what a turn means. This is the statement `design.md`
"Propagation: Turns, Ordering, and Pruning" and "Identity" are held to: the
page after a turn, the local state that survives it (a state lives exactly
while its identity, its path with every branch and row key on it, is
live), and how one event's writes compose. Where the engine, a Roc
reference or a vector disagrees with this file, this file decides, unless
`design.md` says otherwise; then `design.md` is changed first and this file
with it.
-/
import Turns.Kernel
namespace Turns

/-- What a render yields at an identity. -/
inductive Item where
  | text (v : Val)                        -- a hole's text
  | texts (vs : List Val)                 -- a `joined` hole's values
  | keyed (k v : Val)                     -- a `keyed` hole's row key and value
  | button (ws : List (Target × Val))     -- a live button and what a click writes
  | state (v : Val)                       -- a live local state (not on the page)
  deriving DecidableEq, Repr

/-- Everything live, in document order. -/
abbrev View := List (Ident × Item)

/-- ρ: local state carried by structural identity. -/
abbrev Rho := List (Ident × Val)

/-- A handler's writes where its button is drawn. A layer index names the
state site at that depth on the button's path; a write to a `derive` or a
row is no write. -/
def resolve (env : Env) (sites : List (Option Ident)) (h : Handler) : List (Target × Val) :=
  (h.writes env fun i => (sites.getD i none).isSome).filterMap fun (r, v) =>
    match r with
    | .cell c => some (.cell c, v)
    | .layer i => (sites.getD i none).map fun id => (.state id, v)

mutual
/-- `render`: a state reads ρ at its identity, or starts at `init`. -/
def renderNode (ρ : Rho) (env : Env) (sites : List (Option Ident)) (id : Ident) : Node → View
  | .show e => [(id, .text (e.eval env.get))]
  | .joined es => [(id, .texts (es.map (·.eval env.get)))]
  | .keyed e => [(id, .keyed (rowKey id) (e.eval env.get))]
  | .bump h => [(id, .button (resolve env sites h))]
  | .state init body =>
      let v := (ρ.lookup id).getD init
      (id, .state v) :: renderBlock ρ (env.push v) (sites ++ [some id]) id 0 body
  | .derive e body =>
      renderBlock ρ (env.push (e.eval env.get)) (sites ++ [none]) id 0 body
  | .when sel yes no =>
      if sel.eval env.get ≠ 0 then renderBlock ρ env sites (id ++ [.b 0]) 0 yes
      else renderBlock ρ env sites (id ++ [.b 1]) 0 no
  | .switch sel a b c =>
      match (sel.eval env.get % 3).toNat with
      | 0 => renderBlock ρ env sites (id ++ [.b 0]) 0 a
      | 1 => renderBlock ρ env sites (id ++ [.b 1]) 0 b
      | _ => renderBlock ρ env sites (id ++ [.b 2]) 0 c
  | .each src body =>
      (rowsOf (src.eval env.get)).flatMap fun (k, item) =>
        renderBlock ρ (env.push item) (sites ++ [none]) (id ++ [.r k]) 0 body
def renderBlock (ρ : Rho) (env : Env) (sites : List (Option Ident)) (id : Ident) (i : Nat) :
    List Node → View
  | [] => []
  | n :: ns => renderNode ρ env sites (id ++ [.c i]) n ++ renderBlock ρ env sites id (i + 1) ns
end

/-- The state of an instance: the store and the live local state. -/
structure World where
  cells : List Val
  rho : Rho
  deriving DecidableEq, Repr

def view (p : Prog) (w : World) : View := renderBlock w.rho ⟨w.cells, []⟩ [] [] 0 p.body

def rhoOf (v : View) : Rho := v.filterMap fun
  | (id, .state x) => some (id, x)
  | _ => none

def World.init (p : Prog) : World := { cells := p.cells, rho := rhoOf (view p ⟨p.cells, []⟩) }

/-- One turn: every write, then the page from scratch. The survival rule is
the last line: a local state is carried exactly when its identity (its path,
with every branch and row key on it) is live before and after. -/
def stepRef (p : Prog) (w : World) (ev : Ident) : Option World :=
  match (view p w).lookup ev with
  | some (.button ws) =>
      let w1 := ws.foldl (fun w (t, v) => match t with
        | .cell c => { w with cells := w.cells.set c v }
        | .state id => { w with rho := w.rho.map fun (i, x) => if i = id then (i, v) else (i, x) }) w
      some { w1 with rho := rhoOf (view p w1) }
  | _ => none

/-- The page: what the DOM shows. -/
inductive Leaf where
  | text (v : Val)
  | texts (vs : List Val)
  | keyed (k v : Val)
  | button (writes : Nat)                 -- a button, and how many writes its click makes
  deriving DecidableEq, Repr, Inhabited

def pageOf (v : View) : List (Ident × Leaf) := v.filterMap fun
  | (id, .text x) => some (id, .text x)
  | (id, .texts xs) => some (id, .texts xs)
  | (id, .keyed k x) => some (id, .keyed k x)
  | (id, .button ws) => some (id, .button ws.length)
  | _ => none

def buttonsOf (v : View) : List Ident := v.filterMap fun
  | (id, .button _) => some id
  | _ => none

end Turns
