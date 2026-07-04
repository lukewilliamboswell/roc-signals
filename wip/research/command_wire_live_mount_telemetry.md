# Command Wire Live Mount Telemetry

Captured: 2026-07-04.

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

If this hypothesis is promoted, add representative action telemetry in addition
to mount snapshots and run the browser/app gates that produce that action trace.

Promotion trigger: representative action telemetry, not just mount snapshots,
shows repeated action-time fixed/dynamic string traffic dominates the remaining
structural tail, and a scoped command-wire dedupe slice lowers total
command/decode bytes without broad Roc value interning.

## Snapshot

The mount harness records the full mount, short settle window, and unmount
lifecycle. It is useful for command-wire byte accounting, but it is not a
dispatch benchmark and should not replace native work-budget specs.
This snapshot covers the current `public = true`, `wasm = true` entries in
`www/data/examples.toml` as of 2026-07-04.
The fixed record/string and dynamic buffer columns are command-stream byte
totals.

Refresh check: the snapshot was re-run on 2026-07-04 after
`python3 scripts/test.py wasm --keep-output`; every public wasm app listed in
`www/data/examples.toml` matched the rows below exactly.

| App | Command batches | Commands | Fixed record bytes | Fixed string bytes | Dynamic buffer bytes |
| --- | ---: | ---: | ---: | ---: | ---: |
| service-ops-center | 3 | 1065 | 25560 | 2649 | 14460 |
| team-checkout | 2 | 139 | 3336 | 580 | 2096 |
| command-palette | 2 | 68 | 1632 | 240 | 1504 |
| team-signup | 2 | 109 | 2616 | 398 | 2216 |
| api-request-console | 3 | 86 | 2064 | 935 | 1024 |
| release-planner | 2 | 578 | 13872 | 1964 | 10468 |
| deployment-queue | 2 | 108 | 2592 | 480 | 1660 |
| workspace-widgets | 2 | 79 | 1896 | 333 | 1200 |
| live-search | 2 | 53 | 1272 | 264 | 872 |
| Total | 20 | 2285 | 54840 | 7843 | 35500 |

The apply-path decode columns are counters from `commands_applied.decode`.

| App | Fixed string decodes | Fixed string bytes | Dynamic record decodes | Dynamic record bytes | Dynamic string decodes | Dynamic string bytes | Dynamic byte array decodes | Dynamic byte array bytes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| service-ops-center | 462 | 2649 | 237 | 14460 | 472 | 9351 | 2 | 6 |
| team-checkout | 51 | 580 | 48 | 2096 | 96 | 1059 | 0 | 0 |
| command-palette | 20 | 240 | 33 | 1504 | 64 | 732 | 2 | 23 |
| team-signup | 33 | 398 | 51 | 2216 | 96 | 983 | 6 | 8 |
| api-request-console | 37 | 935 | 26 | 1024 | 52 | 448 | 0 | 0 |
| release-planner | 220 | 1964 | 177 | 10468 | 340 | 6339 | 14 | 14 |
| deployment-queue | 38 | 480 | 39 | 1660 | 78 | 818 | 0 | 0 |
| workspace-widgets | 28 | 333 | 28 | 1200 | 56 | 596 | 0 | 0 |
| live-search | 19 | 264 | 18 | 872 | 36 | 479 | 0 | 0 |
| Total | 908 | 7843 | 657 | 35500 | 1290 | 20805 | 24 | 51 |

Summary:

- Total command-wire bytes in this sample are 98183: fixed record bytes 54840,
  fixed string bytes 7843, and dynamic buffer bytes 35500.
- String payloads are visible but not dominant: fixed strings plus decoded
  dynamic strings total 28648 bytes. Dynamic byte-array traffic is tracked
  separately; this snapshot records 24 dynamic byte-array decodes over 51 bytes.
- The fixed string buffer is only 7843 bytes across all public app mount
  lifecycles. The larger dynamic buffer total comes from 657 variable-shape
  dynamic attribute/event records, with decoded dynamic strings accounting for
  20805 of those bytes.
- This snapshot does not justify promoting command-wire string dedupe by itself.
  Revisit only if action telemetry or representative app regressions show string
  traffic larger than the remaining structural tail.
