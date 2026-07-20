# RealWorld (Conduit) Demo Findings Ledger

Created: 2026-07-08, at `wip/REALWORLD_DEMO_PLAN.md` Phase 0.

Purpose: one entry per finding from the `examples/conduit` build — every
platform gap, friction point, compiler issue, tooling pain, and every
confirmation that a gated backlog item stayed unneeded. No silent
workarounds: any place app code routes around a platform deficiency gets an
entry here. At build end, every `wip/NEXT_STEPS.md` priority 1-5 either
cites conduit evidence for a promotion or is explicitly re-deferred with a
reason (MoE-5).

Entry format:

```
### <date> <phase> — <title>
Classification: platform-gap | app-land | compiler | ergonomics | tooling
Severity: blocker | friction | paper-cut
Evidence: <file / spec / telemetry refs>
Action: <promotion trigger recorded in NEXT_STEPS priority N | issue filed |
        accepted as app code | breaking-change proposal>
```

## Feature → spec-line map (MoE-1)

Maintained from Phase 1 onward; no unchecked feature rows at Phase 5 exit.
“Verified” means the app path and assertion are present and the full native
script passed with PATH Roc `release-fast-8eaa9abd` on 2026-07-20. Line references are
to `examples/conduit/spec.txt` sections by comment header (line numbers drift;
headers are stable).

| Feature | Spec assertion(s) | Status |
| --- | --- | --- |
| Deep link cold-mounts routed page + title | "Deep link cold-mounts the article page" section | verified (Phase 1) |
| Header navigation and routed URL/title/view updates | navigation throughout the script | verified (Phase 1) |
| Back/forward keep URL and title in sync | "Back/forward stay in sync across live pages" section | verified for one back/forward pair; planned 10-step trail remains a soak gate |
| All 9 route shapes mount with per-route titles | routed navigation throughout the script | verified (Phase 1-5) |
| Home query params (page, tag, feed) parse into feed state | "Pagination"; "Tag filter"; "Your Feed" sections | verified (Phase 1-3) |
| Unknown route renders not-found without URL rewrite | final not-found assertions | verified (Phase 1) |
| Feeds, pagination controls, popular tags | "Home"; "Pagination"; "Tag filter"; "Your Feed" sections | verified (Phase 2-3) |
| Article page with markdown body | "Deep link cold-mounts the article page" section | verified (Phase 2) |
| Profiles (view, tabs) | "Profile page" section | verified (Phase 2) |
| Auth: register/login/logout, JWT persist/restore | "Seeded session"; "Settings"; "Login"; "Register" sections | verified (Phase 3-5) |
| Guarded routes with replace_state redirects | "Guarded routes redirect anonymous visitors" section | verified (Phase 3) |
| Settings | "Settings" section | verified (Phase 3-5) |
| Editor create/edit, article delete | "Article writes" section | verified (Phase 4) |
| Comments create/delete | "Article writes" section | verified (Phase 4) |
| Favorites, follows | "Home"; "Article writes"; "Profile page" sections | verified, including repeated inverse mutations (Phase 4-5) |
| 422 envelopes on all four forms | "Settings"; "Register"; "Login"; "Article writes" sections | verified (Phase 5) |
| Network failure states on every GET surface | "Network failure matrix for every GET surface" section | verified (Phase 5) |
| Stale response suppression | "Tag filter with request replacement" section | verified with an explicitly delivered stale completion (Phase 5) |
| `StorageUnavailable` startup | no native directive can currently inject this state | open robustness/tooling gap (Phase 5) |
| Submission readiness | README plus `serve.py --no-server` gates | published; full dev and size site gates pass (Phase 5) |
| Soak and command-wire measurement | Conduit build plus plateau/telemetry gates | structural plateau gate refreshed; Conduit-specific measurements not run (Phase 5) |
| Comparison study | local LoC baseline plus wasm/public build outputs | local source baseline recorded; payload/reference rows open (Phase 5) |

## NEXT_STEPS Priority Synthesis (Phase 5 WIP)

This is the MoE-5 closeout ledger. It stays WIP until the remaining real-backend,
measurement, and comparison gates are exercised.

