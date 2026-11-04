# Draft upstream issue (not filed): static storage for boxed non-capturing callables

Compiler: nightly-2026-11-01-48d3369, `roc build --opt=speed`, target x64musl.

A boxed callable with no captures allocates on every `Box.box`, identically to
a capturing one. Roc already has the notion of a constant heap object with
refcount zero for static data, and such a box would be immutable and shareable.

Minimized body, in a loop of 1,000 inside a reducer:

    boxed : Box((U64 -> U64))
    boxed = Box.box(|x| x + 1)
    f = Box.unbox(boxed)
    $acc = f($acc)

Measured Roc allocations per event: no box 34; non-capturing lambda 1,034;
top-level function 1,034; capturing lambda 1,034.

Request: emit `Box.box` of a capture-free callable as static, refcount-exempt
storage. Platforms that erase closures across a host boundary pay one allocation
per erased callable otherwise.

Scope note for Roc Signals: this alone removes 1 of the 4 boxes in
`Capability.new`, because `clone!`, `eq!` and `drop!` capture `split_handle`.
