## Summary

A closure captures a record that holds a list. The closure passes the record to a function that matches on `List.replace`, rebuilds the record, and returns it in a tuple. The closure is then rebuilt from the result. Nothing else references the record or the list.

Under `--opt=speed` and `--opt=size`, the whole list is copied on every call. `--opt=dev` and the interpreter update it in place. Small, unrelated-looking edits to the source make the copy go away (see the table below).

This differs from #12841. There, two closures capture the same list. Here only one closure holds the list.

Compiler: `nightly-2026-11-03-34bd006`, Linux x86_64 (`x64musl`). I used the `test/alloc-count` platform from this repository. The engine this was reduced from shows the same copy on `wasm32`.

## Reproduction

Put `min.roc` next to `test/alloc-count/platform`:

```roc
app [run!] { pf: platform "./platform/main.roc" }

import pf.Host

# A closure captures a record holding a list. Each call replaces one element
# and rebuilds the closure from the result. Nothing else references the
# record, so List.replace and List.set should both update in place.
Block : { tag : U64, rows : List(U64) }

Root := [Root((U64 -> Root))]

step : Block, U64 -> (Block, U64)
step = |{ tag, rows }, x| {
	match rows.replace(0, 0) {
		Ok({ list, prev }) => ({ tag, rows: list.set(0, prev + x) ?? crash "rows" }, x)
		Err(_) => crash "rows"
	}
}

root : Block -> Root
root = |block| Root(|x| {
	(next, _) = step(block, x)
	root(next)
})

run! : Str => Str
run! = |input| {
	n = 1_000_000 + input.count_utf8_bytes()
	var $r = root({ tag: 0, rows: List.repeat(0, n) })
	before = Host.alloc_count!()
	var $i = 0
	while $i < 1000 {
		Root(f) = $r
		$r = f($i)
		$i = $i + 1
	}
	"1000 calls: ${(Host.alloc_count!() - before).to_str()} allocations"
}
```

```
$ roc build --opt=dev --no-cache min.roc && ./min        # 1000 calls: 0 allocations
$ roc build --opt=speed --no-cache min.roc && ./min      # 1000 calls: 1000 allocations  (~1.5 s: 8 MB copied per call)
$ roc build --opt=size --no-cache min.roc && ./min       # 1000 calls: 1000 allocations
$ roc build --opt=speed --specialize=no --no-cache min.roc && ./min   # 1000 calls: 2000 allocations
$ roc --opt=interpreter --no-cache min.roc               # 1000 calls: 0 allocations
```

## Expected

0 allocations in every mode, as with dev and the interpreter. The record is uniquely owned by the closure, and the closure is consumed by the call.

## Each of these single edits gives 0 allocations under speed and size

| Edit | speed / size |
|---|---|
| none (as above) | 1000 / 1000 |
| `root(step(block, x).0)` in place of `(next, _) = step(block, x)` | 0 / 0 |
| `{ list, prev } = rows.replace(0, 0) ?? crash "rows"` in place of the `match` | 0 / 0 |
| `step` returns `Block` rather than `(Block, U64)` | 0 / 0 |
| `Block : List(U64)` (no record) | 0 / 0 |
| the loop calls `step` directly with no closure | 0 / 0 |
| `match rows.set(0, x)` in place of `match rows.replace(...)` | 0 / 0 |

An `Err` arm that does not crash (for example `Err(_) => ({ tag, rows: [] }, x)`) still copies.

## Generated code

In the `--opt=speed --debug` binary, everything is inlined into `roc_run`. The loop body:

1. increments the refcount of `rows` (a non-atomic `inc` on the list header),
2. calls `list.RocList.makeUnique`, which now sees refcount 2 and copies the list (`hostAlloc` plus `memcpy`),
3. calls `roc_llvm_rc_decref_*` on the captured `{ tag, rows }` record after the step.

This looks like the captured record being treated as borrowed by the inferred signature of `step` (or of the closure body) even though `step` consumes `rows`. Optimized builds infer procedure ownership signatures (`owned_proc_signatures` is only set for dev in `src/cli/main.zig`), which would explain why dev stays in place. I have not confirmed this in the ARC passes, because the release compiler does not read `ROC_LIR_DUMP`.

## Impact

This came from a pure-Roc UI engine where each dynamic site is one closure that owns its state record. Every sparse update copied whole state lists and row columns. That is O(n) bytes per click (about 80 KB per click for a 10k-element `List(U64)`) in place of O(1). Working around it means avoiding a `match` on `List.replace` in every function that receives a captured record, which is hard to keep up across a large codebase.
