# Generic browser signal runtime-error reproducer

With Roc `nightly-2026-08-13-2fdd90e` installed:

```sh
zig build build-test-hosts
roc build --target=wasm32 --opt=size --no-cache \
  --output=/tmp/roc-signals-generic-browser-signal.wasm \
  repro/nightly-2026-08-13-generic-browser-signal/app.roc
node scripts/browser/mount_wasm_example.mjs \
  /tmp/roc-signals-generic-browser-signal.wasm minimal
```

The app builds without warnings, then mounting traps with `RuntimeError:
unreachable`; the platform reports `Roc crashed: hit a runtime error`.

Replacing `main` with static text mounts successfully:

```roc
main = || Html.text("ok")
```
