/-
Proofs about the transliteration itself (`Bug.none`), not a re-model: the
definitions below are the ones the checker runs.

`Describes E t`: the table's changes say how `t` differs from the rows `E`.
Invariant 23 / T5 splits into
* a guarantee, proved here: the operations, the turn boundary and `kept`
  keep `Describes`, given
* an assumption, `Lineage`: a table carrying the cell's `id` and the turn's
  `start`, in its recording phase, describes the rows the turn began with.
  For a table changed only by its own operations that is proved
  (`turn_describes`). For a copy an app kept, it is what the exhaustive
  checker tests: a copy kept from an earlier turn is `ready`, so `kept`
  never takes it as the cell's own, and a `writing` copy exists only inside
  one turn of one history.
-/
import TableSpike.Spec
namespace TableSpike

theorem rget_rput (m : Rows) (k : K) (v : V) (k' : K) :
    rget (rput m k v) k' = if k' = k then some v else rget m k' := by
  induction m with
  | nil => simp [rput, rget]
  | cons hd tl ih => grind [rput, rget]

theorem rget_rdel (m : Rows) (k k' : K) :
    rget (rdel m k) k' = if k' = k then none else rget m k' := by
  induction m with
  | nil => simp [rdel, rget]
  | cons hd tl ih => grind [rdel, rget]

theorem cget_cnote (r : Rec) (k : K) (b : Before) (k' : K) :
    cget (cnote .none r k b) k' =
      match cget r k' with
      | some x => some x
      | none => if k' = k then some b else none := by
  induction r with
  | nil => simp [cnote, cget]
  | cons hd tl ih => grind [cnote, cget]

/-- A key written again keeps its first entry: a new entry appears only for
a key the record did not hold. -/
theorem mem_cnote (r : Rec) (k : K) (b : Before) (p : K × Before) :
    p ∈ cnote .none r k b → p ∈ r ∨ (p = (k, b) ∧ cget r k = none) := by
  induction r with
  | nil => simp [cnote, cget]
  | cons hd tl ih => grind [cnote, cget]

/-- The changes say how `t` differs from `E`: every recorded entry is the
key's state in `E`, and an unrecorded key has the row it has in `E`. -/
def Describes (E : Rows) (t : Table) : Prop :=
  t.whole = .keyed →
    (∀ p ∈ t.record, p.2 = beforeOf E p.1) ∧
    (∀ k, cget t.record k = none → rget t.rows k = rget E k)

theorem beforeOf_congr {E R : Rows} {k : K} (h : rget R k = rget E k) :
    beforeOf R k = beforeOf E k := by
  simp [beforeOf, h]

/-- TableCore.roc:230-250 keeps `Describes` when handed the key's current state. -/
theorem describes_write (E : Rows) (t : Table) (key : K) (after : Option V)
    (h : Describes E t) : Describes E (write .none t key (beforeOf t.rows key) after) := by
  intro hw
  have hw' : t.whole = .keyed := by simpa [write] using hw
  obtain ⟨h1, h2⟩ := h hw'
  simp only [write, hw']
  refine ⟨fun p hp => ?_, fun k hk => ?_⟩
  · rcases mem_cnote _ _ _ _ hp with hm | ⟨rfl, hn⟩
    · exact h1 p hm
    · exact beforeOf_congr (h2 key hn)
  · rw [cget_cnote] at hk
    have hk' : cget t.record k = none ∧ k ≠ key := by grind
    cases after <;> simp [rget_rput, rget_rdel, hk'.2, h2 k hk'.1]

theorem beforeOf_some {R : Rows} {k : K} {v : V} (h : rget R k = some v) :
    beforeOf R k = .was v := by simp [beforeOf, h]

theorem beforeOf_none {R : Rows} {k : K} (h : rget R k = none) :
    beforeOf R k = .absent := by simp [beforeOf, h]

theorem describes_put (E : Rows) (t : Table) (k : K) (v : V) (h : Describes E t) :
    Describes E (t.put .none k v) := by
  unfold Table.put
  cases hg : rget t.rows k with
  | some old => simpa [beforeOf_some hg] using describes_write E t k (some v) h
  | none => simpa [beforeOf_none hg] using describes_write E t k (some v) h

theorem describes_remove (E : Rows) (t : Table) (k : K) (h : Describes E t) :
    Describes E (t.remove .none k) := by
  unfold Table.remove
  cases hg : rget t.rows k with
  | some old => simpa [beforeOf_some hg] using describes_write E t k none h
  | none => simpa using h

theorem describes_apply (E : Rows) (ws : List InvOp) (t : Table) (h : Describes E t) :
    Describes E (t.apply .none ws) := by
  unfold Table.apply
  induction ws generalizing t with
  | nil => simpa using h
  | cons w ws ih =>
    simp only [List.foldl_cons]
    apply ih
    cases w with
    | put k v => exact describes_put E t k v h
    | remove k => exact describes_remove E t k h

/-- Every public operation keeps `Describes` (invariant 19 within a turn). -/
theorem describes_op (E : Rows) (nv : Nat) (t : Table) (op : Op) (h : Describes E t) :
    Describes E (op.run .none nv t) := by
  cases op with
  | insert k v =>
    simp only [Op.run, Table.insert]
    cases hg : rget t.rows k with
    | some old => simpa using h
    | none => simpa [beforeOf_none hg] using describes_write E t k (some v) h
  | put k v => exact describes_put E t k v h
  | replace k v =>
    simp only [Op.run, Table.replace]
    cases hg : rget t.rows k with
    | some old => simpa [beforeOf_some hg] using describes_write E t k (some v) h
    | none => simpa using h
  | update k =>
    simp only [Op.run, Table.update]
    cases hg : rget t.rows k with
    | some old => simpa [beforeOf_some hg] using describes_write E t k (some (bump nv old)) h
    | none => simpa using h
  | remove k => exact describes_remove E t k h
  | updateAll => intro hw; simp [Op.run, Table.updateAll] at hw
  | undo =>
    simp only [Op.run]
    cases hi : t.inverse with
    | some ws => exact describes_apply E ws t h
    | none => simpa using h

theorem describes_ops (E : Rows) (nv : Nat) (os : List Op) (t : Table) (h : Describes E t) :
    Describes E (os.foldl (Op.run .none nv) t) := by
  induction os generalizing t with
  | nil => simpa using h
  | cons o os ih => exact ih _ (describes_op E nv t o h)

/-- The turn boundary (TableCore.roc:185-189): the first modifier of a
writing turn starts a record that describes the rows the turn began with. -/
theorem describes_begin (t : Table) (h : t.phase = .ready) :
    Describes t.rows (beginChanges .none t) := by
  intro _
  simp [beginChanges, h, clearChanges, cget]

/-- What must hold of a table an app hands a cell: if it carries the cell's
`id` and the turn's `start` and is recording, its changes describe the turn. -/
def Lineage (E : Rows) (m : Mark) (x : Table) : Prop :=
  x.id = m.id → x.start = m.start → x.phase = .writing → Describes E x

/-- `kept` (TableCore.roc:218-225) is sound under the lineage assumption:
whatever table a write leaves, the cell stores one whose changes describe
the turn, or a whole rewrite (invariant 23 / T5, the guarantee half). -/
theorem describes_kept (E : Rows) (x : Table) (m : Mark) (h : Lineage E m x) :
    Describes E (kept .none x m) := by
  unfold kept
  by_cases hs : (x.id == m.id && x.start == m.start && x.phase == .writing) = true
  · have hs' : (x.id = m.id ∧ x.start = m.start) ∧ x.phase = .writing := by simpa using hs
    simp only [reduceCtorEq, ite_false, hs, ite_true]
    intro hw
    exact h hs'.1.1 hs'.1.2 hs'.2 hw
  · simp only [reduceCtorEq, ite_false, hs]
    intro hw; simp at hw

/-- One generated modifier (Core.roc:427-435) whose function changes the
table it is given by public operations keeps `Describes`. -/
theorem describes_modify (E : Rows) (nv : Nat) (c : Table) (os : List Op)
    (h : Describes E (beginChanges .none c)) :
    Describes E (cellModify .none c fun x => os.foldl (Op.run .none nv) x) := by
  unfold cellModify
  exact describes_kept E _ _ fun _ _ _ => describes_ops E nv os _ h

theorem kept_phase (x : Table) (m : Mark) : (kept .none x m).phase = .writing := by
  unfold kept
  by_cases hs : (x.id == m.id && x.start == m.start && x.phase == .writing) = true <;> simp [hs]

theorem begin_writing (c : Table) (h : c.phase = .writing) : beginChanges .none c = c := by
  simp [beginChanges, h]

/-- The cell after a list of modifiers, each a sequence of public operations. -/
def runTurn (nv : Nat) (fs : List (List Op)) (c : Table) : Table :=
  fs.foldl (fun c os => cellModify .none c fun x => os.foldl (Op.run .none nv) x) c

theorem runTurn_describes (E : Rows) (nv : Nat) (fs : List (List Op)) (c : Table)
    (h : Describes E (beginChanges .none c)) :
    Describes E (beginChanges .none (runTurn nv fs c)) := by
  unfold runTurn
  induction fs generalizing c with
  | nil => simpa using h
  | cons os rest ih =>
    simp only [List.foldl_cons]
    apply ih
    have hm := describes_modify E nv c os h
    rw [begin_writing _ (by unfold cellModify; exact kept_phase _ _)]
    exact hm

theorem runTurn_phase (nv : Nat) (fs : List (List Op)) (c : Table) (h : c.phase = .writing) :
    (runTurn nv fs c).phase = .writing := by
  unfold runTurn
  induction fs generalizing c with
  | nil => simpa using h
  | cons os rest ih =>
    simp only [List.foldl_cons]
    exact ih _ (by unfold cellModify; exact kept_phase _ _)

/-- **A whole writing turn (invariant 19).** From a ready table, one or more
modifiers, each any sequence of the public operations (`insert`, `put`,
`replace`, `update`, `remove`, `update_all`, and `apply` of the table's own
`inverse`), leave the cell holding a table whose changes describe the rows
the turn began with: every recorded entry is its key's state before the
turn's first write, and every unrecorded key is unchanged. -/
theorem turn_describes (nv : Nat) (t : Table) (ht : t.phase = .ready)
    (os : List Op) (fs : List (List Op)) :
    Describes t.rows (runTurn nv (os :: fs) t) := by
  have h := runTurn_describes t.rows nv (os :: fs) t (describes_begin t ht)
  have hp : (runTurn nv (os :: fs) t).phase = .writing := by
    show (runTurn nv fs _).phase = .writing
    exact runTurn_phase nv fs _ (by unfold cellModify; exact kept_phase _ _)
  rwa [begin_writing _ hp] at h

/-! ## `inverse` undoes the turn -/

theorem rows_put (t : Table) (k : K) (v : V) (k' : K) :
    rget (t.put .none k v).rows k' = if k' = k then some v else rget t.rows k' := by
  unfold Table.put
  split <;> simp [write, rget_rput]

theorem rows_remove (t : Table) (k k' : K) :
    rget (t.remove .none k).rows k' = if k' = k then none else rget t.rows k' := by
  unfold Table.remove
  split
  · simp [write, rget_rdel]
  · grind

def invOf (p : K × Before) : InvOp :=
  match p.2 with
  | .was row => .put p.1 row
  | .absent => .remove p.1

theorem apply_restores (E : Rows) (l : Rec) (t : Table)
    (hl : ∀ p ∈ l, p.2 = beforeOf E p.1) (k : K) :
    rget (t.apply .none (l.map invOf)).rows k =
      if (cget l k).isSome then rget E k else rget t.rows k := by
  unfold Table.apply
  induction l generalizing t with
  | nil => simp [cget]
  | cons hd tl ih =>
    obtain ⟨a, b⟩ := hd
    have hb : b = beforeOf E a := hl (a, b) (by simp)
    have htl : ∀ p ∈ tl, p.2 = beforeOf E p.1 := fun p hp => hl p (by simp [hp])
    simp only [List.map_cons, List.foldl_cons]
    rw [ih _ htl]
    cases b with
    | absent =>
      have hE : rget E a = none := by
        cases hg : rget E a with
        | none => rfl
        | some v => simp [beforeOf, hg] at hb
      simp only [invOf, cget, rows_remove]
      grind
    | was row =>
      have hE : rget E a = some row := by
        cases hg : rget E a with
        | none => simp [beforeOf, hg] at hb
        | some v => simp [beforeOf, hg] at hb; simp [hb]
      simp only [invOf, cget, rows_put]
      grind

/-- **`Table.inverse` undoes the turn.** If a table's changes describe the
rows `E` and are keyed, applying its inverse gives, at every key, the row
`E` has. -/
theorem inverse_restores (E : Rows) (t : Table) (h : Describes E t) (hw : t.whole = .keyed)
    (ws : List InvOp) (hi : t.inverse = some ws) (k : K) :
    rget (t.apply .none ws).rows k = rget E k := by
  obtain ⟨h1, h2⟩ := h hw
  have hws : ws = t.record.map invOf := by
    simp only [Table.inverse, hw] at hi
    rw [← Option.some.inj hi]
    apply List.map_congr_left
    intro p _
    obtain ⟨a, b⟩ := p
    cases b <;> rfl
  rw [hws, apply_restores E t.record t h1 k]
  cases hc : cget t.record k with
  | some b => simp
  | none => simpa using h2 k hc

/-- A whole turn and its inverse: the rows the turn began with come back. -/
theorem turn_inverse (nv : Nat) (t : Table) (ht : t.phase = .ready)
    (os : List Op) (fs : List (List Op)) (ws : List InvOp)
    (hi : (runTurn nv (os :: fs) t).inverse = some ws) (k : K) :
    rget ((runTurn nv (os :: fs) t).apply .none ws).rows k = rget t.rows k := by
  have hw : (runTurn nv (os :: fs) t).whole = .keyed := by
    unfold Table.inverse at hi; split at hi <;> simp_all
  exact inverse_restores t.rows _ (turn_describes nv t ht os fs) hw ws hi k

/-! ## The counts (the unstated facts behind T5) -/

theorem write_version (t : Table) (k : K) (b : Before) (a : Option V) :
    (write .none t k b a).version = t.version + 1 ∧ (write .none t k b a).start = t.start
      ∧ (write .none t k b a).id = t.id := by
  simp [write]

/-- Each operation that writes adds exactly one to the count; one that does
not leaves the table as it was. -/
theorem op_counts (nv : Nat) (t : Table) (op : Op) (w : Bool) (h : op.writes t = some w) :
    (op.run .none nv t).version = t.version + (if w then 1 else 0) := by
  cases op with
  | insert k v =>
    simp only [Op.writes, Option.some.injEq] at h; subst h
    simp only [Op.run, Table.insert]; cases hg : rget t.rows k <;> simp [write]
  | put k v =>
    simp only [Op.writes, Option.some.injEq] at h; subst h
    simp only [Op.run, Table.put]; cases hg : rget t.rows k <;> simp [write]
  | replace k v =>
    simp only [Op.writes, Option.some.injEq] at h; subst h
    simp only [Op.run, Table.replace]; cases hg : rget t.rows k <;> simp [write]
  | update k =>
    simp only [Op.writes, Option.some.injEq] at h; subst h
    simp only [Op.run, Table.update]; cases hg : rget t.rows k <;> simp [write]
  | remove k =>
    simp only [Op.writes, Option.some.injEq] at h; subst h
    simp only [Op.run, Table.remove]; cases hg : rget t.rows k <;> simp [write]
  | updateAll =>
    simp only [Op.writes, Option.some.injEq] at h; subst h
    simp [Op.run, Table.updateAll]
  | undo => simp [Op.writes] at h

#print axioms turn_describes
#print axioms turn_inverse
#print axioms describes_kept
#print axioms op_counts

end TableSpike
