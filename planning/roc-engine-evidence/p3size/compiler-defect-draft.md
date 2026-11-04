# Draft upstream issues (not filed), nightly 2026-11-03-34bd006

## 1. Calling a closure from a borrowed position emits a second specialisation of its body

`roc build --opt=size` (and speed), wasm32 and x64musl.

In a self-rebuilding closure object (`Inst(ctx) := [Inst((ctx, Msg, Tx -> (Inst(ctx), Out(ctx), Tx)))]`),
every closure body was emitted twice. The cause was one call site that invoked a
child closure while iterating a list (`for kid in kids { Engine.call(kid, ...) }`,
so `kid` is borrowed). Every other call site takes the closure out of its list
with `replace` (owned). After the borrowed call site was changed to the same
owned `replace` pattern, each closure body (and everything inlined into it) is
emitted once.

Evidence (DWARF inline tree, native `--debug`; wasm sizes after `wasm-opt -Oz`):

| engine | `\ in each_inst` / `each_changed` copies | jfb wasm -Oz |
|---|---|---|
| p3e (borrowed `for kid in kids` in dispose) | 2 / 2 | 349.6 KB |
| p3e-own (owned `replace` loop) | 1 / 1 | 297.0 KB |
| p2 engine (unchanged) | 2x everything | 463.5 KB |
| p2-own (only the three borrowed child-call loops changed) | 1x | 326.8 KB |

Allocation counts for p2 vs p2-own are identical in all 28 measured steps.

The borrowed call happens only on the Dispose path, but it doubles the whole
reachable closure body for every site kind. Expected: either one
specialisation that borrows its captures, with ownership handled at the call
site, or the borrowed variant only for the procs that the borrowed path
reaches.

Repro: `p3size/src/Engine.p3e.roc` vs `Engine.p3e-own.roc` (the diff is
`tools/ownfix.py`), built by `p3size/build.sh` with `apps/jfb-p2`.

## 2. Every proc is `inlinehint`; under `--opt=size` this makes helper code scale with the number of callers

`src/backend/llvm/MonoLlvmCodeGen.zig` gives every non-wrapper proc the
`inlinehint` attribute. Under the `Oz` pipeline, LLVM still applies the hint
threshold (325) unless the function has `minsize`. Small monomorphic helpers
(index insert/remove, command writers, `put_u32` with four `append`s) are
therefore copied into every typed caller. In the p2 jfb build, `put_u32` was
inlined 141 times and `create_row` 9 times. There is no source-level way to
keep a function out of line. The workarounds have large costs:

- A boxed (erased) call keeps a function out of line but marshals every
  argument through memory, so it grew the build: lib1 was +14 KB over p3a.
- A self-recursive guard keeps a function out of line, because LLVM will not
  inline a recursive function. It also grew the build, by the per-call-site
  argument marshalling: p3n was +36 KB.

Request: `--opt=size` should emit `minsize` (or omit `inlinehint`), or provide
a `noinline` escape hatch.

## 3. (Context) Calls pass records through memory

Each out-of-line call stores every word of every record argument and reloads
the result. In the wasm opcode histogram of the biggest typed function,
`local.get`/`load`/`store` are about 70% of 19k instructions. With records of
17 to 45 words (Tx, EachCore), an out-of-line call costs about 0.5 KB per call
site. This is why moving code out of line does not shrink the build. It is
not a defect on its own, but it compounds issue 2.

## 4. (Context) An erased call allocates when closures cross it unboxed

Calling a boxed function whose arguments contain lambda-set closures (for
example a record holding `item -> Str`) allocated once per call: p3b
`create_row` added +1 allocation per created row. Pre-boxing the closures
avoids most of this. The p3h variants still pay +2 allocations on select
events, and the source was not isolated.