| Priority | Conduit evidence | Current decision |
| --- | --- | --- |
| 1. Browser environment follow-ups | Conduit uses the shipped location/history, storage startup snapshots, document title, visibility/online-adjacent task path, and app-local hash-route parsing. The fixed GitHub Pages document path plus hash routes preserve cold deep links without host rewrites. The app has not proven app-visible storage write recovery, cross-tab storage, IndexedDB, or split location sources. | No browser-environment promotion: static hosting was solved in app code with the existing location/history surface. Keep scroll and broader browser-source candidates deferred. |
| 2. Subscriptions and app-specific JS interop | Conduit did not need generic `Sub`, ports-like app interop, or a broader browser source catalog beyond shipped focused sources and ordinary tasks. | Keep generic subscriptions and app-specific interop deferred. |
| 3. HTTP production hardening | Conduit proves authenticated request envelopes, timeout-bearing requests, task replacement/stale suppression, 422 envelopes, and network errors. Cross-origin header auth already passed the Phase 0 canary, so fetch-policy knobs stay closed. Builtin Json required an app-local escape workaround and string-parsed dynamic 422 keys, but the current issue is compiler JSON behavior/dynamic object parsing, not proof that Signals should own JSON/body helpers. Explicit user abort and typed effect capability routing were not needed. | No HTTP public-surface promotion yet; keep fetch-policy controls, JSON/body helper sugar, explicit abort, and effect registry deferred. Compiler JSON issue remains a compiler finding. |
| 4. Form/input hardening | Conduit forms use shipped text inputs, textareas, submit prevention, and controlled state. The async edit/settings prefill limitation is recorded as app ergonomics, and no selection, file input, multi-select, constraint validation, focus command, or date/time input need appeared. | No form/input promotion yet; async state hydration remains a documented app pattern unless more maintained forms pay the cost. |
| 5. Dynamic event response | Conduit uses static prevent-default form submission and ordinary click/input handlers; no state-dependent event response, handler-chain composition, or payload-only response was needed. | Keep dynamic event response deferred. |

## Comparison Baseline (Phase 5 WIP)

This is the local half of the RealWorld comparison study. External reference
implementations and gzipped first-render payloads remain open. The native gate
is now green; release/readiness and robustness evidence take precedence over
comparison polish.

Measured 2026-07-11 with `wc -l examples/conduit/*.roc
examples/conduit/spec.txt examples/conduit/README.md`:

| Category | Files | Lines |
| --- | --- | ---: |
| Shell, routing, session, nav, formatting | `app.roc`, `Route.roc`, `Session.roc`, `Nav.roc`, `Format.roc` | 654 |
| API, DTOs, request helpers, mock contract | `Api.roc` | 380 |
| Routed pages, view state, form state | `Home.roc`, `Feed.roc`, `Article.roc`, `Profile.roc`, `Auth.roc`, `Settings.roc`, `Editor.roc` | 2,343 |
| Markdown rendering | `Markdown.roc` | 358 |
| Roc app source total | all `examples/conduit/*.roc` | 3,735 |
| Native browser spec | `spec.txt` | 357 |
| Public README | `README.md` | 36 |
| App source plus evidence docs | Roc source, spec, README | 4,128 |

Interpretation: the Roc app source is inside the plan's 3,000-4,000 line
target and below the 5,000-line review threshold. Including the native spec and
README crosses 4,000 lines, but those are evidence/publication artifacts rather
than app runtime source. The missing comparison rows remain: Elm/Svelte/React
reference LoC by category, gzipped first-render payload, cold-load request
count and reference error-state coverage.

## Phase 5 Gate Status

The compiler, native feature, cross-example, and publication gates are complete.
The table retains the remaining closeout evidence alongside those completed gates:

| Gate | Current evidence | Resume condition |
| --- | --- | --- |
| Native spec execution | full `examples/conduit/spec.txt` passes with PATH Roc `release-fast-8eaa9abd`, including explicit stale completion and back/forward assertions | complete |
| Cross-example rollout | `python3 scripts/test.py all --roc-bin roc` passes all checks, native specs, browser tests, wasm mounts, bundles, and benchmarks | complete |
| Remaining MoE-3/MoE-4 robustness | ordinary back/forward, loading, errors, and stale suppression pass | inject `StorageUnavailable` and run the planned 10-step navigation trail |
| Real-backend conformance (MoE-2) | in-page backend shape is covered by node tests, and the Phase 0 cross-origin auth canary passed | wasm Conduit build runs in browser with a base-URL swap against a conformant backend |
| Public-site publication/readiness (MoE-6) | Conduit is public; full `serve.py --no-server` dev and size builds pass for all 11 examples, including Conduit, and its wasm mounts | complete |
| Static-host deep-link decision | complete: Conduit uses `#/...` routes beneath `/roc-signals/examples/conduit/`; native cold mounts and the generated static page cover the fixed-path contract | complete |
| Payload/startup comparison | local source LoC baseline exists | wasm/site output exists so gzipped payload and cold-load request counts can be measured |
| Conduit soak and action telemetry | structural plateau and static wire estimates are refreshed | native/wasm behavior gate is trustworthy enough to exercise feed/article/login/logout cycles |

## Compiler Issue Filing Drafts (Phase 5 WIP)

These track upstream compiler findings that blocked or shaped Conduit evidence.
Filed issues are linked here; unfiled issue notes stay summarized in this table
until they can be rechecked and filed.

