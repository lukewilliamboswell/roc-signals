# GUI examples review backlog

Reviewed 2026-09-10 at `6067ce9745adafb48b363a6364e448322ecab213`.
Scope: all six maintained `examples-gui` apps, their public GUI/Files seams,
and the tests and documentation that teach their behavior. This is a triaged
backlog, not an implementation change or a replacement for `design.md`.

[Evidence, screenshots, commands, and reproductions](gui-examples-review/2026-09-10/README.md).
All six apps checked, built, and passed their Roc tests; all 42 maintained
semantic specs passed. Four additional diagnostic specs fail. A real GPUI
desktop interaction also reproduced cross-task native undo contamination.
The passing suite therefore does not establish that the examples are correct
or usable at the supported window sizes.

P1 = data integrity or core workflow obstruction; P2 = substantive correctness,
usability, or maintainability; P3 = refinement. **All items below are open.**
“Reproduced” means executed here; “source” means a traced code path;
“design” means a recommendation, not a demonstrated functional defect.

## Queue

| ID | Priority | Work item | Evidence | Primary owner |
| --- | --- | --- | --- | --- |
| GUI-01 | P1 | Notes: isolate every accepted document's native editor lifetime | Failing spec + source | Notes workflow |
| GUI-02 | P1 | Board: isolate native edit history between tasks/documents | Desktop reproduction + failing spec | Board view/lifecycle |
| GUI-03 | P1 | Board: make the complete board and detail actions reachable | Screenshots + wheel attempts | Board layout; GPUI verification |
| GUI-04 | P1 | Keep confirmation dialogs inside the allowed viewport | Screenshot | GUI dialog layout + Notes |
| GUI-06 | P2 | Account for all payload retained by board history | Source | Board history |
| GUI-07 | P2 | Replace duplicated handwritten theme JSON grammar with builtin codecs | Pinned compiler probes + source | Theme examples |
| GUI-08 | P2 | Defaulted nominal `Gui.Style` records | Pinned compiler probes | Public Roc GUI API |
| GUI-09 | P2 | Make asset-verification warnings match rendered behavior | Source | Board/Explorer asset views |
| GUI-10 | P2 | Explorer: fit list, inspector, and preview at smaller heights | Screenshots + wheel attempts | Explorer layout |
| GUI-11 | P2 | Explorer: present successful previews as readable content | Screenshot + source | Explorer; possibly public read-only control |
| GUI-12 | P2 | Activity: preserve useful event space at 800×600 | Populated screenshots | Activity layout |
| GUI-13 | P2 | Give cards and event rows coherent activation and selection | Screenshots + source | Examples + GUI interaction API |
| GUI-14 | P2 | Complete the Counter theme demonstration | Source + baseline screenshot | Counter theme/view |
| GUI-15 | P2 | Give windows application/document identity | Source | GUI title boundary + examples |
| GUI-16 | P2 | Add interaction/resize evidence to the GUI verification workflow | Coverage gap | GUI tests/tooling |
| GUI-17 | P2 | Strengthen example lifecycle and changed-set work assertions | Source/coverage gap | Native semantic specs |
| GUI-18 | P2 | Make toolbars, inspectors, and tabular content easier to scan | Screenshots; design | Board/Explorer/Activity views |
| GUI-19 | P2 | Review minimal typography/alignment/truncation capabilities | Source; design | Public GUI style protocol |
| GUI-20 | P2 | Make shortcut and keyboard behavior discoverable and platform-appropriate | Source; cross-OS validation needed | Examples + native keyboard tests |
| GUI-21 | P3 | Make the teaching examples smaller and more idiomatic | Source | Example structure |
| GUI-22 | P3 | Correct maintained docs and small presentation-copy defects | Source + screenshots | Example/reference docs |
| GUI-23 | P3 | Finish the remaining application-controlled chrome/theming surface | Source; design | GUI/GPUI boundary |
| GUI-24 | P3 | Optional visual refinements, after operability | Design | Examples + narrowly justified API work |

## Correctness and operability

### GUI-01 — Notes document lifetime

