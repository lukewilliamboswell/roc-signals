## Phase 0b report: typed-sites API sketch

**Verdict: continue.** The canary type-checks without host ids, without per-row closures and without hidden correctness rules. The static rule that `each_template` only enforced with a runtime panic is now a type parameter. All 5 requested apps pass `roc check` and `roc test` on nightly-2026-11-01-48d3369 (the newest; no newer one exists). I also wrote a 6th app, a recursive tree, because writing one exposed a real limit (point 5 under awkward points).

The remaining hidden rules are about cost, not meaning (listed below). The sketch adds one rule-bearing primitive the plan didn't name: `Ui.tree`.

### Where things are
- Sketch platform: `/home/lbw/Documents/Github/roc-signals/.claude/worktrees/agent-a80c03d762a27fddc/platform-sketch/`. It is new and untracked; no existing platform module or `design.md` was touched.
  - Modules: `main.roc`, `Elem.roc`, `Val.roc`, `Signal.roc`, `Node.roc` (private), `Ui.roc`, `Html.roc`, `Action.roc`. `Rows.roc` is copied unchanged.
  - Apps are in `examples/{counter,js-framework-benchmark,canary (main.roc + TaskRow.roc),form,nested-each,tree}`.
  - Negative probes are in `examples/neg/`.
- Copy of everything: `/tmp/claude-1000/-home-lbw-Documents-Github-roc-signals/3be5123c-58c0-43c7-9279-7606a00fb469/scratchpad/spike-results/roc-engine/p0b/`. It includes `check-log.txt` (all check/test output plus negative-probe errors) and `compiler-repros/`.
- I read the App-Facing API and examples sections of `design.md`, not the whole file.

### API summary (key signatures)
```roc
Elem(ctx)                      # ctx = Ui.Root, or Ui.Site(outer, item) inside a row
Ui.Root ; Ui.Site(outer, item) # opaque; the engine builds a Site from its columns
Val(ctx, a)                    # a value per context: site-level or row-level
  to_val, const, map, map2     # map2 makes `{ a: x, b: y }.Val` work
Signal(a)                      # unchanged, site-level; Signal.to_val : Signal(a) -> Val(ctx, a)
Signal.keyed : Signal(Str), v, v -> Signal.Keyed(v)

Ui.each : r, (Ui.RowRef(ctx, item) -> Elem(Ui.Site(ctx, item))) -> Elem(ctx)
  where [r.to_val : r -> Val(ctx, Rows(item)), item.is_eq]   # builder runs ONCE per site
Ui.RowRef(outer, item):
  key    : -> Val(Site(outer,item), Str)
  field  : (item -> a) -> Val(Site(outer,item), a)
  item   : -> Val(Site(outer,item), item)
  select : Signal.Keyed(v) -> Val(Site(outer,item), v)        # changes only old and new key
  outer  : Val(outer, a) -> Val(Site(outer,item), a)          # lift for nested each
  outer_handler : Handler(outer) -> Handler(Site(outer,item))
Ui.tree : r, (RowRef(Up(ctx,node), node) -> Elem(Site(Up(ctx,node), node))) -> Elem(ctx)
Ui.children : RowRef(Up(ctx,node), node), (node -> Rows(node)) -> Elem(Site(Up(ctx,node), node))
Ui.state : a, (Ui.State(a) -> Elem(Ui.Root)) -> Elem(Ui.Root)   # root only, by type
Ui.local : a, (Ui.RowState(ctx, a) -> Elem(ctx)) -> Elem(ctx)   # one typed column per site
Ui.when  : c, (() -> Elem(ctx)), (() -> Elem(ctx)) -> Elem(ctx) where [c.to_val : c -> Val(ctx, Bool)]
Ui.switch, Ui.component        # same idea
Ui.State(a): signal; update : (a -> a) -> Handler(ctx)          # any ctx
  update_by : v, (a, b -> a) -> Handler(ctx) where [v.to_val : v -> Val(ctx, b)]
  update_str, update_str_by, update_bool, update_bool_by, write, set
Ui.RowState(ctx, a): to_val/val; update, update_str -> Handler(ctx)  # bound to its context
Ui.Handler(ctx), Html.Attr(ctx)   # public aliases (fixes the canary's unnameable handler)
Html._s helpers : v -> ... where [v.to_val : v -> Val(ctx, T)]   # take a Signal, Val or RowState
Html.element : Str, List(Attr(ctx)), List(Elem(ctx)) -> Elem(ctx)   # public
Action.run : v, (a -> Action(a)) -> Handler(ctx) where [v.to_val : v -> Val(ctx, a)]
```
Handlers read the row when they fire, for example `model.update_by(row.key(), remove_row)`. For two keys in a nested each it is `model.update_by({ group: item.outer(group.key()), item: item.key() }.Val, remove_item)`.

