/-
One proof: P3 for the static fragment (holes, `state`, `derive`), for any
signature abstraction.

The fragment is modelled on its own here, as a chain of sites, so that
every function is structurally recursive. It shares `Expr`, `Expr.eval` and
`Expr.reads` with the executable model and nothing else.

Trusted for: the theorems below, about this model. That the model is the
executable algorithm is tested, not proved (`Turns.ProofLink`, `check
link`).
-/
import Turns.Kernel
namespace Turns.Static

/-- A mounted static block: a chain of sites, each with its storage. -/
inductive S where
  | nil
  | hole (e : Expr) (last : Val) (next : S)
  | state (v : Val) (waiting : Bool) (body next : S)
  | derive (e : Expr) (v : Val) (body next : S)
  deriving DecidableEq

/-- An environment: every layer and every cell. -/
abbrev E := Ref → Val

/-- The environment below the layer at depth `d`. -/
def push (ρ : E) (d : Nat) (v : Val) : E := fun r => if r = .layer d then v else ρ r

/-- A set of signature bits. -/
abbrev Mask := Nat → Bool

def Mask.add (m : Mask) (b : Nat) : Mask := fun x => decide (x = b) || m x
def Mask.none : Mask := fun _ => false

/-- Whether a reader of `rs` listens to `m`, under the abstraction `α`. Any
`α` at all is sound: a reader's signature is the image of its reads. -/
def hit (α : Ref → Nat) (m : Mask) (rs : List Ref) : Bool := rs.any fun r => m (α r)

/-- Static reads of a block. -/
def reads : S → List Ref
  | .nil => []
  | .hole e _ n => e.reads ++ reads n
  | .state _ _ b n => reads b ++ reads n
  | .derive e _ b n => e.reads ++ reads b ++ reads n

/-- `Changed(m)` over a block in the environment `ρ` at depth `d`.

A hole is evaluated when its signature meets `m`. A site is entered when
its static reads meet `m`; a waiting layer that is entered joins, adding its
bit for its own subtree; a `derive` that is woken is recomputed first and
adds its bit only when its value changed.

`force` enters every site whatever its reads: with the empty mask that is
the walk that follows the pass, here over the whole block rather than down
one path. -/
def go (α : Ref → Nat) (force : Bool) (m : Mask) (ρ : E) (d : Nat) : S → S
  | .nil => .nil
  | .hole e last n => .hole e (if hit α m e.reads then e.eval ρ else last) (go α force m ρ d n)
  | .state v w b n =>
      if force || hit α m (reads b) then
        .state v false (go α force (if w then m.add (α (.layer d)) else m) (push ρ d v) (d + 1) b)
          (go α force m ρ d n)
      else .state v w b (go α force m ρ d n)
  | .derive e v b n =>
      if force || hit α m (e.reads ++ reads b) then
        if hit α m e.reads then
          .derive e (e.eval ρ)
            (go α force (if e.eval ρ = v then m else m.add (α (.layer d))) (push ρ d (e.eval ρ)) (d + 1) b)
            (go α force m ρ d n)
        else .derive e v (go α force m (push ρ d v) (d + 1) b) (go α force m ρ d n)
      else .derive e v b (go α force m ρ d n)

def pass (α : Ref → Nat) (m : Mask) (ρ : E) (d : Nat) (t : S) : S := go α false m ρ d t
def walk (α : Ref → Nat) (ρ : E) (d : Nat) (t : S) : S := go α true Mask.none ρ d t

/-- From-scratch consistency: every hole shows its expression, every
`derive` holds its expression, and nothing waits. -/
def Ok (ρ : E) (d : Nat) : S → Prop
  | .nil => True
  | .hole e last n => last = e.eval ρ ∧ Ok ρ d n
  | .state v w b n => w = false ∧ Ok (push ρ d v) (d + 1) b ∧ Ok ρ d n
  | .derive e v b n => v = e.eval ρ ∧ Ok (push ρ d v) (d + 1) b ∧ Ok ρ d n

/-- Consistency with `ρ` up to the layers that wait: below a waiting layer
the block is consistent with some earlier value of that layer. -/
def Pre (ρ : E) (d : Nat) : S → Prop
  | .nil => True
  | .hole e last n => last = e.eval ρ ∧ Pre ρ d n
  | .state v w b n => (∃ v0, (w = false → v0 = v) ∧ Pre (push ρ d v0) (d + 1) b) ∧ Pre ρ d n
  | .derive e v b n => v = e.eval ρ ∧ Pre (push ρ d v) (d + 1) b ∧ Pre ρ d n

