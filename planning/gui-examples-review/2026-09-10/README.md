# Evidence for the open GUI examples backlog

[Current backlog](../../gui-examples-backlog.md). These captures and probes
support its open items; they are not a screenshot approval baseline or a claim
that every GUI state has been reviewed. Retire planning evidence when the
relevant regression coverage and fixes land.

## Build and verification

Application source: `6067ce9745adafb48b363a6364e448322ecab213`, initially clean.
Compiler: `nightly-linux_x86_64-2026-09-04-c125b82`, the pinned GUI version.
Applications were built freshly with `--target=x64glibc --opt=dev --no-cache`,
using the already-staged native host libraries in `platform-gui/targets/x64glibc`.
This review did not rebuild or establish a fresh source-provenance receipt for
those host archives. Their SHA-256 hashes identify the actual linked inputs:

```text
libsignals_gpui_host.a  6d9a5b7ccb2df23d29fdae0bbd42bc0ffe452df3a1b464b134c4bb7c5dfa346c
libengine.a             88d2f2717f60c9751b21c00dfde518d2985ee2e85c7162cd449cb44734dffae9
```

| App | `roc check` / build | Roc tests, including imports | Maintained semantic specs |
| --- | --- | --- | --- |
| Counter | Pass / pass | 46 passed | 1 passed |
| Keyed Rows | Pass / pass | 42 passed | 1 passed |
| Notes | Pass / pass | 62 passed | 12 passed |
| Board | Pass / pass | 52 passed | 16 passed |
| Explorer | Pass / pass | 60 passed | 7 passed |
| Activity | Pass / pass | 55 passed | 5 passed |

The imported-test counts overlap; do not sum them as distinct tests.
All 42 maintained semantic specs passed at the reviewed commit. Four additional
diagnostics failed at their intended assertions. The two editor-lifetime
diagnostics have since been fixed; maintained specs in
`examples-gui/notes-editor/specs/` and `examples-gui/task-board/specs/` now
cover that behavior, so only the two Windows-path diagnostics remain below. The codec probe passes five tests and the
cross-module style probe passes six. `zig build run-check-tidy` passed.

For setup and staging, use the maintained
[contributor workflow](../../../www/content/docs/contributing.md).
From the repository root, the per-app commands used were equivalent to:

```sh
export ROC_BIN=/path/to/roc_nightly-linux_x86_64-2026-09-04-c125b82/roc
review_output=/path/to/review-output
review_app=notes-editor
"$ROC_BIN" check "examples-gui/$review_app/main.roc"
"$ROC_BIN" test --no-cache "examples-gui/$review_app/main.roc"
"$ROC_BIN" build --target=x64glibc --opt=dev --no-cache --output="$review_output/$review_app" "examples-gui/$review_app/main.roc"
python3 scripts/spec_driver.py "$review_output/$review_app" "examples-gui/$review_app/specs" --jobs 2
```

## Desktop capture conditions and limits

Linux x86_64; isolated Xvfb display, Weston 13's X11 backend with Pixman and
kiosk shell, and Mesa's software Vulkan driver. Only review applications were
launched in that private display. Captures are unedited screenshots of the
private compositor output, not generated mockups or the user's desktop.

The compositor output was resized to 1200×820, 800×600, or 360×600 before
capture. Kiosk mode gives the app the whole output; these are content-area
dimensions and omit ordinary titlebar/window-frame chrome. Board and Explorer
were launched with their checked-in `assets/` directories as `--assets-root`.
Pointer/key input used XTEST; screenshots used Pillow's X11 ImageGrab. No
existing example source or asset was modified for the captures.

The sample data is deterministic except Keyed Rows' displayed scope clock.
Activity captures use Step replay rather than a free-running timer. Some shots
include focus or a hovered pointer; these are useful state evidence, not a
pixel-normalized visual regression suite.

Not validated: actual Windows/macOS desktop operation, regular window chrome,
screen readers, high-DPI/scaling variants, OS chooser dialogs, long-running
memory behavior, all loading/error states, all drag interactions, or an alternate
theme build. Windows diagnostic results are injected into the Linux semantic
host, not evidence of a completed Windows end-to-end test. Source-only concerns
are labeled as such in the backlog.

## Screenshot index