| Candidate | Draft title | Current evidence | Before filing |
| --- | --- | --- | --- |
| Builtin JSON string escapes | builtin Json cannot parse escaped string characters | a temporary single-field probe reproduced rejection of plain controls versus escaped newline, quote, backslash, tab, and Unicode inputs on the roc#10072 compiler; the probe was removed after evidence capture; the Conduit workaround lives in `examples/conduit/Api.roc`; a 2026-07-12 recheck on `release-fast-4828766c` instead panicked in postcheck before execution | recreate the small probe after minimizing/bypassing the new postcheck panic, then make the final semantic recheck and file upstream |
| Browser source compiler crash | exposed/used/mapped `Browser.location` source crashes compiler with SIGSEGV/capture_fields | filed as roc-lang/roc#10071 with a self-contained repro; roc-lang/roc#10072 fixed the reduced and full build repros; the later `ConstStore` postcheck panic is a separate compiler regression | resolved for this experiment; retain the upstream link as history |
| HTTP task build crash | unused `Http.get_text_task` crashes native build/codegen | reduced in roc-lang/roc#10071/comment-4941703250 and helper-specialization repro in comment-4944342804; fixed by roc-lang/roc#10072; the later `ConstStore` postcheck panic is a separate compiler regression | resolved for this experiment; retain the upstream link as history |
| Wide derived JSON record parse crash | already filed as roc-lang/roc#9964 | focused 50-field repro now checks on nightly-2026-July-07, but upstream issue remains open | re-verify when upstream closes it; only reopen/file follow-up if the single-wide parser is still slow or crashes |

## Findings

### 2026-07-20 Phase 5 — Hash routes close static-host deep links in app code

Classification: app-land
Severity: paper-cut
Evidence: `examples/conduit/Route.roc` formats every logical route beneath the
fixed `/roc-signals/examples/conduit/` document path; `spec.txt` cold-mounts a
hash-routed article, exercises hash-contained feed queries, redirects and
unknown routes, and mounts the unhashed published URL as home. The generated
site contains the matching static document path.
Action: accept hash routing as demo/deployment configuration. No router DSL,
split hash source, or other browser-environment API is promoted.

### 2026-07-20 Phase 5 — PATH main compiler and publication gates pass

Classification: compiler
Severity: blocker (resolved)
Evidence: PATH Roc `release-fast-8eaa9abd` checks and builds Conduit natively
and for wasm. Its full native spec passes. `python3 scripts/test.py all
--roc-bin roc` passes the repository gate, and `python3 scripts/serve.py
--no-server --roc-bin roc` passes in both dev and size modes with Conduit
published. Folding the package's opaque HTTP response directly into Conduit's
large domain unions still overflows the compiler stack; `Api.response_state`
confines response materialization to a small plain record before domain decode.
Action: compiler recovery and publication are complete. Keep the real-backend,
static-host, soak/telemetry, and comparison work as the active closeout evidence.

### 2026-07-12 Phase 5 — Source factories expose a pre-existing Service Ops branch defect

Classification: platform-gap
Severity: friction (resolved)
Evidence: the all-example native suite checks every app, then reaches
`service-ops-center/spec.txt` line 75: an unknown service URL is canonically
replaced with `/`, but the overview `Ui.when` branch remains detached. A clean
`HEAD` archive built with the same `release-fast-afbc7863` compiler fails
earlier during mount with the retained-value capability mismatch, so this is
not a regression caused by the keyed-row insertion fix; the source-factory
change made the deeper existing failure reachable.
Action: resolved in `examples/_fixtures/location-canonical-branch`. Scalar
render sinks now capture navigation/storage effects, structural sinks for the
triggering generation apply next, and only then does the engine redispatch the
updated host source. Native and Wasm DOM-event paths share the same batch
transaction. The focused failing/control specs, Service Ops, Conduit, and the
full cross-example native suite pass.

### 2026-07-12 Phase 5 — Native behavior gate restored and hardened

Classification: platform-gap
Severity: blocker (resolved)
Evidence: `examples/conduit/spec.txt` passes end to end with Roc
`release-fast-afbc7863`. The reduction changed capability-bearing browser and
session sources into factories; the native host now resolves repeated task
names by source token; dirty keyed-row replacement uses live insertion points;
role/name locators include descendant text; and repeated follow, favorite, and
comment mutations carry distinct results so their refetches are not pruned.
Focused Zig regressions cover duplicate task names, full each-row replacement,
and descendant accessible names. The Conduit script additionally delivers a
stale feed completion and exercises both history directions.
Action: treat the native feature map as verified. Keep `StorageUnavailable`,
the 10-step navigation trail, site builds, real-backend conformance, and soak
telemetry as explicit closeout gates.

### 2026-07-12 Phase 5 — Native Conduit mount fails retained-value capability ownership

