# Boxed typed graph state: local spike

Run from the repository with `bash .test-out/boxed-graph/reproduce.sh`.
Sources and the generated Wasm stay in this ignored directory. This is an
architectural experiment, not a replacement engine or a maintained public API.

Initially tested with Roc `debug-886888c4`, then rebuilt and rerun with the
pinned `nightly-2026-09-12-220fd47`, Zig 0.16.0, Node 23.11.1 on x86-64 Linux.
Host: ReleaseFast; Roc app: wasm32, opt=speed, no cache. Reproduction defaults
to the installed pinned binary, with an explicit ROC_BIN override available.
Pinned output is recorded in `pinned-results.jsonl`.

## Boundary and ownership

Zig retains exactly one opaque `Box(Graph)` pointer. It clears its owner slot
before each consuming Roc call and installs the returned owner afterwards.
It never interprets Graph, nested Roc values, or their reference counts.
All value destruction occurs through an app-compiled Roc operation. Allocator
headers describe raw allocation sizes only, not Roc payload layouts.

Graph contains a boxed typed Payload and an optional list retaining its original
Payload. Payload contains numeric and string lists, a typed Dict keyed by
`{ owner : U64, ordinal : U64 }`, and four scalar diamond fields. Roc uses the
dictionary to resolve an update key to a numeric slot. No hash or key crosses
the host boundary. This is a fixed heterogeneous record, not an arbitrary
heterogeneous collection of user-defined Signal types.

The host's allocator counts calls and requested bytes. Its realloc explicitly
copies and counts those bytes. `realloc_copied_bytes` does NOT count compiler
emitted list/Dict copy-on-write copies or general memory.copy instructions.
Numbers below establish allocation scaling, not cycle attribution or a proof
that no bytes are copied anywhere. Header overhead is excluded from requested
bytes; allocator capacity and committed Wasm pages are not measured.

## Results

All sizes (1k, 10k, 100k numeric/string entries):

- 100 opaque handoffs: zero allocations/frees; exact outer pointer preserved.
- One unique update: two allocations/frees, 128 requested bytes.
- 100 separate updates: 200 allocations/frees, 12,800 requested bytes.
- 100 updates within one Roc call: two allocations/frees, 128 requested bytes.
- First update with original Payload retained: three allocations, one free,
  8*N + 136 requested bytes. Subsequent updates return to fixed allocation cost.
- Small inline strings, no snapshot: six live allocations for the whole model;
  drop-only releases six allocations at every size.
- Long heap strings, no snapshot: N+6 live allocations and N+6 drop-only frees.
  The setup creates each long string separately; this is deliberately not a
  string-sharing or interning experiment.
- Current values, untouched numeric slots, typed index entries, original numeric
  snapshots, and current strings are checked. Every scenario ends with zero live
  allocations and bytes. Drop-only is separate from validation: validating long
  strings itself allocates comparison literals on this compiler.

Before adding Dict, the same experiment used four live allocations with inline
strings and allocated 88 bytes per update call. The extra Dict adds two retained
buffers and grows the fixed Payload box.

## Unexpected dictionary construction cost

Despite Dict.with_capacity(N), this compiler allocates two buffers per insert.
For inline-string creation, requested allocation traffic was 28,468,564 bytes
at 1k and 2,511,531,252 bytes at 10k. Dot-call and explicit Dict.insert forms
both showed this. Allocation counts and traffic suggest copying of dictionary
storage; this spike does not identify the compiler/library cause. Do not treat
this as an accepted collection scaling strategy. No workaround was installed.

## What is and is not established

One opaque owner can contain typed bulk storage without per-value boxes, and
pure ownership transfer need not allocate. The current compiler reconstructs
the two enclosing boxes on update, with constant cost that batching amortizes.
Retaining the old flat numeric list introduces size-dependent allocation.

This does not yet implement the existing Signal/Ui API, arbitrary application
types, dynamic dependency construction, equality pruning, row lifetime/identity,
effects, scheduling, rendering, or recoverable transaction preparation. The
diamond is a fixed typed arithmetic operation, not a tested reactive scheduler.
OOM traps; there is no rollback protocol. These results cannot be compared as a
speedup against the full clear-table benchmark. They support investigating the
storage/ownership boundary, with generic composition and transactional sparse
updates still open.
