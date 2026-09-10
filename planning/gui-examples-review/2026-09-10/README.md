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
All 42 maintained semantic specs passed. The four additional diagnostics below
fail at their intended assertions. The codec probe passes five tests and the
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
| Board after adding first task | [new task](task-board-new-task.png) | GUI-02/03 |
| Second task before native undo | [before](task-board-second-before-undo.png) | GUI-02 |
| Second task after native undo | [after](task-board-second-after-undo.png) | GUI-02 |
| Board after five wheel-down events over outer margin | [outer wheel](task-board-root-scroll.png) | GUI-03 |
| Explorer initial, 1200×820 | [wide](folder-explorer-wide.png) | GUI-10/18 |
| Explorer initial, 800×600 | [smaller](folder-explorer-800x600.png) | GUI-10 |
| Explorer after three wheel-down events over inspector, 800×600 | [after wheel](folder-explorer-800x600-after-scroll.png) | GUI-10 |
| Explorer sample README selected and previewed, 1200×820 | [preview](folder-explorer-preview.png) | GUI-10/11/18 |
| Activity initial, 1200×820 | [wide](activity-monitor-wide.png) | GUI-12/18 |
| Activity initial, 800×600 | [smaller](activity-monitor-800x600.png) | GUI-12 |
| Activity after five Step replay clicks, 1200×820 | [populated](activity-monitor-populated.png) | GUI-12/13/18 |
| Activity with Inspect 1 selected, 1200×820 | [inspector](activity-monitor-inspector.png) | GUI-13/18 |
| Same populated/selected Activity after resize to 800×600 | [populated smaller](activity-monitor-populated-800x600.png) | GUI-12 |

## Native undo reproduction: GUI-02

1. Launch a fresh Board at 1200×820.
2. Enter `duplicate` into New task title and click Add task.
3. In its Task notes field, type `private`, then Ctrl+A and Backspace.
4. Enter `second` into New task title and click Add task.
5. Observe that `second` has empty notes; capture
   [before](task-board-second-before-undo.png).
6. Focus `second`'s Task notes field and press Ctrl+Z.
7. Observe `private` in `second`'s notes; capture
   [after](task-board-second-after-undo.png).

Both tasks remain on the board; this is the input's native history restoring
text from another task, not domain undo deleting the newly created task.
No save or external file write is required.

For the dialog reproduction, type `draft` into a fresh Notes editor, click New,
then resize the open discard confirmation from 1200×820 to 360×600.
For the Explorer preview, select the sample `README.md` and click Preview text.

## Failing diagnostic specs

These are deliberately outside the maintained suite while their backlog items
are open. They document observed failures, not new permanent metric contracts.
Choose the final lifetime assertions alongside the fix and add real native
editor tests; a scope count alone cannot prove history isolation.

| Diagnostic | Executable | Observed failure |
| --- | --- | --- |
| [notes-open-lifetime.scm](repros/notes-open-lifetime.scm) | Notes | `bind_event` delta expected 1, actual 0 |
| [board-editor-lifetime.scm](repros/board-editor-lifetime.scm) | Board | `scopes_created` delta expected 1, actual 0 |
| [notes-windows-name.scm](repros/notes-windows-name.scm) | Notes | Expected `Ideas.txt`; actual `C:\Users\Lee\Ideas.txt` |
| [explorer-windows-breadcrumbs.scm](repros/explorer-windows-breadcrumbs.scm) | Explorer | `Go to C:\Users` locator absent |

Example command from the repository root:

```sh
"$review_output/notes-editor" --run-spec-json planning/gui-examples-review/2026-09-10/repros/notes-open-lifetime.scm
```

The two Windows cases use current raw `files1` task frames because typed file
fixtures reject non-`/`-prefixed paths. They are boundary diagnostics, not
examples of application-facing Files usage or a proposed private-wire API.
Replace them with typed fixtures when GUI-05 makes those values expressible.

## Pinned Roc probes: GUI-07/08

```sh
"$ROC_BIN" test --no-cache planning/gui-examples-review/2026-09-10/probes/CodecProbe.roc
"$ROC_BIN" test --no-cache planning/gui-examples-review/2026-09-10/probes/StyleProbe.roc
```

[CodecProbe.roc](probes/CodecProbe.roc) verifies structural and nominal codecs,
round-trip encoding, snake_case field names, leading-zero rejection, and the
important duplicate-key behavior. Its final test characterizes last-value-wins;
it does **not** endorse that behavior for themes, whose existing contract
rejects duplicates.

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