Classification: platform-gap
Severity: blocker (for MoE-1 and downstream Phase 5 measurements)
Evidence: with PATH compiler `release-fast-4828766c`, `roc check` passes;
native arm64mac, wasm dev, and wasm size direct builds pass. The native build
takes about 2m50s and wasm dev about 2m59s. Running the resulting native
executable against `examples/conduit/spec.txt` exits immediately with
`HOST ERROR: HostValue operation used a capability that does not own the
retained value`. Empty, storage-only, and location-only probe specs fail the
same way, which places the failure in initial app mount rather than a spec
directive or feature flow. The JS browser contract suite remains green
(103/103), including the 21 Conduit backend cases.
Action: make this the first closeout task. Minimize the Conduit initial-mount
capability mismatch against a smaller app, fix it in the host/engine or app as
the reduction proves, and do not claim the feature map verified until the full
native script passes. Release, soak, and comparison work follows this gate.
Resolution 2026-07-12: capability-bearing module-level sources were the
trigger. Converting `Browser.location`, `Browser.visibility`, `Browser.online`,
and the Conduit session source to factories removed the ownership mismatch;
the full native script now passes on `release-fast-afbc7863`.

### 2026-07-12 Phase 5 — Current compiler postcheck regression blocks final verification

Classification: compiler
Severity: blocker
Evidence: building the temporary single-field JSON probe with PATH compiler
`release-fast-4828766c` aborted in postcheck with `erased function ConstStore
output requires explicit erased function entries`. The prior roc#10072 compiler
built the same minimized probe and reproduced rejection of escaped JSON strings.
The probe was removed after this evidence was captured. Final verification then
reproduced the same postcheck panic on the full Conduit app, including a
sequential `roc check --no-cache examples/conduit/app.roc`; earlier in the same
review, the same reported compiler version had checked and built direct Conduit
artifacts.
Action: treat this as the first compiler/runtime gate and do not conflate it
with the JSON semantic bug. Minimize the postcheck panic and establish why the
same version's behavior changed, then recheck Conduit and recreate the small
JSON probe for its final semantic filing check.
Resolution 2026-07-12: this remains a PATH-toolchain regression, but it no
longer blocks Conduit verification. The known-good roc#10072 compiler
`release-fast-afbc7863` checks and builds the app and produced the passing
native artifact.

### 2026-07-11 Phase 5 — Conduit soak and wire-telemetry measurements are compiler-blocked

Classification: compiler
Severity: blocker (for Conduit-specific MoP ratchets)
Evidence: the reusable structural plateau gate
`zig build run-test-zig -Dtest-filter=plateau -Dtest-filter="dirty queue"`
passes on 2026-07-11, so the existing host dense-table and dirty-queue plateau
coverage remains current. The planned Conduit-specific soak run (feed/article
navigation plus login/logout cycles) and command-wire action trace refresh both
require a Conduit native or wasm build. Current direct Conduit wasm builds in
both app opt modes exit 139 with Roc compiler SIGSEGVs, and the native Conduit
spec/build path is already blocked by the Phase 4 compiler crash recorded
below.
Action: no structural work is promoted: there is no failing plateau measurement.
Conduit-specific MoP ratchets and command-wire action telemetry are deferred
until the compiler can build the app.
Resolution 2026-07-12: the compiler now builds the app; the new initial-mount
capability mismatch above supersedes the old resume condition.

### 2026-07-11 Phase 5 — Public-site wasm build gate is blocked by Roc compiler crashes

