`roc check` segfaults on pinned `nightly-2026-09-12-220fd47` when a constant call
round-trips a boxed getter through declared hosted functions and invokes it.
No host is executed or needed to reproduce this checking failure.

Expected: type-check, or issue a diagnostic if this use is unsupported; never
invoke an unavailable hosted result as a callable while checking. The last
sentence is a hypothesis about the failure mechanism, not a compiler diagnosis.

`main.roc`:

```roc
app [main] { pf: platform "platform/main.roc" }
import pf.Erased

roundtrip : U64 -> U64
roundtrip = |n| {
    hidden = Erased.erase!(Box.box(|| n))
    getter : Box((() -> U64))
    getter = Erased.restore!(hidden)
    (Box.unbox(getter))()
}

main : () -> U64
main = || roundtrip(41)
```

`platform/main.roc`:

```roc
platform ""
    requires {} { main : () -> U64 }
    exposes [Erased]
    packages { roc: "nightly-2026-09-12-220fd47" }
    provides { "result": result }
    hosted { "erase": Erased.erase!, "restore": Erased.restore! }
    targets: { inputs_dir: "targets/", wasm32: { inputs: ["host.wasm", app], exports: [] } }

import Erased
result : () -> U64
result = || main()
```

`platform/Erased.roc`:

```roc
Erased := Box((() -> {})).{
    erase! : Box((() -> a)) -> Erased
    restore! : Erased -> Box((() -> a))
}
```

Run `roc check main.roc` on Linux x86-64. It exits 139:

```text
Segmentation fault (SIGSEGV) in the Roc compiler.
Fault address: 0x0
```

In the larger experimental platform, calling an ownership probe with a literal
seed crashes during checking; calling it with an incoming runtime event value
instead checks, builds, and executes in unoptimized Wasm. The real runtime
restore primitive checks an ownership token before returning the callable; the
reproducer omits those checks to isolate the compiler failure, and is not a
proposed safe erasure API.