### Results per app

| App | `roc check` | `roc test` |
|---|---|---|
| js-framework-benchmark (run, runlots, add, update every 10th, clear, swap, select, remove) | pass | pass |
| canary (`TaskRow.roc` packaged; record of independent `Val`s, static `Config`, caller `Callbacks(ctx)`, two conditional children, one with row-local state; the same component also used at Root) | pass | pass |
| counter | pass | pass |
| form (derived error text, disabled submit, record builder over signals) | pass | pass |
| nested-each (groups → items, two-key handler, outer value lifted) | pass | pass |
| tree (`Ui.tree`) | pass | pass |

- Each app has an `expect` that evaluates `main()` and checks a structural description. It confirms each row template exists once per site, with holes rather than rows, for example `{each <tr:3><td:1>{val}</td>...}`.
- An `expect` in `Ui.roc` evaluates one `row.field` and one `row.select` against two row contexts. I broke its expected value on purpose and it failed.

### Kill gate
- **Host ids:** none.
- **Per-row closures:** none. Templates, `map` closures and handlers are built once per site.
- **Hidden correctness rules:** none. The context type enforces them, and the negative probes in `examples/neg/` confirm it:
  - a row value used outside its row, or an outer-row field used without `outer`: "Elem(Ui.Site(GroupCtx, Item)) vs Elem(Ui.Site(Ui.Root, Group))";
  - `Ui.state` inside a row: "...-> Elem(Ui.Site(...)) but needs -> Elem(Ui.Root)";
  - capturing the key in a closure: "Val(Ui.Site(..), Str) but remove needs Str";
  - interpolating the key into a string: the same kind of error.

**Hidden cost rules the types don't show:**
1. `map2` of a site signal with a row field re-evaluates every row when the signal changes. Selection must use `row.select`.
2. `Ui.switch` builds one template per distinct case value, so a case carrying row data falls back to one template per row.
3. Key-derived attributes such as `key.map(|k| "row-${k}")` allocate a `Str` per row per attribute. The benchmark row has 3 of these (test-id and two aria-labels), which matters for the "≤3 allocations per row" gate. The real benchmark doesn't need them.

### Awkward points
1. **`.to_val()` at the root.** A component's input record wants `Val`, but a record field is not a `to_val` dispatch site, so root callers write `title: sig.to_val()`. The error here is also misreported because of compiler bug B.
2. **Let-bound values are not generalized.** A `Val` bound once and used at two depths fails with an unreadable "infinite type / RecursiveType" error (probe n7). The rule is to keep site values as `Signal` and let helpers convert them; it is not visible in the types.
3. **Helpers annotated `Elem(Ui.Root)` can't be reused in rows** (probe n4). Static helpers must be written as `Elem(ctx)`. The error is readable.
4. **Nested types are long.** Context aliases are essentially required, for example `GroupCtx : Ui.Site(Ui.Root, Group)` and `ItemCtx : Ui.Site(GroupCtx, Item)`. Outer values need explicit `item.outer(...)`. Unannotated mistakes give errors about recursive types at `|model|`, not at the fault (probe n1).
5. **Recursive trees can't use nested `Ui.each`.** Each depth is a new context type, which is polymorphic recursion. It type-checks in isolation, but the compiler hangs (bug A), and monomorphization could not compile it anyway. `Ui.tree`/`Ui.children` with a fixed-point context `Up(outer, node)` solves it. An author writing the old way gets a hang, not an error.
6. **Reducer names multiply.** Each payload kind needs a `_by` variant (`update_str_by`, `update_bool_by`, ...). `Action.run(reads, ...)` covers the general case.
7. **Conflicts with `design.md`.**
   - `Ui.Row(item)` and per-row signals are replaced.
   - The per-row `Ui.state` in the design's todo example must become `Ui.local`.
   - `Elem` gains a type parameter, so every `Elem` signature in the docs and examples becomes `Elem(ctx)`. The migration is large but mechanical.