Classification: compiler
Severity: blocker (for publication/submission readiness)
Evidence: `python3 scripts/serve.py --no-server --app-opt dev` and
`python3 scripts/serve.py --no-server --app-opt size` both fail before a full
public site build completes. With `release-fast-43e1cc3c`, the dev gate
SIGSEGVs while building `service-ops-center` for wasm, and the size gate aborts
with `guarded list invalidated: lambda_mono.Type.Store.capture_fields` on the
same app. Direct Conduit wasm builds on the current source also fail:
`roc build --target=wasm32 --opt=dev --no-cache
--output=/tmp/conduit-dev.wasm examples/conduit/app.roc` and the matching
`--opt=size` command both exit 139 with Roc compiler SIGSEGVs. During the
temporary publication trial, focused `serve.py --example conduit` checks failed
the same way. Rechecked on 2026-07-11 with PATH Roc `release-fast-d35c3560`:
`roc check examples/conduit/app.roc`, direct native build, and wasm dev build
SIGSEGV; wasm size panics with
`lambda_mono.Type.Store.capture_fields`. A smaller
temporary app that only returns `Elem.Text("hello")` also SIGSEGVs with the
full platform. Temporary reduction
shows the crash disappears with only `Elem`, `Signal`, `Html`, and `Ui`
exposed, and reappears when the `Browser.location` source is restored. Filed
upstream as roc-lang/roc#10071 with a self-contained eight-file repro that does
not require cloning this repository. Follow-up comment
roc-lang/roc#10071/comment-4939911807 corrects the issue body's omitted
`hosted` mappings; adding them to the standalone repro still reproduces the
SIGSEGV.
Built roc-lang/roc#10072 locally on 2026-07-11 as `release-fast-3a167111`.
That compiler fixes the reduced Browser-location repro: both the temporary
repo-local probe and the corrected standalone roc-lang/roc#10071 repro check,
and the standalone repro builds natively. It
does not unblock Conduit: `roc check examples/conduit/app.roc`, direct native
build, direct wasm dev build, and direct wasm size build all still exit 139
with SIGSEGVs. Smaller control checks/builds (`counter`, `service-ops-center`,
`json-decode`, and the Conduit JSON decode probe) pass on the PR compiler.
Follow-up reduction posted as
roc-lang/roc#10071/comment-4940838958: starting from the corrected standalone
repro, adding only `current = Browser.location` in app code makes `roc check`
and native build SIGSEGV with fault address `0x10`; removing that binding while
keeping `import pf.Browser` checks.
Retested the newer roc-lang/roc#10072 head
`fbab7377ea32b393133021ae898ab5930350f0ad` on 2026-07-11 as
`release-fast-fbab7377`. It fixes the direct used-source repro:
`current = Browser.location` now checks and builds. It does not fix mapped
browser sources: `current = Browser.location.map(|_| "ok")` still SIGSEGVs on
`roc check` and native build, and full Conduit still SIGSEGVs on check, native
build, wasm dev build, and wasm size build. Follow-up posted as
roc-lang/roc#10071/comment-4941101241.
Retested roc-lang/roc#10072 again at
`2bde9d3f9f691d31e98ae7457ccb3442837441cc` on 2026-07-11 as
`release-fast-2bde9d3f`. The mapped-source repro now checks and builds, and
full `roc check examples/conduit/app.roc` passes. Full Conduit direct builds
still SIGSEGV for native arm64mac, wasm dev, and wasm size. Smaller control
builds (`counter`, the mapped route-source static app, and the Conduit JSON
decode probe) pass, so the remaining blocker is a Conduit build-stage crash
rather than the previously reduced browser-source check crash.
Further reduction posted as roc-lang/roc#10071/comment-4941703250: the build
crash reduces to constructing an unused `Http.get_text_task("feed")` and
returning `Elem.Text("hello")`. The app checks, but native build SIGSEGVs.
`Signal.fold_task` is not required. A simple
`Signal.task_source("feed", |_| "done", |_| "failed", False)` control builds,
and replacing `Http.get_text_task`'s decoder pair with simple lambdas also
builds; reintroducing `decode_text_response_payload` brings the crash back.
Retested roc-lang/roc#10072 at
`45d819c010c640472ae730d19041347d3f589d27` on 2026-07-11 as
`release-fast-45d819c0`. The reduced HTTP task repro still checks and still
SIGSEGVs on native build. Full Conduit still checks and still SIGSEGVs for
native arm64mac, wasm dev, and wasm size. Counter native/wasm and the Conduit
JSON decode probe still build; follow-up posted as
roc-lang/roc#10071/comment-4942947641.
Diagnostic script output from `/tmp/roc-10071-diagnostics-20260711-164002`
gives a more actionable root than the ReleaseFast SIGSEGV: the Debug compiler
panics in postcheck with
`instantiation unified a tag union with a non-tag-union type` at
`src/postcheck/monotype/solve.zig:663`, reached through dispatch lowering
(`instantiateTargetFromPlan` / `lowerResolvedDispatch`). ReleaseSafe aborts at
`reached unreachable code`; ReleaseFast remains a stripped `EXC_BAD_ACCESS`.
Posted as roc-lang/roc#10071/comment-4943237173.
`examples/conduit` now has a README, but `www/data/examples.toml` keeps
`public = false` until these build gates can pass.
Action: publication is deferred; keep using `roc check`, backend/browser tests,
and tidy gates for Conduit work. Revisit after the compiler crash is minimized
or the local compiler is refreshed.
Resolution 2026-07-12: direct native and wasm builds passed on the then-current
compiler, and the native runtime gate now passes with `release-fast-afbc7863`.
Publication remains deferred for the unrun site/readiness gates, not for a
compiler or native behavior failure.

### 2026-07-10 Phase 4 — Async-loaded records cannot seed controlled form state directly

Classification: ergonomics
Severity: friction
Evidence: `examples/conduit/Editor.roc` edit page fetches the article and
renders current values as read-only context, while the controlled edit fields
start blank and submit a partial article update where blank fields mean
"unchanged". The same constraint already shaped `examples/conduit/Settings.roc`:
`Ui.state` initializes synchronously, and there is no app-level primitive to
copy a later task result into controlled input state exactly once without
fighting user edits.
Action: accepted as app code for Phase 4. Consider a one-shot state hydration
helper only if Phase 5 finds more form surfaces paying this cost; otherwise
document the partial-update pattern for async edit forms.

### 2026-07-10 Phase 4 — Conduit native build crashes the temporary Roc compiler before spec execution

