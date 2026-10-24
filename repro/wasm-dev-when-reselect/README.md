# `--target=wasm32 --opt=dev` does not remount a `Ui.when` branch it left

Upstream: [roc-lang/roc#12560](https://github.com/roc-lang/roc/issues/12560).

Reproduced with Roc `nightly-2026-10-23-18478ff` on macOS arm64.

`main.roc` holds a `Bool` state that starts `True` and a button that negates
it. A `Ui.when` on that state renders `on` or `off`. Clicking the button twice
should show `on`, `off`, `on`.

The same Zig host produces the expected sequence for every other build:

- native `--opt=dev`: `specs/toggle.scm` passes;
- `--target=wasm32 --opt=size`: the page shows `on`, `off`, `on`, `off`.

With `--target=wasm32 --opt=dev` the page shows `on`, `off`, `off`, `off`:
the state itself still toggles (rendering `Str.inspect` of the state signal
shows `True`, `False`, `True`, `False`), but once the `when` has switched to
its second branch it never switches back. No trap or runtime error is
reported.

## Reproduce

Natively, which passes:

```sh
python3 scripts/prepare_platforms.py
zig build build-test-hosts
roc build --target=arm64mac --opt=dev --output=.test-out/when-reselect repro/wasm-dev-when-reselect/main.roc
.test-out/when-reselect repro/wasm-dev-when-reselect/specs/toggle.scm
```

In Wasm, the `event-actions` fixture exercises the same switch-back through the
browser contract: its "Toggle actions" button hides and then re-shows a
`Ui.when` branch. Change the wasm suite's `--opt=size` to `--opt=dev` in
`scripts/test.py` (`build_wasm_apps`) and run `python3 scripts/test.py wasm`;
`event-actions` fails with `missing action button: Append snapshot` and the
rendered text ends in `Actions hidden`, and `svg` fails with `same-name
namespace change reused the wrong rendered node`.

The reproduction still depends on this platform; it has not been reduced to a
platform-free program.