/-- What an event does before anything is observed: some state sites take
a new value and wait. -/
inductive Wrote : S → S → Prop
  | nil : Wrote .nil .nil
  | hole : Wrote n n' → Wrote (.hole e l n) (.hole e l n')
  | keep : Wrote b b' → Wrote n n' → Wrote (.state v false b n) (.state v false b' n')
  | write : Wrote b b' → Wrote n n' → Wrote (.state v false b n) (.state v' true b' n')
  | derive : Wrote b b' → Wrote n n' → Wrote (.derive e v b n) (.derive e v b' n')

/-- `ρ` and `ρ'` differ only in what `m` names. -/
def Agree (α : Ref → Nat) (m : Mask) (ρ ρ' : E) : Prop := ∀ r, m (α r) = false → ρ r = ρ' r

theorem eval_congr {ρ ρ' : E} (e : Expr) (h : ∀ r ∈ e.reads, ρ r = ρ' r) : e.eval ρ = e.eval ρ' := by
  induction e with
  | lit n => rfl
  | rd r => exact h r (by simp [Expr.reads])
  | add a b iha ihb =>
      simp only [Expr.reads, List.mem_append] at h
      simp [Expr.eval, iha (fun r hr => h r (Or.inl hr)), ihb (fun r hr => h r (Or.inr hr))]
  | mul a b iha ihb =>
      simp only [Expr.reads, List.mem_append] at h
      simp [Expr.eval, iha (fun r hr => h r (Or.inl hr)), ihb (fun r hr => h r (Or.inr hr))]
  | mod a b iha ihb =>
      simp only [Expr.reads, List.mem_append] at h
      simp [Expr.eval, iha (fun r hr => h r (Or.inl hr)), ihb (fun r hr => h r (Or.inr hr))]
  | eq a b iha ihb =>
      simp only [Expr.reads, List.mem_append] at h
      simp [Expr.eval, iha (fun r hr => h r (Or.inl hr)), ihb (fun r hr => h r (Or.inr hr))]

theorem not_hit {α : Ref → Nat} {m : Mask} {rs : List Ref} (h : ¬ hit α m rs = true) :
    ∀ r ∈ rs, m (α r) = false := by
  simpa [hit] using h

theorem agree_push {α : Ref → Nat} {m : Mask} {ρ ρ' : E} (d : Nat) (v : Val) (h : Agree α m ρ ρ') :
    Agree α m (push ρ d v) (push ρ' d v) := by
  intro r hr
  simp only [push]
  split
  · rfl
  · exact h r hr

theorem agree_join {α : Ref → Nat} {m : Mask} {ρ ρ' : E} (d : Nat) (v v' : Val) (h : Agree α m ρ ρ') :
    Agree α (m.add (α (.layer d))) (push ρ d v) (push ρ' d v') := by
  intro r hr
  simp only [Mask.add, Bool.or_eq_false_iff, decide_eq_false_iff_not] at hr
  simp only [push]
  split
  · next heq => exact absurd (by rw [heq]) hr.1
  · exact h r hr.2

theorem push_congr {ρ ρ' : E} {rs : List Ref} (d : Nat) (v : Val) (h : ∀ r ∈ rs, ρ r = ρ' r) :
    ∀ r ∈ rs, push ρ d v r = push ρ' d v r := by
  intro r hr
  simp only [push]
  split
  · rfl
  · exact h r hr

/-- A block that reads nothing of a change is consistent after it as it was
before: this is why a child whose reads miss the mask is not entered, and
why a waiting layer the pass did not reach shares no reader with it. -/
theorem pre_congr (t : S) : ∀ (ρ ρ' : E) (d : Nat), (∀ r ∈ reads t, ρ r = ρ' r) → Pre ρ d t → Pre ρ' d t := by
  induction t with
  | nil => intros; trivial
  | hole e last n ih =>
      intro ρ ρ' d h hp
      simp only [reads, List.mem_append] at h
      exact ⟨hp.1.trans (eval_congr e (fun r hr => h r (Or.inl hr))), ih ρ ρ' d (fun r hr => h r (Or.inr hr)) hp.2⟩
  | state v w b n ihb ihn =>
      intro ρ ρ' d h hp
      simp only [reads, List.mem_append] at h
      obtain ⟨⟨v0, hv, hb⟩, hn⟩ := hp
      exact ⟨⟨v0, hv, ihb _ _ _ (push_congr d v0 (fun r hr => h r (Or.inl hr))) hb⟩,
        ihn ρ ρ' d (fun r hr => h r (Or.inr hr)) hn⟩
  | derive e v b n ihb ihn =>
      intro ρ ρ' d h hp
      simp only [reads, List.mem_append] at h
      obtain ⟨hv, hb, hn⟩ := hp
      exact ⟨hv.trans (eval_congr e (fun r hr => h r (Or.inl (Or.inl hr)))),
        ihb _ _ _ (push_congr d v (fun r hr => h r (Or.inl (Or.inr hr)))) hb,
        ihn ρ ρ' d (fun r hr => h r (Or.inr hr)) hn⟩

/-- The pass is sound wherever it stops: after `Changed(m)` in the new
environment, everything is consistent with it except below the layers that
still wait. -/
theorem go_pre (α : Ref → Nat) (force : Bool) (t : S) :
    ∀ (m : Mask) (ρ ρ' : E) (d : Nat), Agree α m ρ ρ' → Pre ρ d t → Pre ρ' d (go α force m ρ' d t) := by
  induction t with
  | nil => intros; trivial
  | hole e last n ih =>
      intro m ρ ρ' d ha hp
      refine ⟨?_, ih m ρ ρ' d ha hp.2⟩
      by_cases hh : hit α m e.reads = true
      · simp [hh]
      · simp only [hh]
        exact hp.1.trans (eval_congr e (fun r hr => ha r (not_hit hh r hr)))
  | state v w b n ihb ihn =>
      intro m ρ ρ' d ha hp
      obtain ⟨⟨v0, hv, hb⟩, hn⟩ := hp
      simp only [go]
      split
      · refine ⟨⟨v, fun _ => rfl, ?_⟩, ihn m ρ ρ' d ha hn⟩
        cases w with
        | true => exact ihb _ _ _ _ (agree_join d v0 v ha) hb
        | false =>
            rw [hv rfl] at hb
            exact ihb _ _ _ _ (agree_push d v ha) hb
      · next hh =>
        simp only [Bool.or_eq_true, not_or] at hh
        exact ⟨⟨v0, hv, pre_congr b _ _ _ (push_congr d v0 (fun r hr => ha r (not_hit hh.2 r hr))) hb⟩,
          ihn m ρ ρ' d ha hn⟩
  | derive e v b n ihb ihn =>
      intro m ρ ρ' d ha hp
      obtain ⟨hv, hb, hn⟩ := hp
      simp only [go]
      split
      · split
        · refine ⟨rfl, ?_, ihn m ρ ρ' d ha hn⟩
          split
          · next heq =>
            rw [heq]
            exact ihb _ _ _ _ (agree_push d v ha) hb
          · exact ihb _ _ _ _ (agree_join d v _ ha) hb
        · next hh =>
          have he : e.eval ρ = e.eval ρ' := eval_congr e (fun r hr => ha r (not_hit hh r hr))
          exact ⟨hv.trans he, ihb _ _ _ _ (agree_push d v ha) hb, ihn m ρ ρ' d ha hn⟩
      · next hh =>
        simp only [Bool.or_eq_true, not_or] at hh
        have hr := not_hit hh.2
        simp only [List.mem_append] at hr
        exact ⟨hv.trans (eval_congr e (fun r h => ha r (hr r (Or.inl h)))),
          pre_congr b _ _ _ (push_congr d v (fun r h => ha r (hr r (Or.inr h)))) hb,
          ihn m ρ ρ' d ha hn⟩

/-- Entering every site leaves nothing waiting: the walk ends consistent. -/
theorem go_ok (α : Ref → Nat) (t : S) :
    ∀ (m : Mask) (ρ ρ' : E) (d : Nat), Agree α m ρ ρ' → Pre ρ d t → Ok ρ' d (go α true m ρ' d t) := by
  induction t with
  | nil => intros; trivial
  | hole e last n ih =>
      intro m ρ ρ' d ha hp
      refine ⟨?_, ih m ρ ρ' d ha hp.2⟩
      by_cases hh : hit α m e.reads = true
      · simp [hh]
      · simp only [hh]
        exact hp.1.trans (eval_congr e (fun r hr => ha r (not_hit hh r hr)))
  | state v w b n ihb ihn =>
      intro m ρ ρ' d ha hp
      obtain ⟨⟨v0, hv, hb⟩, hn⟩ := hp
      simp only [go, Bool.true_or, ite_true]
      refine ⟨rfl, ?_, ihn m ρ ρ' d ha hn⟩
      cases w with
      | true => exact ihb _ _ _ _ (agree_join d v0 v ha) hb
      | false =>
          rw [hv rfl] at hb
          exact ihb _ _ _ _ (agree_push d v ha) hb
  | derive e v b n ihb ihn =>
      intro m ρ ρ' d ha hp
      obtain ⟨hv, hb, hn⟩ := hp
      simp only [go, Bool.true_or, ite_true]
      split
      · refine ⟨rfl, ?_, ihn m ρ ρ' d ha hn⟩
        split
        · next heq =>
          rw [heq]
          exact ihb _ _ _ _ (agree_push d v ha) hb
        · exact ihb _ _ _ _ (agree_join d v _ ha) hb
      · next hh =>
        have he : e.eval ρ = e.eval ρ' := eval_congr e (fun r hr => ha r (not_hit hh r hr))
        exact ⟨hv.trans he, ihb _ _ _ _ (agree_push d v ha) hb, ihn m ρ ρ' d ha hn⟩

theorem ok_pre (t : S) : ∀ (ρ : E) (d : Nat), Ok ρ d t → Pre ρ d t := by
  induction t with
  | nil => intros; trivial
  | hole e last n ih => exact fun ρ d h => ⟨h.1, ih ρ d h.2⟩
  | state v w b n ihb ihn => exact fun ρ d h => ⟨⟨v, fun _ => rfl, ihb _ _ h.2.1⟩, ihn ρ d h.2.2⟩
  | derive e v b n ihb ihn => exact fun ρ d h => ⟨h.1, ihb _ _ h.2.1, ihn ρ d h.2.2⟩

/-- Writes leave the tree consistent with the environment before them, up to
the layers that now wait. -/
theorem wrote_pre {t t' : S} (hw : Wrote t t') : ∀ (ρ : E) (d : Nat), Ok ρ d t → Pre ρ d t' := by
  induction hw with
  | nil => intros; trivial
  | hole _ ih => exact fun ρ d h => ⟨h.1, ih ρ d h.2⟩
  | keep _ _ ihb ihn => exact fun ρ d h => ⟨⟨_, fun _ => rfl, ihb _ _ h.2.1⟩, ihn ρ d h.2.2⟩
  | @write b b' n n' v v' _ _ ihb ihn =>
      exact fun ρ d h => ⟨⟨v, fun h => absurd h (by decide), ihb _ _ h.2.1⟩, ihn ρ d h.2.2⟩
  | derive _ _ ihb ihn => exact fun ρ d h => ⟨h.1, ihb _ _ h.2.1, ihn ρ d h.2.2⟩

theorem agree_refl (α : Ref → Nat) (m : Mask) (ρ : E) : Agree α m ρ ρ := fun _ _ => rfl

/-- **P3 for the static fragment, for any abstraction `α`.**

A block consistent with `ρ` takes an event: some of its state sites are
written and wait (`Wrote`), and the environment around it becomes `ρ'`,
which differs from `ρ` only in what `m` names (the cells and outer layers
the event wrote). One pass with `m` and the walk after it leave the block
consistent with `ρ'`: every hole shows its expression on the state after
the writes, every `derive` holds its own, and nothing waits. -/
theorem turn_static (α : Ref → Nat) (m : Mask) (ρ ρ' : E) (d : Nat) (t t' : S)
    (h : Ok ρ d t) (hw : Wrote t t') (ha : Agree α m ρ ρ') :
    Ok ρ' d (walk α ρ' d (pass α m ρ' d t')) :=
  go_ok α _ Mask.none ρ' ρ' d (agree_refl α _ ρ')
    (go_pre α false t' m ρ ρ' d ha (wrote_pre hw ρ d h))

/-- The lemma design.md states in words: a site the pass does not enter
(its reads miss everything the pass carries) is exactly as consistent after
the change as before it, waiting layers inside it included. -/
theorem unreached_shares_no_reader (α : Ref → Nat) (m : Mask) (ρ ρ' : E) (d : Nat) (t : S)
    (ha : Agree α m ρ ρ') (hmiss : hit α m (reads t) = false) (hp : Pre ρ d t) : Pre ρ' d t :=
  pre_congr t ρ ρ' d (fun r hr => ha r (not_hit (by simp [hmiss]) r hr)) hp

end Turns.Static

#print axioms Turns.Static.turn_static
