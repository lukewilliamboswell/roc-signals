# Upstream compiler bugs

Roc compiler and builtin bugs this repo has hit, with the workaround each one
forced on us. Every entry names the workaround site so the code can be
un-worked-around once the upstream fix lands.

Toolchain: the nightly pinned in `.roc-version`, which is what CI installs.
Individual entries record the versions on which they were reproduced; older
entries are historical evidence, not claims that every bug persists on the pin.
`scripts/dev/check-example.sh` and `scripts/test.py` both read `ROC_BIN`, so
point it at the pinned toolchain when reproducing:

```sh
export ROC_BIN=/path/to/pinned-roc/roc
```

| # | Bug | Upstream | Repro | Worked around |
|---|-----|----------|-------|---------------|
| 1 | `Json.parser_camel()` corrupts long field names on wasm32 | [#10957](https://github.com/roc-lang/roc/issues/10957) | `repro/json-camel-long-field-name/` | yes |
| 2 | flight-search double-frees its task payload on wasm32 | [#10958](https://github.com/roc-lang/roc/issues/10958) | — | yes |
| 3 | markdown-editor traps with `unreachable` in the browser | [#10959](https://github.com/roc-lang/roc/issues/10959) | — | yes |
| 4 | Empty lambda set at a boxed-closure call | not filed | `repro/empty-lambda-set-boxed-closure/` | n/a |
| 5 | Method-position dispatch rejects a nested nominal, printing two identical types | not filed | in-situ (below) | yes |
| 6 | `var $x = False` infers an open tag union, not `Bool`, so `!$x` fails method lookup | not filed | `repro/var-bool-inference/` | yes |
| 7 | A record-destructured binding loses method dispatch when two different `.map`s are called on it | not filed | in-situ (below) | yes |
| 8 | `List.sort_with` is a first-element-pivot quicksort, so it is O(n^2) on already-ordered input | not filed | `examples/data-grid` | yes |
| 9 | *(withdrawn -- was a misdiagnosis; see below)* | n/a | n/a | n/a |
| 10 | Unit-state capability callbacks produce invalid dev Wasm | not filed | `repro/unit-state-wasm-dev/` | no; size backend validates |

For #1, camelCase field names longer than ten bytes are corrupted on wasm32 at
byte four, while native is unaffected; `favoritesCount` exposed it. For #2, the
first flight-search task result double-frees its exact-length string payload on
wasm32 while native passes. For #3, markdown-editor traps during wasm32 mount
while all native specs pass. Their linked upstream issues carry the reductions
and current status. Bug #4 has a `README.md` beside its repro.

---

## 5. Method-position dispatch rejects a nested nominal, printing two identical types

**Status:** not filed upstream. Found 2026-08-27 while converting the examples
to idiomatic tag unions. Reproduces on both `nightly-2026-08-25-cc03aa8` (pinned)
and `nightly-2026-08-26-b29bef3`.

A function returning a nominal type that is declared *inside* another nominal
module is rejected in method-call position, but accepted in call position. The
error prints the expected and actual types character-for-character identically,
so it carries no diagnostic information.

### Reproduce

In `examples/support-inbox/main.roc:458`, change the call form to the method form:

```sh
cd /path/to/roc-signals
sed -i '458s/.*/\t\t\t\t\t\t\tsend_req_sig = session_sig.map(Inbox.send_request)/' \
  examples/support-inbox/main.roc
./scripts/dev/check-example.sh support-inbox
```

`Inbox.send_request : Inbox.Session -> Inbox.SendRequest`, where
`SendRequest := [NoSend, Send(Str)]` is declared inside the nominal module
`Inbox` (`examples/support-inbox/Inbox.roc:139`).

Output:

```
── ✗ type mismatch ─ .../support-inbox/main.roc:458:23

This expression is used in an unexpected way.

send_req_sig = session_sig.map(Inbox.send_request)
               ^^^^^^^^^^^

It has the type:

    c
      where [
        c.map : c, ({ dead: List(Str), draft: Str, last_cid: Str, pending:
        List(Inbox.Pending), selected: Str, seq: U64 } -> Str) -> _ret,
      ]

But you are trying to use it as:

    c
      where [
        c.map : c, ({ dead: List(Str), draft: Str, last_cid: Str, pending:
        List(Inbox.Pending), selected: Str, seq: U64 } -> Str) -> _ret,
      ]
```

Two things to note beyond the identical types: the printed result type is `Str`,
not `Inbox.SendRequest` — the nominal appears to have been collapsed to its
payload — and the constraint shown is the *method* constraint `c.map`, so this
looks like static-dispatch constraint solving rather than plain unification.

### Workaround

Use call position. `examples/support-inbox/main.roc:458` is therefore:

```roc
send_req_sig = Signal.map(session_sig, Inbox.send_request)
```

rather than the `session_sig.map(...)` used by every neighbouring line.

### Minimisation notes (for whoever fixes this)

It did **not** reproduce when reduced. All of the following type-check clean,
so none of them is the trigger on its own:

- a hand-rolled `Holder := [...]` with a `map` method returning the nested nominal;
- the same, with `map`'s result constrained by `where [b.is_eq : b, b -> Bool]`,
  matching `platform/Signal.roc:234`;
- the real `Signal`/`Ui.state` graph mapping a nested nominal, both with the
  result unused and with it consumed downstream.

So the trigger needs something further from `support-inbox` — plausibly the size
of the `Inbox` module or the number of sibling bindings in the same block. The
in-situ reproduction above is reliable.

---

## 6. `var $x = False` infers an open tag union, so `!$x` fails

**Status:** not filed upstream. Found 2026-08-27 in `examples/spreadsheet-lite`.

A `var` initialised to a bare `False` (or `True`) infers an *open* tag union
rather than `Bool`, so calling the `!` method on it fails method lookup. Note
the inferred type does pick up both tags from the later assignment — it is
`[False, True, ..]`, structurally a superset of `Bool` — but the open extension
variable is enough to defeat method lookup.

`repro/var-bool-inference/Repro.roc`:

```roc
f : U64 -> Bool
f = |n| {
	var $flag = False
	if n > 3 {
		$flag = True
	}
	!$flag
}
```

```
── ✗ missing method ─ Repro.roc:9:2

This not method is being called on a value whose type doesn't have that method.

!$flag
^^^^^^

The value's type, which does not have a method named not, is:

    [False, True, ..]
```

### Workaround

Annotate the var, or avoid `!` on it. `examples/spreadsheet-lite/Cells.roc`
previously carried module-level `no = False` / `yes = True` aliases purely to
give the vars a `Bool` type; they were replaced by inverting the flags so they
are named positively and never need `!` (`$closed` became `$open`).

---

## 7. A record-destructured binding breaks method dispatch, printing two identical types

**Status:** not filed upstream. Found 2026-08-27 while grouping positional
arguments into record parameters in `examples/pomodoro-tracker`.

Binding a value out of a record by *destructuring* (`{ run } = ctx`) and then
calling two differently-typed methods on it fails, where binding the same value
by *field access* (`run = ctx.run`) succeeds. Like #5, the error prints the
expected and actual types character-for-character identically — and here it also
prints the *wrong* function type: the annotation of the sibling `.map` call
(`RunState -> Str`) is reported for a call whose argument is `RunState -> Bool`.

### Reproduce

In `examples/pomodoro-tracker/main.roc`, replace the field-access preamble of
`board` with the destructuring form:

```roc
board = |b, extras| {
	{ ctx, ledger, ticks } = b
	{ attach, run, attached } = ctx
	run_signal = run.signal()
	...
```

```sh
./scripts/dev/check-example.sh pomodoro-tracker
```

Output:

```
── ✗ type mismatch ─ .../pomodoro-tracker/main.roc:372:9

run_signal.map(is_idle),
^^^^^^^^^^

It has the type:

    d where [d.map : d, (RunState -> Str) -> Signal(Str)]

But you are trying to use it as:

    d where [d.map : d, (RunState -> Str) -> Signal(Str)]
```

`run_signal` is mapped twice in the same block: `run_signal.map(run_text)` and
`run_signal.map(run_badge_class)` return `Signal(Str)`, while
`run_signal.map(is_idle)` returns `Signal(Bool)`. Only the last one is rejected,
and only when `run` reached the block through a destructuring pattern. A
parameter-position pattern (`board = |{ ctx, ledger, ticks }, extras|`) fails the
same way.

### Workaround

Bind through field access (`run = b.ctx.run`), which is what
`examples/pomodoro-tracker/main.roc` now does. The call form
(`Signal.map(run_signal, is_idle)`) also works, as it does for #5.

A standalone repro under `repro/` did not reproduce with a hand-rolled nominal
`Box(a)` and a plain record, so the trigger needs something more than
"destructure a record, then call two methods" — the in-situ reproduction above
is reliable.

---

## 8. `List.sort_with` degrades to O(n^2) on ordered input

**Status:** not filed upstream. Found 2026-08-27 when `examples/data-grid` was
switched from its hand-rolled merge sort to the builtin.

`List.sort_with` is a naive quicksort that takes the **first element** as its
pivot, and partitions with **two** `keep_if` passes (so 2n comparisons per
level, plus a fresh list allocation for each partition and a `concat` to
rejoin):

```roc
Ok(pivot) => {
    rest = List.drop_first(list, 1)
    less_or_equal = List.keep_if(rest, |item| ... LT => True, EQ => True, GT => False)
    greater       = List.keep_if(rest, |item| ... LT => False, EQ => False, GT => True)
    List.concat(List.sort_with(less_or_equal, order), ...)
}
```

First-element pivoting makes **already-sorted input the worst case**, which is
the common case for a UI list that is regenerated in key order and sorted by
that same key. It also recurses to depth n there.

Measured on `examples/data-grid` (1200 rows generated in id order, default sort
by id ascending): `specs/initial-mount.scm` went from **68 ms to 68,751 ms** —
roughly a thousandfold regression. Every other data-grid spec exceeded the
30 s spec timeout.

### Workaround

`examples/data-grid/GridData.roc` keeps a hand-rolled merge sort and a comment
saying why. `examples/flight-search` still uses `sort_with`, which is fine: it
sorts a handful of rows.

A median-of-three pivot, or a single partitioning pass, would fix the common
case upstream.

---

## 9. WITHDRAWN -- was a misdiagnosis

This entry previously claimed that adding any import to `platform/Ui.roc`
corrupted `loan-comparator`'s values. **That was wrong**, and the entry is kept
only so the claim is not repeated.

The real cause is a host regression, not a compiler or import problem:
`5fe35ad Optimize bulk keyed structural updates` breaks
`examples/loan-comparator/specs/editing-scenario-c-does-not-disturb-a-or-b.scm`.

```
git bisect over 04f5c02..8ef18cf, `python3 scripts/test.py native`

04f5c02  Replace stringly-typed state with tag unions (batch 3)   269 pass, 0 fail
ea3ff9b  Add js-framework benchmark fixture                       269 pass, 0 fail
5fe35ad  Optimize bulk keyed structural updates                   110 pass, 1 FAIL  <-- first bad
e0cfd71  Document engine profiling workflow                       110 pass, 1 fail
11e2d82  Index custom attributes in large descriptor streams      110 pass, 1 fail
8ef18cf  Intern render cache tag names                            110 pass, 1 fail
```

```
TEST FAILED at line 33:
  Expected text: "Month 1 | interest $12.00 | principal $194.56 | balance $2205.44"
  Got text:      "Month 1 | interest $12.00 | principal $2400.00 | balance $0.00"
```

Line 33 asserts on **scenario A** inside the spec that checks *editing scenario C
does not disturb A or B*, so an edit to C bleeds into A and A's first month
clears its whole balance. That is a keyed-row identity problem, which matches
what `5fe35ad` changed: `engine.zig` (+192), `host_value_registry.zig`,
`identity_table.zig` and `structural_splice.zig`.

### Why the original diagnosis was wrong

Every experiment was run in a worktree created from a `HEAD` that already
contained `5fe35ad`, so the spec failed no matter what was changed -- an added
import, an added function with no import, and even a comment-only edit all
"reproduced" it. The control that would have caught this, an unmodified worktree
at the *current* `HEAD`, was not run; the passing control being compared against
was from an earlier `HEAD` predating the host commit.

**Lesson for this file: pin the control to the same commit as the experiment.**

## 10. Unit-state capability callbacks produce invalid dev Wasm

Reproduced on `nightly-2026-09-04-c125b82`: a `Ui.state({}, ...)` app
compiles successfully with `--opt=dev`, but Node and Chromium reject the
artifact with `expected 0 elements on the stack for fallthru, found 2`.
Boolean state without an event handler and a string input validate; adding a
unit event handler also reproduces the failure. The size backend validates
the same unit-state app. The exact compiler cause remains unisolated.

See `repro/unit-state-wasm-dev/README.md` for commands and controls. Site builds
now validate the generated Wasm instead of treating compiler exit status as
proof of a usable artifact. No platform semantic workaround has been applied.

## Not compiler bugs — missing builtins

These cost time this session because they look like they should exist. They are
API gaps, not defects; recorded so nobody re-derives them.

| Expected | Reality |
|---|---|
| `Try.unwrap_or` / `Try.with_default` | Absent. Use **`Try.ok_or(try, fallback)`** (call position; `Try` exposes `map_ok`/`map_err` as methods). |
| `Try.and_then` / `Try.or_else` | Absent. `Try.on_err` covers the error-side case; otherwise `match` or `?`. |
| `List.reverse` | Absent. Build the list in the wanted order, or `fold` + `concat`. |
| `U64.max_value` / a max constant | Absent. `U64.max : U64, U64 -> U64` is a two-argument "greater of". Model "no limit" as a tag instead of a sentinel literal. |
| `_` in a type alias declaration | Rejected ("Underscores are not allowed in type alias declarations"). Use an inline record annotation at the signature instead. |
| calling a function held in a record field | `rec.f(x)` parses as a *method* lookup on `rec` and fails. Parenthesise the field: `(rec.f)(x)`. |
| `Str` ordering | There is no `Str.compare` / `compare_to` / `order` in this build, and `Str` has no `compare` method. Comparing strings for sort order means hand-rolling a byte comparison. |

Present and used, for contrast: `U64.compare`, `U64.from_str`, `Str.contains`,
`List.find_first`, `List.keep_if`, `List.map2`, `List.all`, `List.any`,
`List.contains`, `List.join_map`, `Try.ok_or`, `Try.map_ok`, `Try.map_err`,
`Try.is_ok`, and the `?` operator.