| App/state | Screenshot | Open items |
| --- | --- | --- |
| Counter initial, 1200×820 | [wide](counter-wide.png) | GUI-14 |
| Counter, 360×600 | [narrow](counter-360x600.png) | GUI-14 |
| Keyed Rows initial, 1200×820 | [wide](keyed-rows-wide.png) | GUI-14/17/21 |
| Keyed Rows, 360×600 | [narrow](keyed-rows-360x600.png) | GUI-14 |
| Notes initial, 1200×820 | [wide](notes-editor-wide.png) | GUI-18 |
| Notes initial, 800×600 | [smaller](notes-editor-800x600.png) | GUI-16; useful non-modal control |
| Notes discard confirmation, 1200×820 | [dialog](notes-editor-discard-dialog.png) | GUI-04/18 |
| Same dialog after resize to 360×600 | [clipped dialog](notes-editor-dialog-360x600.png) | GUI-04 |
| Board initial, 1200×820 | [wide](task-board-wide.png) | GUI-03/13/18 |
| Board initial, 800×600 | [smaller](task-board-800x600.png) | GUI-03 |
| Board after five wheel-down events over notes | [detail wheel](task-board-wide-after-scroll.png) | GUI-03 |
| Board after adding first task | [new task](task-board-new-task.png) | GUI-03 |
| Board after five wheel-down events over outer margin | [outer wheel](task-board-root-scroll.png) | GUI-03 |
| Explorer initial, 1200×820 | [wide](folder-explorer-wide.png) | GUI-10/18 |
| Explorer initial, 800×600 | [smaller](folder-explorer-800x600.png) | GUI-10 |
| Explorer after three wheel-down events over inspector, 800×600 | [after wheel](folder-explorer-800x600-after-scroll.png) | GUI-10 |
| Explorer sample README selected and previewed, 1200×820 | [preview](folder-explorer-preview.png) | GUI-10/11/18 |
| Activity initial, 1200×820 | [wide](activity-monitor-wide.png) | GUI-18 |
| Activity after five Step replay clicks, 1200×820 | [populated](activity-monitor-populated.png) | GUI-13/18 |
| Activity with Inspect 1 selected, 1200×820 | [inspector](activity-monitor-inspector.png) | GUI-13/18 |

For the dialog reproduction, type `draft` into a fresh Notes editor, click New,
then resize the open discard confirmation from 1200×820 to 360×600.
For the Explorer preview, select the sample `README.md` and click Preview text.

## Retired diagnostic specs

The four diagnostics this review shipped — the Notes and Board editor-lifetime
cases and the two Windows-path cases — have been fixed and now live in the
maintained suites under `examples-gui/notes-editor/specs/`,
`examples-gui/task-board/specs/` and `examples-gui/folder-explorer/specs/`.
Their scope counts prove editor *replacement*, not native undo isolation; that
distinction is still real and is why GUI-16 asks for native interaction
coverage.

## Pinned Roc probes: GUI-08

```sh
"$ROC_BIN" test --no-cache planning/gui-examples-review/2026-09-10/probes/StyleProbe.roc
```

The GUI-07 codec probe has been retired. Everything it characterized — builtin
JSON syntax, snake_case field names, leading-zero rejection, numeric bounds, and
duplicate-key handling — is now asserted by the maintained tests in
`examples-gui/counter/Theme.roc`.

[StyleApi.roc](probes/StyleApi.roc) and [StyleProbe.roc](probes/StyleProbe.roc)
verify cross-module transparent nominal defaults, explicit zero, record update,
shorthand with a comma, and equality. They model the type/call-boundary idea,
not the complete platform `style_s`/ABI migration.

Additional rejected call forms during investigation:

```roc
StyleApi.style({})             # {} does not coerce to StyleApi.Style on this pin.
padding = 16.U32
StyleApi.style({ padding })    # This is a block returning U32, not a record.
```

`StyleApi.style(StyleApi.Style.{})` and
`StyleApi.style({ padding, })` pass. The one-field block/record distinction is
documented language syntax, not a compiler defect to work around in the GUI API.

Local primary references inspected in the sibling `roc` checkout at
`53863b31f951daa8307ccd22f343bf7e39870046`:

- `docs/langref/static-dispatch.md`: derived `parser_for`, `encoder_for`, and
  nominal opt-in; structural derivation.
- `docs/langref/types.md`: transparent nominal record literal construction.
- `docs/langref/expressions.md`: `{ x }` is a block, unlike a record literal.
- `test/cli/BoxyOptionalRecordFields.roc`: nominal fields with `??` defaults.
- `test/cli/JsonOptionalFieldKinds.roc`: defaulted JSON fields and nominal hooks.

The dedicated `records.md` default-field and `parsers.md` reference sections
are still placeholders in that checkout; executable probes on the actual pin
are the evidence for readiness. No compiler or application fixes were made as
part of this triage.