Classification: compiler
Severity: blocker (for native spec verification)
Evidence: `/private/tmp/roc-pr10025-10050-copy/zig-out/bin/roc build
--no-cache --target=arm64mac --opt=dev --output=/tmp/signals-conduit
examples/conduit/app.roc` exits 139 with a Roc compiler SIGSEGV. The same
command also crashes against a clean `HEAD` archive at
`/private/tmp/roc-signals-head-archive`, so this is not caused by the Phase
4 editor-create slice. The `roc` binary from `/Users/luke/Documents/GitHub/roc`
panics on the same app with
`guarded list invalidated: lambda_mono.Type.Store.capture_fields`, which
points at the same build/codegen class rather than a native host/spec issue.
Action: keep using `roc check` plus browser/backend gates for this slice;
native Conduit spec execution is blocked until the local compiler is refreshed
or this build crash is minimized/filed during Phase 5 compiler-issue
synthesis.

### 2026-07-08 Phase 2 — Builtin Json parser rejects every escape sequence inside JSON strings

Classification: compiler
Severity: blocker (worked around in app code)
Evidence: a temporary probe minimized the failure to one parser,
`{ body : Str }`, with plain, `\n`, `\"`, `\\`, `\t`, and `\uXXXX` inputs.
The native browser-spec run rendered `plain ok` for the control case, while all
five escaped-string cases rendered
`<case> invalid: Invalid JSON` with the temporary compiler on 2026-07-11.
The probe and its spec were removed after evidence capture.
The original Phase 2 source read showed `Builtin.Json.split_json_string_tail`
returning `invalid_json` whenever a backslash appears before the closing quote.
Every RealWorld article body (markdown with newlines) and any bio/title with a
quote hits this; a conformant client cannot avoid it.
Action: upstream issue warranted (draft: "builtin Json cannot parse any
string escape sequence; split_json_string_tail rejects backslashes"); app
workaround in `examples/conduit/Api.roc`
(`shield_escapes`/`restore_text`: placeholder-substitute escapes before
parse, restore after decode; `\uXXXX` still unsupported). Remove the
workaround and re-simplify when upstream lands support.

### 2026-07-08 Phase 2 — Native host panics when a Ui.when arm flips during a task resolve/reject flush

Classification: platform-gap
Severity: blocker (worked around in app code)
Evidence: resolving the conduit feed from one row to zero rows (flipping
an is-empty `Ui.when` arm), or rejecting it (flipping an is-failed arm),
panics the native host with "descriptor stream recorded duplicate
descriptor index" (exit 134). Reproduced deterministically by the Phase 2
spec before the workaround; a state-driven equivalent (button click sets
the list empty and flips the same arm shape) does not reproduce, so the
task-completion flush path is implicated. Loading-arm flips at task start
never panicked.
Action: promotion trigger recorded — this is a host correctness bug
(descriptor stream/scope disposal during task flush), to be minimized
into a fixture and fixed as its own slice; conduit's `Feed.roc` renders
empty/failed states as placeholder keyed rows instead of when arms until
then (restore the arms with the fix). Article/Profile pages still use
failed arms and are exposed to the same panic on reject — the Phase 5
error matrix must not land before the host fix.

2026-07-08 update (Phase 3 WIP): a third manifestation, silent instead of
panicking — with the session `Ui.when` nodes added to the header, a
route-driven arm swap away from a page whose task had completed leaves
the disposed arm's nodes active in the DOM (the article page's
"Loading article..." paragraph stays mounted as a sibling of the home
page's content; native spec fails at the home tags assertion with the
zombie visible in the `--verbose` DOM dump). Three manifestations of one
descriptor-stream defect is a pattern, not a corner: the host fix now
blocks Phase 3, promoted to active work ahead of further app phases.

2026-07-09 update (resolved in `c981ae9`): the class split into stale
dirty entries against recycled node ids, deferred command payload lifetime,
and structural removal/ordering issues. The engine fix now snapshots
changed-record ids, applies render sinks before collecting structural work,
delays same-generation identity reuse, preserves deferred navigation
payloads, and treats subtree removal as one host remove while deactivating
descendants internally. With `Feed.roc` restored to natural
loading/failed/empty `Ui.when` arms, the full Conduit spec passes; the page
switch budget returned to `patches_emitted <= 60` exactly.

### 2026-07-08 Phase 2 — Accessible name lookup does not traverse link children; keyed rows need static context

Classification: ergonomics
Severity: paper-cut
Evidence: spec `role:link name:"X"` matchers miss anchors whose text is a
nested `Html.text_s` child (only `Html.link`'s direct label registers an
accessible name). Keyed `Ui.each_str` rows receive only a static key plus
an item signal, so row-level links with dynamic targets encode data in
row keys (`Feed.roc` pagination keys carry `page|tag`; single-row keyed
lists give author links a static username). Workable, but a
`link`-with-signal-label helper or child-traversing name computation
would remove both contortions.
Action: accepted as app code; revisit as a platform ergonomics candidate
only if later phases keep paying it.

### 2026-07-08 Phase 1 — Cold-cache `roc check` takes ~51s on the conduit skeleton; warm re-check is 90ms

