# Command Wire Live Mount Telemetry

Captured: 2026-07-05.

Purpose: keep the command-wire string-dedupe hypothesis measurement-gated. This
snapshot is evidence for keeping string dedupe deferred unless later app action
telemetry shows string traffic dominating the remaining structural tail.

## Focused Gates

For evidence-only edits that do not change telemetry totals or current-state
claims, run:

```sh
git diff --check
zig build run-check-tidy
```

Run the static framing estimate:

```sh
node wip/research/wire_protocol_dynamic_size_estimate.mjs
```

Run the live mount sampler by first building wasm artifacts, then sampling each
public wasm app (`public = true`, `wasm = true`) listed in
`www/data/examples.toml`:

```sh
python3 scripts/test.py wasm --keep-output
node scripts/browser/mount_wasm_example.mjs .test-out/wasm/<slug>.wasm <slug> --telemetry-summary
```

If this hypothesis is promoted, broaden the representative action telemetry and
run the browser/app gates that produce that action trace.

Promotion trigger: representative action telemetry, not just mount snapshots,
shows repeated action-time fixed/dynamic string traffic dominates the remaining
structural tail, and a scoped command-wire dedupe slice lowers total
command/decode bytes without broad Roc value interning.

## Snapshot

The mount harness records the full mount, short settle window, and unmount
lifecycle. It is useful for command-wire byte accounting, but it is not a
dispatch benchmark and should not replace native work-budget specs.
This snapshot covers the current `public = true`, `wasm = true` entries in
`www/data/examples.toml` as of 2026-07-05.
The fixed record/string and dynamic buffer columns are command-stream byte
totals.

Refresh check: re-run on 2026-07-05:

- `node wip/research/wire_protocol_dynamic_size_estimate.mjs` exited
  successfully.
- `python3 scripts/test.py wasm --keep-output` exited successfully and rebuilt
  kept `.test-out/wasm/*.wasm` artifacts.
- `node scripts/browser/mount_wasm_example.mjs .test-out/wasm/<slug>.wasm <slug> --telemetry-summary`
  matched the rows below for every public wasm app listed in
  `www/data/examples.toml`.
- The representative action spot-checks were re-run on the same artifacts with
  `--exercise-service-ops-refresh`, `--exercise-team-checkout-plans`, and
  `--exercise-live-search-online`; subtracting the mount-only rows matched the
  action deltas below.

| App | Command batches | Commands | Fixed record bytes | Fixed string bytes | Dynamic buffer bytes |
| --- | ---: | ---: | ---: | ---: | ---: |
| service-ops-center | 3 | 1113 | 26712 | 2767 | 15428 |
| team-checkout | 2 | 194 | 4656 | 747 | 2784 |
| command-palette | 2 | 68 | 1632 | 240 | 1504 |
| team-signup | 2 | 109 | 2616 | 398 | 2216 |
| api-request-console | 3 | 86 | 2064 | 935 | 1024 |
| release-planner | 2 | 711 | 17064 | 2623 | 12304 |
| deployment-queue | 2 | 108 | 2592 | 480 | 1660 |
| workspace-widgets | 2 | 79 | 1896 | 333 | 1200 |
| live-search | 2 | 57 | 1368 | 280 | 932 |
| Total | 20 | 2525 | 60600 | 8803 | 39052 |

The apply-path decode columns are counters from `commands_applied.decode`.

| App | Fixed string decodes | Fixed string bytes | Dynamic record decodes | Dynamic record bytes | Dynamic string decodes | Dynamic string bytes | Dynamic byte array decodes | Dynamic byte array bytes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| service-ops-center | 477 | 2767 | 261 | 15428 | 516 | 9719 | 6 | 10 |
| team-checkout | 74 | 747 | 64 | 2784 | 128 | 1404 | 0 | 0 |
| command-palette | 20 | 240 | 33 | 1504 | 64 | 732 | 2 | 23 |
| team-signup | 33 | 398 | 51 | 2216 | 96 | 983 | 6 | 8 |
| api-request-console | 37 | 935 | 26 | 1024 | 52 | 448 | 0 | 0 |
| release-planner | 272 | 2623 | 215 | 12304 | 402 | 7075 | 28 | 28 |
| deployment-queue | 38 | 480 | 39 | 1660 | 78 | 818 | 0 | 0 |
| workspace-widgets | 28 | 333 | 28 | 1200 | 56 | 596 | 0 | 0 |
| live-search | 21 | 280 | 19 | 932 | 38 | 517 | 0 | 0 |
| Total | 1000 | 8803 | 736 | 39052 | 1430 | 22292 | 42 | 69 |

Representative action spot-check:

The sampler was also run against existing public workflow flags after the same
wasm build. Rows below are deltas from the mount-only public rows, so they
approximate action-time command traffic. The service workflow covers
route/back/forward, manual refresh, and visibility toggles; the checkout
workflow covers persisted delivery edits, plan changes, quantity updates, and
clear-saved removals; the live-search workflow covers offline typing and online
catch-up.

| App workflow | Delta command batches | Delta commands | Delta fixed record bytes | Delta fixed string bytes | Delta dynamic buffer bytes | Delta decoded dynamic string bytes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| service-ops-center route/refresh/visibility | 8 | 1821 | 43704 | 3720 | 17968 | 11203 |
| team-checkout persisted cart/edit/clear | 8 | 173 | 4152 | 961 | 2144 | 1111 |
| live-search online/offline search | 4 | 6 | 144 | 152 | 0 | 0 |

Summary:

- Total command-wire bytes in this sample are 108455: fixed record bytes 60600,
  fixed string bytes 8803, and dynamic buffer bytes 39052.
- String payloads are visible but not dominant: fixed strings plus decoded
  dynamic strings total 31095 bytes. Dynamic byte-array traffic is tracked
  separately; this snapshot records 42 dynamic byte-array decodes over 69 bytes.
- The fixed string buffer is only 8803 bytes across all public app mount
  lifecycles. The larger dynamic buffer total comes from 736 variable-shape
  dynamic attribute/event records, with decoded dynamic strings accounting for
  22292 of those bytes.
- The action spot-check does not promote command-wire string dedupe either:
  service-ops-center action traffic is still dominated by fixed records plus
  dynamic records, team-checkout string bytes remain a minority of action
  traffic, and live-search's string-heavy action delta is only 296 command-wire
  bytes total. Revisit only if broader action telemetry or representative app
  regressions show string traffic larger than the remaining structural tail.
