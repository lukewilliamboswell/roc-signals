/-
A transliteration of `platform/TableCore.roc` (355 lines) and of the table
cell's generated modifier in `platform/Core.roc:427-439`.

Abstractions (everything else is line for line):
* `Dict(k, v)` rows  -> an association list kept sorted by key, so that two
  tables with the same rows are equal as values (Roc's `Dict` order is
  unspecified for rows; nothing below reads it).
* `Dict(k, [Absent, Was(v)])` record -> an association list in insertion
  order (the record is never removed from, so insertion order is the
  order `inverse` folds in).
* keys and rows are `Nat`; `U64` overflow is not modelled.
* `Bug` selects a seeded defect; `Bug.none` is the transliteration.

Trusted for: what `TableCore.roc` does, not what it should do. It follows
the code as it is, defects included, so the checks show what the code
keeps; where a check fails, `design.md` and `Tables.Spec` say what is
wanted, and the fix lands here and in Roc together.
-/
namespace Tables

abbrev K := Nat
abbrev V := Nat

inductive Bug where
  | none
  | latestRow   -- the record keeps the latest earlier row, not the first
  | noClear     -- the next writing turn's first modifier does not clear
  | staleOk     -- `kept` compares the id only
  | idOk        -- `kept` compares the start only
  | twoDraws    -- the site draws for the table, then again for the window
  | noReach     -- `absorb` never reports that a change reached the window
  deriving DecidableEq, Repr

inductive Before where
  | absent
  | was (v : V)
  deriving DecidableEq, Repr, Hashable

inductive Whole where
  | keyed | rewritten
  deriving DecidableEq, Repr, Hashable

inductive Phase where
  | ready | writing
  deriving DecidableEq, Repr, Hashable

abbrev Rows := List (K × V)
abbrev Rec := List (K × Before)