`Workflow.bindings` installs reads with `Session.from_file(file)`
([Workflow.roc](../examples-gui/notes-editor/Workflow.roc), lines 55–58).
That constructor resets `document_generation` to zero; `Session.loaded`
already advances it, but is not used by this path
([Session.roc](../examples-gui/notes-editor/Session.roc), `from_file`, `loaded`).
The editor's `Ui.switch` is keyed by that generation. Opening a file whose text
equals the current body can therefore retain the previous document's editor.
This matters because equal controlled-value echoes intentionally preserve
native selection/history; clearing them on every equal echo would violate the
editing contract, not fix the application.

Reproduction: [notes-open-lifetime.scm](gui-examples-review/2026-09-10/repros/notes-open-lifetime.scm)
expects one new input binding on an equal-text open; observed zero.
The document-lifetime failure is reproduced; its undo consequence in Notes is
source-traced, not a desktop file-chooser test.

Acceptance: every successful document replacement gets a fresh identity even
for equal text; ordinary typing, saves, and temporary availability changes do
not remount the editor. Cover repeated opens, New, Revert, cancellation, failed
reads, equal text, and generation exhaustion. Add native control undo/selection
coverage as well as application semantic assertions.

### GUI-02 — Board editor ownership

`detail_view` switches only on `editor.column`
([main.roc](../examples-gui/task-board/main.roc), lines 411–413). Different tasks
in the same column share the input lifetimes. If a field's value is equal,
GPUI correctly retains that input's existing native history, which now belongs
to a different task. Replacing an entire document needs the same identity audit.

Desktop reproduction: add `duplicate`; type `private` into its notes; select
all and delete; add `second`; focus its empty notes and press Ctrl+Z.
`private` appears in `second`:
[before](gui-examples-review/2026-09-10/task-board-second-before-undo.png),
[after](gui-examples-review/2026-09-10/task-board-second-after-undo.png).
[A separate semantic diagnostic](gui-examples-review/2026-09-10/repros/board-editor-lifetime.scm)
also observes zero new scopes when selecting another equal-valued task.

Acceptance: explicitly identify the edited document/task lifetime; keep the
draft owned above card/filter scopes, but prevent native history and selection
from crossing task/document boundaries. Test same-column selection, equal
fields, replacement documents with reused keys, transfers, filtering, domain
undo/redo, and disposal. Do not make the host infer identity from text or keys
hidden in labels. Preserve ordinary input-echo history.

### GUI-03 — Board scrolling and detail reachability

At 1200×820, the default detail panel ends at the priority controls: movement
and deletion controls below them are off-screen. Added cards also fall below
the viewport. At 800×600 the detail panel is almost entirely off the right
edge. Wheel-down attempts over the detail editor and the outer left margin
did not reveal the missing controls:
[initial](gui-examples-review/2026-09-10/task-board-wide.png),
[detail wheel](gui-examples-review/2026-09-10/task-board-wide-after-scroll.png),
[outer wheel](gui-examples-review/2026-09-10/task-board-root-scroll.png),
[800×600](gui-examples-review/2026-09-10/task-board-800x600.png).

The board region clips both axes; the inner column group declares horizontal
scrolling, but the detail panel has no vertical scroll region
([main.roc](../examples-gui/task-board/main.roc), `board_view`, `column_view`,
`detail_view`). The host has a window scrolling fallback; its existence is
not evidence that clipped descendant controls are reachable. These wheel
checks do not exhaust keyboard or scrollbar paths.

Acceptance: explicitly size and scroll board columns and the detail region;
all seeded and newly appended cards and all detail actions must be reachable
by pointer and keyboard at the supported sizes. Keep scroll ownership clear;
do not repair this with host tree scans or application-state layout inference.
Test large boards, long titles/notes, filtering, focus visibility, and resize.
If a new minimum size is chosen, make it an explicit public/window contract,
not a silent replacement for usable overflow.

### GUI-04 — Viewport-bounded dialogs

