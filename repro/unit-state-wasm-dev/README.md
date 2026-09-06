# Unit-state capability produces invalid dev Wasm

Reproduced with `nightly-2026-09-04-c125b82` and the Signals platform in this
checkout. No browser events, SVG, or dynamic structure are needed.

After building the platform hosts, run from the repository root:

```sh
"$ROC_BIN" build --target=wasm32 --opt=dev --no-cache \
  --output=.test-out/unit-state-dev.wasm repro/unit-state-wasm-dev/main.roc
node scripts/browser/validate_wasm.mjs .test-out/unit-state-dev.wasm
```

Roc reports successful compilation. WebAssembly validation rejects the output:
`expected 0 elements on the stack for fallthru, found 2`.
The function index and byte offset depend on the linked host artifacts.

Controls on the same platform and compiler:

- Replace `{}` with `Bool.False`: validation succeeds.
- Use `Html.text("Unit state")` without state: validation succeeds.
- Build the original unit-state app with `--opt=size`: validation succeeds.
- A string state with an `on_str` input validates in dev mode.
- A Boolean or integer state with an `on_unit` button fails in dev mode.

These controls implicate zero-sized unit values in the generated capability
callbacks, rather than state construction generally. The exact compiler cause
is not yet isolated. Do not replace unit payloads with a different type or
remove capability ownership operations to make the artifact validate.