Classification: compiler
Severity: friction
Evidence: on nightly-2026-July-07 (`release-fast-050c6975`), the first
`roc check examples/conduit/app.roc` after edits reports ~51,000ms; an
immediate re-check of the unchanged file reports 90ms, so the cost is
cold-cache module-graph compilation, not per-iteration. For comparison,
cold checks of small fixtures are sub-second (`json-decode` ~320ms, the
50-field repro ~1s) while `service-ops-center` is ~64s — app-shaped code
pays far more than fixture-shaped code and the scaling with size is
unclear. Local iteration is fine; the cost lands on cold paths —
`python3 scripts/test.py roc-check` gates and CI check every example from
fresh copies, so each conduit phase adds cold-check latency to every gate
run.
Action: recorded; re-measure at each phase exit, and minimize an upstream
repro if cold checks cross a few minutes at target app size.

### 2026-07-08 Phase 1 — Tag constructors are not first-class functions

Classification: ergonomics
Severity: paper-cut
Evidence: passing a payload tag constructor as a function argument
(`slug_route(prefix, EditorEdit)`) fails to check — the bare tag is
treated as a zero-argument tag (`[EditorEdit, ..]` vs the needed
`Str -> Route`). `examples/conduit/Route.roc` wraps constructors in
lambdas (`|slug| EditorEdit(slug)`) instead.
Action: accepted as app code; language-level, not a platform matter.

### 2026-07-08 Phase 0 — Nightly compiler renamed the builtin `Json` error type; repo idiom broke under floating-nightly CI

Classification: compiler
Severity: blocker (for gates; resolved in this slice)
Evidence: `roc check` on nightly-2026-July-07 (`release-fast-050c6975`)
rejected every `Try(a, Json)` annotation ("The type Json is not exposed by
the module Builtin") in `examples/service-ops-center/Dashboard.roc`,
`examples/_fixtures/json-decode/JsonProbe.roc`, and
`wip/research/wide_record_json_sigsegv_repro.roc`. Upstream change landed
between nightly-2026-July-05 (`c0cae66`, last green vintage) and
nightly-2026-July-06/07: the parse error type is now `Json.ParseErr` with
payload-carrying tags `MissingRequiredField(Str)` / `InvalidJson(Str)`
(previously bare `Json` with `MissingRequired` / `InvalidJson`), and
`Json.encode` was replaced by `Json.to_str` / `Json.to_str_try`
(roc-lang/roc commit 84f5cc921c). CI floats on `nightly-new-compiler`
(`.github/workflows/ci.yml:30`), so main was red against the current
nightly independent of any conduit work.
Action: accepted as app code — migrated all three files to
`Json.ParseErr` / `MissingRequiredField(_)` / `InvalidJson(_)` /
`Json.to_str_try` in this slice; `wip/research/json_codec_evidence.md`
refreshed. The payload-carrying tags are a small win for conduit: decode
errors can now surface the offending field name in error states.

### 2026-07-08 Phase 0 — New effectful-name lint requires `!` on the platform's hosted declarations; warnings now fail `roc check` gates

Classification: compiler
Severity: blocker (for gates; resolved in this slice)
Evidence: nightly-2026-July-07 (`release-fast-050c6975`) emits seven
"EFFECTFUL FUNCTION NAME" warnings for the annotation-only hosted
declarations in `platform/HostValue.roc` (`clone`,
`store_with_capability`, ..., `take_with_split`) and exits 2 on
warnings-only checks, which fails `python3 scripts/test.py roc-check` for
every example. This is intentional upstream behavior, not a false
positive: annotation-only declarations in the platform package are
rewritten to hosted lambdas, which the effectful-name check always treats
as effectful (see roc-lang/roc 8684eb0abf, which narrowed the transform to
platform packages precisely because "only the platform package
legitimately provides hosted functions"; upstream's own `test/fx` platform
names all hosted functions with `!`). The lint checks only the hosted
declaration's own body, so the rename does not cascade: pure platform
callers (`Capability.roc`, `Ui.roc`) keep their names.
Action: accepted as platform-internal migration — renamed the seven
`HostValue` functions with a `!` suffix and updated the `hosted` table in
`platform/main.roc` plus the call sites in `Capability.roc`/`Ui.roc`.
App-invisible (HostValue is not in the platform `exposes` list); the host
ABI symbol names (`roc_host_value_*`) are unchanged. Worth watching: the
platform still types these as pure (`->`) while upstream's convention is
the effectful arrow (`=>`) — if upstream later enforces call-site
effectfulness, the purity model of the view layer needs a real design
response, not a rename. If a floating-nightly breakage recurs, pinning
`nightly-tag` in `.github/workflows/ci.yml` (setup-roc supports it) is the
recorded option.

### 2026-07-08 Phase 0 — Markdown spike: app-land parser covers Conduit article syntax; roc-parser dependency not needed yet

Classification: app-land
Severity: paper-cut
Evidence: `examples/_fixtures/markdown-elem` extended with fenced code
blocks (multi-line state across the line fold), images (`![alt](src)` with
the same scheme allowlist applied to `src` — javascript: images degrade to
plain alt text with no `img` attribute), and one-level nested lists
(grouped consecutive `- ` / `  - ` lines into a single keyed list block).
Native spec asserts all three in both the static and the signal-backed
live views, plus the existing patch budgets
(`expect_metric_delta_at_most patches_emitted 80`), all green under
`python3 scripts/test.py native --native always`. No roc-parser package
dependency exists in the repo; the plan's fallback (extend the app-local
parser) is the working path, and the conduit `Markdown.roc` can start from
this fixture.
Action: accepted as app code; swap to roc-parser only if it ships as a
package and materially simplifies the module.