Notes' normal discard dialog is readable at 1200×820, but at 360×600 its
heading and safe action extend off the left edge and the explanation is cut
off on the right:
[wide](gui-examples-review/2026-09-10/notes-editor-discard-dialog.png),
[narrow](gui-examples-review/2026-09-10/notes-editor-dialog-360x600.png).
The host currently permits a 360×240 minimum window. Notes supplies a complete
style without a width constraint; the centered dialog can keep its intrinsic
content width. The fixed default dialog width must be audited too.

Acceptance: dialog bounds, wrapping, internal scrolling, and action layout
work within every allowed viewport. Verify safe initial focus, visible focused
controls, Tab/Shift+Tab, Escape, resize while open, and long copy. Cover board
delete/replace/close dialogs too; those were not desktop-captured in this pass.
Preserve modal admission and engine-owned lifecycle semantics.

### GUI-06 — Board history payload accounting

Deletion subtracts the task from `bytes` and sets `editing = False`, but leaves
the full deleted value in `editor.task` ([main.roc](../examples-gui/task-board/main.roc),
`delete_confirmation`). `BoardSnapshot` retains that editor alongside the rows;
subsequent history snapshots can retain text no longer included in the charged
row payload. `trim_history` trusts `item.bytes`. Large editable drafts make
this material, even though file decoding enforces smaller field limits.

The accounting omission is source-confirmed. No allocator-measured peak or
specific four-MiB overrun was measured here; the 50-entry count bound still
exists, so this is not a claim of unbounded history.

Acceptance: clear inactive editor payload or charge every independently
retained payload under an explicit conservative rule. Test delete → subsequent
changes → undo/redo with large unique text, inactive editors, saved baselines,
and branch retirement. Derive accounting checks from actual retained values,
not only synthetic snapshots with a manually set `bytes` field. Clarify which
budgets cover history versus live drafts, saved baselines, and pending saves.

## Roc and public API ergonomics

### GUI-07 — Builtin JSON codecs for themes

[Counter Theme.roc](../examples-gui/counter/Theme.roc) and
[Notes Theme.roc](../examples-gui/notes-editor/Theme.roc) are identical 255-line
modules containing their own object/string/number JSON parser. This obscures
the tiny Counter example and deliberately rejects valid JSON escape forms.
The handwritten number parser also accepts leading-zero numbers and has an
overly restrictive U32 cutoff; layout bounds deserve semantic validation
instead of a bespoke numeric grammar.

The sibling Roc language reference documents derived `parser_for` and
`encoder_for`: structural records derive automatically, nominal types opt in.
Pinned-compiler [probes](gui-examples-review/2026-09-10/probes/CodecProbe.roc)
confirm `Json.parse`/`Json.to_str`, nominal opt-in, existing snake_case field
names, and leading-zero rejection. Example shape:

```roc
ThemeWire := { background : Str, gap : U32 }.{
    parser_for : _
    encoder_for : _
}
```

This is **not** a blanket finding that every example hand-rolls JSON:
[Board Codec.roc](../examples-gui/task-board/Codec.roc) and both manifest
modules already use `Json.parser_camel()`; board encoding uses `Json.to_str`.
Those are builtin-codec users, not parser replacements to queue.

Compatibility gate: the probe shows `Json.parse("{\"gap\":8,\"gap\":9}")`
accepts the duplicate and keeps `9`. The current theme contract rejects
duplicates. A direct derived-record replacement therefore changes meaning.
Resolve duplicate detection through supported codec hooks/validation before
removing the old parser; post-decode field inspection cannot recover discarded
duplicates. If the pinned builtin cannot express the contract, record the
precise limitation and keep the necessary workaround narrow and identifiable.
Do not silently weaken rejection or copy a second JSON grammar elsewhere.

Acceptance: builtin syntax parsing plus small domain validation for `#RRGGBB`,
layout bounds, required/unknown/duplicate keys, and useful filename/key errors.
Preserve compile-time theme loading and current JSON field names. Cover malformed
JSON, escapes/Unicode, numeric boundaries, missing/wrong fields, and duplicates.
Share the schema/validation where appropriate without introducing a platform
theme engine. Keep the board's existing version-1/priority-string wire contract.
The documented wasm32 camel-field bug is not evidence against native themes;
retest it separately if code becomes shared with browser examples.

