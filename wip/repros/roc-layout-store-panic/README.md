# Optimized wasm compiler panic

This is a self-contained reduction of the panic found while compiling the
RealWorld team-checkout example. The directory includes the reduced platform
sources and wasm host needed by `app.roc`; it does not depend on files elsewhere
in the roc-signals repository.

## Reproduce

From the roc-signals repository root, run:

```sh
roc build --target=wasm32 --opt=size --no-cache \
  --output=/tmp/roc-layout-store-panic.wasm \
  wip/repros/roc-layout-store-panic/app.roc
```

`roc check --no-cache wip/repros/roc-layout-store-panic/app.roc` succeeds, but
the optimized wasm build panics.

The original release compiler (`release-fast-afbc7863`) reported:

```text
layout.Store invariant violated: struct field original index ... not found in struct ...
```

The current debug compiler at Roc commit `e7495afb2a` catches the bad state
earlier in capture recomputation, with messages including:

```text
postcheck invariant violated: lifted capture set contained two slots with the same CaptureId
```

The reduction contains two nested heterogeneous `Ui.state` calls. Each state
is combined with a storage signal through a record-derived signal and consumed
by an `Ui.on_change` closure. Removing one pair still produces a later ARC
certifier panic, while retaining both exposes the capture-recomputation failure
that is closest to the original compiler panic.
