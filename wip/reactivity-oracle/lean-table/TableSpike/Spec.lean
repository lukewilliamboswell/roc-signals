/-
The specification, as plain functions that share nothing with the
transliteration but the row lookup: what the record means, what a view is,
and what an app's function over a table may be.
-/
import TableSpike.View
namespace TableSpike

/-! ## The record (design.md:811-817, 950-961) -/

/-- A key's state in `E`, as the record would hold it. -/
def beforeOf (E : Rows) (k : K) : Before :=
  match rget E k with
  | some v => .was v
  | none => .absent

/-- Every recorded entry is the key's state when the turn began. -/
def recordSound (E : Rows) (t : Table) : Bool :=
  t.record.all fun (k, b) => b == beforeOf E k

/-- Every key whose row differs from the turn's start is recorded. -/
def recordCovers (keys : List K) (E : Rows) (t : Table) : Bool :=
  keys.all fun k => (cget t.record k).isSome || rget t.rows k == rget E k

/-- `Table.inverse` applied to the table gives the rows the turn began with. -/
def inverseRestores (E : Rows) (t : Table) : Bool :=
  match t.inverse with
  | none => true
  | some ws => (t.apply .none ws).rows == E

/-! ## The view (design.md:5345-5353): `window (sort (filter table))` -/

def insertBy (lt : Entry → Entry → Bool) (e : Entry) : List Entry → List Entry
  | [] => [e]
  | x :: xs => if lt e x then e :: x :: xs else x :: insertBy lt e xs

/-- The keys a query keeps, in its order: a filter and an insertion sort. -/
def specKeys (q : Nat) (rows : Rows) : List K :=
  let p := plan q
  let kept := rows.filter fun (k, v) => p.keep k v
  let sorted := kept.foldl (fun acc (k, v) =>
    insertBy (fun a b => p.compare a.1 b.1 == .lt) (p.sort k v, k) acc) []
  sorted.map (·.2)

def specWindow (keys : List K) (w : Window) : List K := (keys.drop w.start).take w.count

/-- Length of a longest strictly increasing subsequence, by the quadratic rule. -/
def lisLength (xs : List Nat) : Nat :=
  let best := xs.foldl (fun (acc : List (Nat × Nat)) x =>
    let b := (acc.filter fun (y, _) => y < x).foldl (fun m (_, l) => max m l) 0
    acc ++ [(x, b + 1)]) []
  best.foldl (fun m (_, l) => max m l) 0

/-! ## What an app may hand a table cell -/

inductive Op where
  | insert (k : K) (v : V)
  | put (k : K) (v : V)
  | replace (k : K) (v : V)
  | update (k : K)
  | remove (k : K)
  | updateAll
  | undo          -- `t.apply(t.inverse())`
  deriving DecidableEq, Repr, Hashable

def bump (nv : Nat) (v : V) : V := (v + 1) % nv

def Op.run (bug : Bug) (nv : Nat) (t : Table) : Op → Table
  | .insert k v => t.insert bug k v
  | .put k v => t.put bug k v
  | .replace k v => t.replace bug k v
  | .update k => t.update bug k (bump nv)
  | .remove k => t.remove bug k
  | .updateAll => t.updateAll fun _ v => bump nv v
  | .undo => match t.inverse with
    | some ws => t.apply bug ws
    | none => t

/-- Does the operation write (and so count)? `none`: not a single write. -/
def Op.writes (t : Table) : Op → Option Bool
  | .insert k _ => some (rget t.rows k).isNone
  | .put _ _ => some true
  | .replace k _ | .update k | .remove k => some (rget t.rows k).isSome
  | .updateAll => some true
  | .undo => none

def Op.key : Op → Option K
  | .insert k _ | .put k _ | .replace k _ | .update k | .remove k => some k
  | _ => none

/-- A function an app passes to `Cell.update` of a table cell. -/
inductive Fn where
  | onArg (os : List Op)             -- the table it is given, changed by operations
  | saved (i : Nat) (os : List Op)   -- a copy it kept, ignoring its argument
  | other (i : Nat) (os : List Op)   -- a kept copy under another cell's identity
  | fresh (rows : Rows)              -- `Table.from_list`
  deriving DecidableEq, Repr

def otherId : Nat := 77

def Fn.run (bug : Bug) (nv : Nat) (saved : List Table) : Fn → Table → Table
  | .onArg os, t => os.foldl (Op.run bug nv) t
  | .saved i os, t => os.foldl (Op.run bug nv) (saved.getD i t)
  | .other i os, t => os.foldl (Op.run bug nv) (withId (saved.getD i t) otherId)
  | .fresh rows, _ => { Table.empty with rows := rows }

def Op.show : Op → String
  | .insert k v => s!"insert({k},{v})"
  | .put k v => s!"put({k},{v})"
  | .replace k v => s!"replace({k},{v})"
  | .update k => s!"update({k})"
  | .remove k => s!"remove({k})"
  | .updateAll => "update_all"
  | .undo => "undo"

def showOps (os : List Op) : String := " ".intercalate (os.map Op.show)

def Fn.show : Fn → String
  | .onArg os => s!"|t| t.{showOps os}"
  | .saved i os => s!"|_| saved{i}.{showOps os}"
  | .other i os => s!"|_| other(saved{i}).{showOps os}"
  | .fresh rows => s!"|_| from_list({rows})"

end TableSpike