### GUI-08 — Defaulted nominal styles (Richard Feldman's suggestion)

Currently `Gui.Style` aliases the complete structural `Presentation` record,
so callers repeatedly spread `Gui.style_default`
([Gui.roc](../platform-gui/Gui.roc), `Presentation`, `Style`, `style_default`).
A transparent nominal record with `??` field defaults removes this noise while
still materializing a complete presentation value.

The cross-module [six-test probe](gui-examples-review/2026-09-10/probes/StyleProbe.roc)
passes on the pin: omitted defaults, explicit zero, record update, nominal
equality, and a single-field shorthand with a trailing comma. Use numeric
literal suffixes such as `16.U32` when constraining a numeric value.

```roc
# Proposed call forms, after migrating the public Style type:
Gui.style({ padding: 16.U32 })
padding = 16.U32
Gui.style({ padding, })
```

Syntax qualification: `{ padding }` is a **block expression**, not a record,
in the current language reference and pinned compiler. `{ padding, }` works.
Bare `style({})` also failed in the probe; explicit nominal construction
(`StyleApi.Style.{}` in the probe) works. Do not promise the exact empty/shorthand
spelling without testing it. These results do not certify a full GUI migration.

Acceptance: default every presentation field to the existing neutral value;
derive `is_eq` for the nominal style; test `style_s` and mapped/state-backed
styles on the real platform, including equal-value pruning and typed records
constructed outside a call. Update public docs and all affected examples.
Audit source compatibility and give a clear migration for pretyped structural
records. Omitted style must still select the control helper's defaults;
supplying a style must still replace the **complete** record. No implicit
partial merging or special “unset” semantics. Preserve the encoded v2 fields
and validation; a nominal type change alone should not change the wire format.

## Visual and interaction backlog

### GUI-09 — Truthful asset verification

Both apps promise placeholder boxes for missing **or mismatched** assets
([board](../examples-gui/task-board/main.roc), `asset_problem_text`;
[explorer](../examples-gui/folder-explorer/main.roc), `asset_problem_text`).
Verification only changes warning text. `avatar`/`kind_glyph` do not depend on
verification, and [GPUI rendering](../crates/gpui-host/src/lib.rs) resolves and
renders an existing image independently. An altered but valid image is not
necessarily replaced by a placeholder. Startup verification is also not a
continuous watch for later restoration.

Acceptance: decide whether verification is advisory or gates image rendering,
then make messages, README claims, bindings, and tests agree. Test missing,
altered-but-decodable, invalid image, healthy, and restored assets. If gating
is chosen, use explicit application data/signal dependencies and specify retry
behavior; do not infer reactive policy inside the image loader.

### GUI-10 — Explorer height/overflow

At 800×600 the list and inspector run below the viewport; the preview and
footer disappear. Wheel attempts over the inspector leave the same clipped
result. At 1200×820, a selected file's preview is still pushed to the bottom:
[small](gui-examples-review/2026-09-10/folder-explorer-800x600.png),
[after wheel](gui-examples-review/2026-09-10/folder-explorer-800x600-after-scroll.png),
[preview](gui-examples-review/2026-09-10/folder-explorer-preview.png).
See [main.roc](../examples-gui/folder-explorer/main.roc), root `overflow_y: Clip`,
the growing content row, fixed-width details, and preview `height: Fill`.

Acceptance: bounded list and inspector regions with usable explicit overflow;
compact or reflow header controls as needed. Retain a useful preview area and
access to status/errors. Test resizing with a selected file and preview, long
paths, long errors, filter/sort, and list scrolling. Keep virtual row height and
selection/focus decoration within the declared 44-pixel contract.

### GUI-11 — Preview is not a disabled operation

