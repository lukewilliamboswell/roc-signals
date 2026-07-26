# Canonical location branch regression

This is the focused regression for a nested browser-location update that used
to lose a structural `Ui.when` refresh.

The failing sequence is:

1. mount on `/services/workers`, where the detail branch is active;
2. externally navigate to `/services/missing`;
3. an `Ui.on_change` canonicalizes that location with
   `Browser.replace_state("/")` in the same host turn.

Before the engine fix, the host URL and ordinary `Path: /` text signal updated,
but the detail branch remained mounted and `spec.txt` failed at the overview
assertion. `direct.spec.txt` is the control: navigating directly to `/` updates
the same `Ui.when` without a nested host-source redispatch. Both now pass.

```sh
zig build build-test-hosts
roc build --target=arm64mac --opt=dev \
  --output=/tmp/location-canonical-branch app.roc
chmod +x /tmp/location-canonical-branch
/tmp/location-canonical-branch spec.txt
/tmp/location-canonical-branch direct.spec.txt

roc build --target=wasm32 --opt=size \
  --output=/tmp/location-canonical-branch.wasm app.roc
node ../../../scripts/browser/mount_wasm_example.mjs \
  /tmp/location-canonical-branch.wasm location-canonical-branch \
  --exercise-location-canonical-branch
```

The original repro failed identically with Roc's dev and LLVM speed backends.
The fix defers location/storage source redispatch until structural work from the
triggering dirty generation has applied, confirming this was a roc-signals
engine transaction-ordering bug rather than a Roc compiler bug.