### How the hard cases map onto typed columns
- **Conditional child** (`Ui.when` over a row `Val`):
  - Both branches are built once per site.
  - Per row: one `Bool` column, plus a sparse per-row branch-instance table holding the mounted branch's DOM ids and any `Ui.local` columns inside it. **This is the per-row fallback path.** It is allocated only for rows whose selected branch is non-empty, and a branch swap mounts or disposes for that row only.
- **`Ui.local` in a row:** one typed column per site. The initial value is a site constant.
- **Nested each:**
  - The inner template is built once.
  - Storage is one inner column set per outer row (items, key index, DOM ids), keyed by outer slot.
  - Inner deltas come from the `Rows` generation chain of the outer item's field. So inner edits must be `Rows.apply` on the old inner `Rows` to stay proportional to the change. Apps must keep `Rows` inside items.
- **Tree:** one site whose rows carry a parent slot, each with a children list as above.

### Assumptions the engine (Phase 0a) must satisfy
1. A site's builder runs exactly once. Templates capture site-level things (state handles, config, signals), never rows.
2. To evaluate a `Val` or fire a handler, the engine builds a `Site{outer, key, item}` from its columns. For nested sites it walks the outer chain, so it needs the outer slot.
3. The engine tells `SiteVal` from `RowVal` when dirtying. `select` dirties only the old and new key. A site signal mixed into a row value dirties all rows, and the metrics must show that honestly.
4. Each row-level hole is equality-pruned per row, which needs the last value per hole per row, or a compare against the stored item.
5. A handler fires from DOM node → row slot → context. The row is live when the handler fires; Action effects snapshot their reads at that moment.
6. `Ui.component` inside a template needs no per-row scope beyond the row itself: identity is template position plus key.
7. Erasure happens once per site. `Elem` holds an `ErasedSite(ctx)` record of closures, and the item, case or state type is hidden inside it.

### Compiler bugs (drafted, not filed)

**A. Annotated polymorphic recursion makes the compiler run forever instead of reporting an error.**
- Repro, `compiler-repros/PolyRec.roc`:
  ```roc
  PolyRec := [].{
      Nest(ctx) :: [Nest(ctx)]
      depth : ctx, U64 -> U64
      depth = |ctx, n| if n == 0 { 0 } else { 1 + depth(Nest(ctx), n - 1) }
  }
  expect PolyRec.depth({}, 3) == 3
  ```
- `roc check` passes; `roc test` never finishes (killed after 15 s).
- In an app, `roc check` itself hangs: see `examples/neg/p8b_recursive_each_min.roc`, a 13-line app against the sketch platform. An earlier 300 s run of `p8_recursive_tree.roc` was killed with exit 137, likely out of memory.
- In that app, replacing the root each's `Rows` source with `crash` makes it pass.
- Expected: a type error saying polymorphic recursion isn't supported, or a finite result.

**B. A type mismatch on a single punned record field prints the field's type as the argument's type.**
```roc
Repro := [].{
    Inputs : { title : U64 }
    view : Inputs -> Str
    view = |_inputs| "ok"
    bad : Str -> Str
    bad = |title| view({ title })
}
```
- Reported: "This argument has the type: Str. But view needs: Repro.Inputs".
- Expected: `{ title: Str }`.
- `{ title: name }` (not punned) and multi-field records report correctly.
