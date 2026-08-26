# Empty lambda set at a boxed-closure call

Upstream: https://github.com/roc-lang/roc/issues/PLACEHOLDER

With the pinned Roc nightly installed:

```sh
zig build build-wasm-host
roc build --target=wasm32 --opt=size --no-cache \
  --output=/tmp/roc-signals-empty-lambda-set.wasm \
  repro/empty-lambda-set-boxed-closure/app.roc
node scripts/browser/mount_wasm_example.mjs \
  /tmp/roc-signals-empty-lambda-set.wasm empty-lambda-set --exercise-click-first-link
```

The app builds with `0 errors and 0 warnings`, mounts, then traps on the first
click with `Roc crashed: hit a runtime error`.

`Capability.new_with_eq` boxes four closures (`split`, `clone`, `eq`, `drop`)
and hands them across the host boundary. Lambda-set specialization lowers a call
of each boxed closure to a `match` over its lambda-set variants; the set comes
back empty, so the match has zero branches and can only reach its failure
terminal. The crash fires on the first event dispatch because that is when the
host runs the capability's drop thunk.

`--target=x64musl` compiles the same way, so this is not wasm-specific.