### 2026-07-08 Phase 0 — Spec `fill` strings cannot express newlines, so multi-line markdown is untypeable in native specs

Classification: tooling
Severity: friction
Evidence: `src/spec/spec_parser.zig` unescapes `\n` only for
`custom_event` and `resolve_task`/`reject_task` payloads
(`dupeUnescapedQuoted`); `fill` values pass through verbatim, so a typed
`"\n"` reaches the app as two characters. The markdown-elem fixture works
around it by prefilling the live view's initial state with a multi-line
sample (fence + nested list) and keeping `fill` exercises single-line.
Conduit's editor page (multi-line article bodies, markdown preview
parse-on-type budgets) will hit the same wall.
Action: accepted for Phase 0; if conduit's editor specs need real
multi-line typing, propose extending `fill` (or a `fill_multiline`
command) as a spec-runner slice — record the decision here when Phase 4
reaches the editor.

### 2026-07-08 Phase 0 — Conduit in-page backend skeleton proven (seeded router, pagination, 422 envelopes, auth plumbing)

Classification: app-land
Severity: paper-cut
Evidence: `www/static/conduit_backend.mjs` implements the RealWorld read
surface plus login as a deterministic in-memory backend in the
`example_tasks.mjs` pattern: seeded users/articles/comments, spec-shaped
envelopes, limit/offset pagination with total `articlesCount` (23 seeded
articles so the default 20-per-page paginates), `Authorization: Token`
parsing with viewer-dependent `favorited`/`following` flags, 422/401/404
error envelopes, and optional latency injection with abort handling.
Dynamic path segments (`/api/articles/:slug`) do not fit
`createHttpTaskRouter`'s literal route keys, so the handler decodes the
request itself with the exported payload codecs and returns null for
non-conduit URIs to keep the chain fall-through semantics. 13 node tests
in `scripts/browser/conduit_backend.test.mjs` (wired into
`zig build run-test-browser`, 95/95 green) lock pagination semantics and
the 422 envelope shape per MoE-2. List responses intentionally omit
article `body` (matches the spec's Multiple Articles example), keeping the
app's feed DTO compatible with the weakest conformant backend.
Action: accepted as app-support code; mutation endpoints land with the
Phase 3/4 app slices that exercise them.

### 2026-07-08 Phase 0 — Cross-origin authenticated fetch works under browser defaults; CORS denial surfaces as renderable Network error

Classification: app-land (confirmation — no platform gap)
Severity: paper-cut
Evidence: real-browser canary via headless Chrome against the shipped
`signals.mjs` fetch path; full observations and boundary recorded in
`wip/research/fetch_policy_evidence.md` (2026-07-08 refresh). A
preflighted cross-origin GET with `Authorization: Token ...` succeeded
against a CORS-enabled endpoint with the header transmitted; a no-CORS
endpoint surfaced as the documented `network` HttpError. The one fully
unproven platform path from the plan is now observed; conduit needs no
fetch-policy knobs for header-based auth (NEXT_STEPS priority 3 candidate
"browser fetch-policy controls" stays closed).
Action: accepted — no promotion; cookie-credentialed cross-origin and the
real-backend conformance pass remain the recorded gaps (MoE-2, Phase 5).

### 2026-07-08 Phase 0 — roc#9964 wide-record JSON SIGSEGV no longer reproduces on current nightly

Classification: compiler
Severity: friction (downgraded from blocker; issue still open upstream)
Evidence: `roc check wip/research/wide_record_json_sigsegv_repro.roc`
(50-field record, updated to the new `Json.ParseErr` idiom) exits 0 in
~1.0s on nightly-2026-July-07 (`release-fast-050c6975`); on
`release-fast-c0cae661` the same check exited 139 (SIGSEGV). roc-lang/roc#9964
remains open upstream — not yet closed or commented, so treat the fix as
unconfirmed-by-upstream and keep the repro file until it closes.
`examples/service-ops-center/Dashboard.roc` still `roc check`s in ~64s with
its ten-way split parse; whether a single wide parse is now both correct
and fast is a follow-up measurement (recorded in
`wip/research/json_codec_evidence.md` as a reopen note). Conduit DTOs are
narrow (~10 fields + nested author), so Api.roc plans single parses per DTO
either way.
Action: accepted as app code (single-parse DTOs in conduit Api.roc);
re-verify against roc#9964 when upstream closes it; json_codec_evidence.md
refreshed with the recheck.