Explorer permanently sets `Gui.disabled_s(True)` on the preview textarea. A
successful preview is consequently dimmed to 45% opacity and removed from Tab
navigation ([main.roc](../examples-gui/folder-explorer/main.roc), `details`;
[input.rs](../crates/gpui-host/src/input.rs), `set_disabled`).
[The loaded-preview screenshot](gui-examples-review/2026-09-10/folder-explorer-preview.png)
looks unavailable even though content was successfully loaded.

This is not a claim that copy is wholly impossible: native disabled inputs
deliberately retain pointer selection and copying. The issue is presentation
and keyboard reachability. Acceptance: normal readable contrast, keyboard
focus/selection/copy/scroll, and no edits or edit-history actions. Evaluate a
proper read-only presentation contract or a selectable text view; do not merely
enable the textarea and ignore its change events, leaving native text divergent
from the authoritative source.

### GUI-12 — Activity content area

At 800×600 five sample events occupy a region showing roughly two complete
rows, with message text cut off horizontally by the fixed inspector. The
banner, source controls, status, replay controls, counters, and filters consume
most of the height:
[populated wide](gui-examples-review/2026-09-10/activity-monitor-populated.png),
[populated small](gui-examples-review/2026-09-10/activity-monitor-populated-800x600.png).
The list can scroll; this is severe space allocation, not evidence that events
are lost.

Acceptance: consolidate controls/status, phase-gate irrelevant Retry/Cancel,
and size/reflow the inspector so messages remain useful. Preserve the explicit
simulated-versus-real source label. Test long log messages, follow-tail on/off,
selection, resize, paused replay, and file-reading/error states.

### GUI-13 — Row/card affordances and focus

Board cards are inert outside their repeated `Edit` buttons; Activity places
a large `Inspect N` button in every 44-pixel row. Those controls compete with
the data, and their focus/selection decoration crowds the fixed-height rows
([board](gui-examples-review/2026-09-10/task-board-wide.png),
[activity](gui-examples-review/2026-09-10/activity-monitor-inspector.png)).
Explorer has already flattened its name buttons; don't undo that improvement.

Acceptance: a coherent pointer and keyboard activation target with meaningful
accessible naming and visible, non-layout-shifting focus/selection. First
evaluate composition with existing controls; if a composite button or explicit
activation attribute is necessary, specify event admission, nested interactive
children, drag-versus-click behavior, and lifetime validation across all layers.
Do not attach unguarded host callbacks to arbitrary containers.

### GUI-14 — Counter theme completeness and small-example sizing

The Counter says switching its imported JSON rebuilds the whole app in the
alternate palette. Its root never uses `theme.background`, Decrement/Reset use
host-default buttons, and panel radius is hardcoded. The high-contrast file
therefore cannot control the whole presentation. The fixed 380-pixel panel
also overflows a 360-pixel window:
[wide](gui-examples-review/2026-09-10/counter-wide.png),
[narrow](gui-examples-review/2026-09-10/counter-360x600.png).

Acceptance: define the intended coverage of the theme example and make it true;
use the declared palette for root and controls, or narrow the promise explicitly.
Verify default and high-contrast screenshots including interaction states.
Keep Counter minimal and readable after GUI-07/08. Apply the same bounded-width
lesson to Keyed Rows' fixed 520-pixel body and long teaching text
([narrow](gui-examples-review/2026-09-10/keyed-rows-360x600.png)).

### GUI-15 — Window identity

[lib.rs](../crates/gpui-host/src/lib.rs), window creation, hardcodes
`Roc Signals` for every example. Different apps/documents are indistinguishable
by title in the desktop switcher. Kiosk screenshots omit frame chrome; this
finding comes from source, not the screenshots.

Acceptance: a deliberate public GUI title route, initial app identity, and
document/dirty-state updates where useful. Reuse the shared engine's command
model and observability; audit existing title support before inventing another
route. Verify close/reopen/lifetime behavior and all native OS integrations.

## Verification and maintainability

### GUI-16 — Desktop regression coverage

`gui_smoke.py` checks that each app mounted/rendered, with one Counter action.
The maintained semantic specs cannot observe visual clipping or native input
history ownership. Both missed GUI-02, and initial screenshots alone missed
the same bug until a multi-task interaction was performed.

