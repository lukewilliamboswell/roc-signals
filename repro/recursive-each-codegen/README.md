# Recursive keyed row code-generation crash

Reproduced with Roc `nightly-2026-09-09-7dadc35` on Apple Silicon macOS.

The app has a recursive nominal tree and renders its children through
`Ui.each`. The row builder dispatches a group back to the same group renderer.
Checking succeeds, while both native and Wasm code generation terminate with
`SIGSEGV` at fault address `0x3f8`.

```sh
ROC=/path/to/roc_nightly-macos_apple_silicon-2026-09-09-7dadc35/roc
"$ROC" check repro/recursive-each-codegen/main.roc
"$ROC" build -j1 --target=wasm32 --opt=size --no-cache \
  --output=/tmp/recursive-each.wasm \
  repro/recursive-each-codegen/main.roc
```

Replacing the call to `render_group` in the `Ui.each` row builder with a
nonrecursive element makes the build succeed. Wrapping that same call in the
existing zero-argument `Ui.component(|| ...)` thunk does not avoid the crash.