/-- `Dict.get` on rows. -/
def rget : Rows → K → Option V
  | [], _ => none
  | (k', v) :: m, k => if k = k' then some v else rget m k

/-- `Dict.insert` on rows (sorted, replacing). -/
def rput : Rows → K → V → Rows
  | [], k, v => [(k, v)]
  | (k', v') :: m, k, v =>
    if k = k' then (k, v) :: m
    else if k < k' then (k, v) :: (k', v') :: m
    else (k', v') :: rput m k v

/-- `Dict.remove` on rows. -/
def rdel : Rows → K → Rows
  | [], _ => []
  | (k', v') :: m, k => if k = k' then rdel m k else (k', v') :: rdel m k

/-- `Dict.get` on the record. -/
def cget : Rec → K → Option Before
  | [], _ => none
  | (k', b) :: r, k => if k = k' then some b else cget r k

/-- TableCore.roc:237-243: `record.update(key, |found| Ok(first) | Ok(before))`. -/
def cnote (bug : Bug) : Rec → K → Before → Rec
  | [], k, b => [(k, b)]
  | (k', b') :: r, k, b =>
    if k = k' then (if bug = .latestRow then (k, b) :: r else (k', b') :: r)
    else (k', b') :: cnote bug r k b

/-- TableCore.roc:7-15. -/
structure Table where
  rows : Rows
  record : Rec
  whole : Whole
  version : Nat
  start : Nat
  id : Nat
  phase : Phase
  deriving DecidableEq, Repr, Hashable

/-- TableCore.roc:36-37. -/
def Table.empty : Table :=
  { rows := [], record := [], whole := .keyed, version := 0, start := 0, id := 0, phase := .ready }

/-- TableCore.roc:21-33. `Err(DuplicateKey(key))` is `none` with the key lost. -/
def Table.fromList (entries : List (K × V)) : Except K Table := do
  let mut rows : Rows := []
  for (key, row) in entries do
    if (rget rows key).isSome then throw key
    rows := rput rows key row
  return { Table.empty with rows := rows }

/-- TableCore.roc:230-250. -/
def write (bug : Bug) (t : Table) (key : K) (before : Before) (after : Option V) : Table :=
  let nextRecord := match t.whole with
    | .rewritten => t.record
    | .keyed => cnote bug t.record key before
  let nextRows := match after with
    | some row => rput t.rows key row
    | none => rdel t.rows key
  { t with rows := nextRows, record := nextRecord, version := t.version + 1 }

/-- TableCore.roc:61-63. -/
def Table.insert (bug : Bug) (t : Table) (key : K) (row : V) : Table :=
  if (rget t.rows key).isSome then t else write bug t key .absent (some row)

/-- TableCore.roc:67-72. -/
def Table.put (bug : Bug) (t : Table) (key : K) (row : V) : Table :=
  match rget t.rows key with
  | some old => write bug t key (.was old) (some row)
  | none => write bug t key .absent (some row)

/-- TableCore.roc:76-81. -/
def Table.replace (bug : Bug) (t : Table) (key : K) (row : V) : Table :=
  match rget t.rows key with
  | some old => write bug t key (.was old) (some row)
  | none => t

/-- TableCore.roc:85-90. -/
def Table.update (bug : Bug) (t : Table) (key : K) (change : V → V) : Table :=
  match rget t.rows key with
  | some old => write bug t key (.was old) (some (change old))
  | none => t

/-- TableCore.roc:94-99. -/
def Table.remove (bug : Bug) (t : Table) (key : K) : Table :=
  match rget t.rows key with
  | some old => write bug t key (.was old) none
  | none => t

/-- TableCore.roc:104-108. -/
def Table.updateAll (t : Table) (change : K → V → V) : Table :=
  { t with rows := t.rows.map (fun (k, v) => (k, change k v)), record := [],
           whole := .rewritten, version := t.version + 1 }

inductive InvOp where
  | put (k : K) (v : V)
  | remove (k : K)
  deriving DecidableEq, Repr

/-- TableCore.roc:132-145. `Err(Rewritten)` is `none`. -/
def Table.inverse (t : Table) : Option (List InvOp) :=
  match t.whole with
  | .rewritten => none
  | .keyed => some (t.record.map fun (key, before) =>
      match before with
      | .was row => .put key row
      | .absent => .remove key)

/-- TableCore.roc:150-158. -/
def Table.apply (bug : Bug) (t : Table) (writes : List InvOp) : Table :=
  writes.foldl (fun acc op => match op with
    | .put key row => acc.put bug key row
    | .remove key => acc.remove bug key) t

/-- TableCore.roc:177-181. -/
def clearChanges (t : Table) : Table :=
  { t with record := [], whole := .keyed, start := t.version, phase := .ready }

/-- TableCore.roc:185-189. -/
def beginChanges (bug : Bug) (t : Table) : Table :=
  match t.phase with
  | .writing => t
  | .ready => if bug = .noClear then { t with phase := .writing }
              else { clearChanges t with phase := .writing }

/-- TableCore.roc:192-193. -/
def finishChanges (t : Table) : Table := { t with phase := .ready }

/-- TableCore.roc:200-204. -/
def withId (t : Table) (id : Nat) : Table := { t with id := id }

structure Mark where
  id : Nat
  start : Nat
  version : Nat
  deriving DecidableEq, Repr

/-- TableCore.roc:208-209. -/
def mark (t : Table) : Mark := { id := t.id, start := t.start, version := t.version }

/-- TableCore.roc:218-225. -/
def kept (bug : Bug) (t : Table) (before : Mark) : Table :=
  let same :=
    if bug = .staleOk then t.id == before.id
    else if bug = .idOk then t.start == before.start
    else t.id == before.id && t.start == before.start
  if same then { t with phase := .writing }
  else { rows := t.rows, record := [], whole := .rewritten, version := before.version + 1,
         start := before.start, id := before.id, phase := .writing }

/-- Core.roc:427-435: the generated modifier of a table cell. -/
def cellModify (bug : Bug) (t : Table) (f : Table → Table) : Table :=
  let began := beginChanges bug t
  let before := mark began
  kept bug (f began) before

/-- Core.roc:439 `clear` then `stamp`/`live`: a cell's table as an instance starts with it. -/
def cellStart (rows : Rows) (id : Nat) : Table :=
  withId (clearChanges { Table.empty with rows := rows }) id

end Tables