Acceptance: deterministic private-display captures/interaction checks for all
six apps; initial, populated, selected, focused, disabled/read-only, modal,
error/loading, and resized states chosen by risk. Include equal-text editor
replacement and reachability of off-screen actions. Test normal framed windows,
minimum dimensions, representative scaling/font environments, and supported OS
behavior. Keep native semantic/work assertions separate from GPUI presentation
checks; use semantic locators or host tests where possible rather than making
pixel coordinates the long-term interaction contract. Preserve artifacts on
failure and avoid capturing the user's desktop.

### GUI-17 — Lifecycle/work budgets in the example specs

[Keyed Rows' lifecycle spec](../examples-gui/keyed-rows/specs/lifecycle.scm)
checks draft values but not exact move/rebuild work or timer disposal/recreation.
The app's scope clock is an opportunity to teach and test the lifecycle contract.
Folder selection has some structural assertions; add bounded incidental work
and larger-dataset comparisons where the example promises changed-set behavior.
Activity's replay spec already asserts one appended row and no moves/removals:
retain that coverage and extend it to pruning/filter/follow-tail boundaries.

Acceptance: exact structural counts for moves, disposal and replacement;
bounded unrelated recomputation on selection; equality no-ops; timer/task
cancellation and late-result refusal. Separate explicitly whole-dataset work
(filter/sort/import) from changed-set paths. Use optimized scaling measurements
only if making performance claims. Add sequence/fuzz oracles for history and
lifetime boundaries when fixes expose a sequence-dependent class; validate an
oracle against a deliberately broken implementation as required by AGENTS.md.

### GUI-18 — Hierarchy, density, and information layout

Screenshots show table-like Explorer/Activity rows with no header labels;
Activity inspector concatenates identity, severity, component, and message into one string;
Explorer repeats preview/status explanations; Board mixes teaching paragraphs
with working controls. Multiple heading levels use the same host heading
treatment, and toolbar labels use padding to approximate baseline alignment.
Breadcrumbs are adjacent buttons without clear hierarchy separators.

Acceptance: label aligned data columns, lay out inspector metadata separately
from content, distinguish page/section headings, consolidate quiet status and
help, and give breadcrumbs a clear path hierarchy. Add correct singular/plural
copy (`1 tasks`, `1 words` are visible in this review). Use existing style
capabilities first; retain semantic labels and the honest sample/replay notices.
Check long values and narrow sizes, not just seeded text. A strict “one accent
per screen” rule is a design option, not a correctness requirement.

### GUI-19 — Minimal layout/text API work

The current complete style record has no application-selected font weight,
cross-axis alignment/justification, text alignment, per-side padding, ellipsis,
or independent line-height control. The host **does** give headings a fixed
semibold treatment; this is not a total absence of font weight. Missing
alignment encourages padded-wrapper workarounds; hard clipping leaves long
messages without a clear truncation affordance.

Acceptance: choose the smallest additions justified by GUI-03/10/12/18 and
test them in real examples before expanding the whole style vocabulary.
Review semantics against `design.md`; update Roc producer, native ABI/typed
validation, shared engine sinks, GPUI consumer, specs, maintained docs, and
bundles wherever affected. If wire fields change, advance the current v2
protocol coherently. Keep `style_s` ordinary equality-pruned propagation.

### GUI-20 — Keyboard and accessibility follow-through

Board and Notes bind shortcuts but provide little on-screen discovery;
Explorer's footer has bindings but is clipped in the captured layouts.
Application shortcuts use `control: True, meta: False`; native macOS convention
and interaction with input-local shortcuts need explicit cross-OS testing.
Repeated `Edit`/`Inspect N` labels lack the context of the item they activate.

Acceptance: discoverable, accurate shortcut help; meaningful control names;
predictable Tab order and visible focus; keyboard access to preview and all
detail actions; platform-appropriate modifiers without duplicate dispatch.
Verify focused text undo versus domain undo, modal admission, and focus
restoration. Screen-reader behavior was not tested here: audit the actual
native accessibility output instead of treating semantic-spec labels as proof.

### GUI-21 — Teaching/example structure

Board `main.roc` is 1,130 lines and nests fourteen `Ui.state` constructions;
document workflow, history, and view composition are hard to review together.
Theme modules and manifest validation are duplicated. Keyed Rows still calls
its invariant failures “spike” errors.

Acceptance: extract cohesive History/Document/Workflow/view helpers while
keeping sources granular and ownership obvious. Do not collapse independent
state into a coarse model merely to reduce nesting. Make the first example
about Signals, with JSON grammar removed by GUI-07 and record noise reduced by
GUI-08. Prefer existing language facilities and clear numeric literals such as
`16.U32`; keep type annotations where they communicate record/nominal contracts.

### GUI-22 — Truthful maintained documentation

[Explorer README](../examples-gui/folder-explorer/README.md) says Linux and
`gio open`, while the native file services have Windows/macOS implementations;
it says 64-pixel virtual rows while the app declares 44. Both asset READMEs
overpromise verified placeholders (GUI-09). Counter's whole-palette promise
needs GUI-14.

Acceptance: synchronize examples, public references, platform modules, specs,
and contributor commands when fixing each item. Clearly distinguish supported
behavior from tested OS coverage and known limitations.
Keep this backlog in planning as requested; move stable contracts to their
authoritative docs and reproducible compiler limitations to
`UPSTREAM_COMPILER_BUGS.md`, not into AGENTS.md.

### GUI-23 — Remaining theme ownership gaps

The host still controls selected/focus treatment, disabled opacity, textarea
caption color, frame/titlebar colors, scrollbars, modal scrim, drag ghost, and
drop highlight. See [lib.rs](../crates/gpui-host/src/lib.rs),
[window_frame.rs](../crates/gpui-host/src/window_frame.rs),
[scrollbars.rs](../crates/gpui-host/src/scrollbars.rs), and
[drag.rs](../crates/gpui-host/src/drag.rs). A Fill/Fill application
root can already cover the host background; that is not the same as owning
window chrome. Button hover/active and editor foreground/background/cursor/
selection support are already available.

Acceptance: select explicit application-controlled values only where examples
need them; preserve accessible defaults and non-layout-shifting state styling.
Keep theme data in Roc and presentation adaptation in the host—no global mutable
theme service or second reactive mechanism. Test light/high-contrast palettes
across focus, selection, disabled, drag and modal states. Coordinate actual
protocol additions with GUI-19 rather than creating another style channel.

### GUI-24 — Optional refinements

Tooltips for help/shortcuts, per-side borders/dividers, configurable cursors for
new activation targets, and restrained dialog elevation may improve polish.
Existing buttons already use pointer cursors. Motion/shadows are lower priority
than readable content, safe dialogs, and reachable controls.

Acceptance: demonstrate the need in an example before adding public APIs;
keep help available to keyboard users, avoid relying on color alone for danger,
and consider reduced motion if animation is introduced. No fixed API shape or
mandatory spacing/color dogma is approved by this backlog.

## Delivery sequence

1. Reproduce and fix GUI-01/02 with native input history coverage; address
   GUI-03/04 core reachability in parallel with their presentation tests.
2. Close the GUI-06 accounting defect. Add GUI-16/17 regressions
   alongside each fix, not only at the end.
3. Resolve GUI-07's codec compatibility gate and migrate GUI-08. These simplify
   later example edits without needing new rendering semantics.
4. Apply current-API layout/readability fixes (GUI-09–14, GUI-18); use evidence
   from them to scope GUI-19/20/23. Window titles (GUI-15) are a distinct boundary
   change, not a styling workaround.
5. Finish structure/docs and optional polish (GUI-21/22/24), then recapture the
   same states. Remove resolved work from this queue; do not treat a fresh
   screenshot alone as proof of lifecycle, performance, or cross-OS correctness.

This file tracks open work, not completed milestones or historical rationale.
Keep supporting evidence while it is useful to an open item; fold regression
cases into the maintained suite as fixes land. Git history retains prior plans.
