# Upstream compiler bugs

Roc compiler and builtin bugs this repo has hit, with the workaround each one
forced on us. Every entry names the workaround site so the code can be
un-worked-around once the upstream fix lands.

Toolchain: the nightly pinned in `.roc-version` (currently
`nightly-2026-08-25-cc03aa8`), which is what CI installs.
`scripts/dev/check-example.sh` and `scripts/test.py` both read `ROC_BIN`, so
point it at the pinned toolchain when reproducing:

```sh
export ROC_BIN=/path/to/roc_nightly-linux_x86_64-2026-08-25-cc03aa8/roc
```

| # | Bug | Upstream | Repro | Worked around |
|---|-----|----------|-------|---------------|
| 1 | `Json.parser_camel()` corrupts long field names on wasm32 | [#10957](https://github.com/roc-lang/roc/issues/10957) | `repro/json-camel-long-field-name/` | yes |
| 2 | flight-search double-frees its task payload on wasm32 | [#10958](https://github.com/roc-lang/roc/issues/10958) | — | yes |
| 3 | markdown-editor traps with `unreachable` in the browser | [#10959](https://github.com/roc-lang/roc/issues/10959) | — | yes |
| 4 | Empty lambda set at a boxed-closure call | not filed | `repro/empty-lambda-set-boxed-closure/` | n/a |
| 5 | Method-position dispatch rejects a nested nominal, printing two identical types | not filed | in-situ (below) | yes |
| 6 | `var $x = False` infers an open tag union, not `Bool`, so `!$x` fails method lookup | not filed | `repro/var-bool-inference/` | yes |

Details for 1-3 are in `wip/example-visual-polish-findings.md`; 4 has its own
`README.md` beside its repro.

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

Present and used, for contrast: `U64.compare`, `U64.from_str`, `Str.contains`,
`List.find_first`, `List.keep_if`, `List.map2`, `List.all`, `List.any`,
`List.contains`, `List.join_map`, `Try.ok_or`, `Try.map_ok`, `Try.map_err`,
`Try.is_ok`, and the `?` operator.
