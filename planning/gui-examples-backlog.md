# GUI examples review backlog

Reviewed 2026-09-10 at `6067ce9745adafb48b363a6364e448322ecab213`.
Scope: all six maintained `examples-gui` apps, their public GUI/Files seams,
and the tests and documentation that teach their behavior. This is a triaged
backlog, not an implementation change or a replacement for `design.md`.

[Evidence, screenshots, commands, and reproductions](gui-examples-review/2026-09-10/README.md).
All six apps checked, built, and passed their Roc tests; all maintained
semantic specs passed. Two additional diagnostic specs still fail. The passing
suite therefore does not establish that the examples are correct or usable at
the supported window sizes.

P1 = data integrity or core workflow obstruction; P2 = substantive correctness,
usability, or maintainability; P3 = refinement. **All items below are open.**
GUI-17 is closed; GUI-16 is narrowed to what has not been executed here.
“Reproduced” means executed here; “source” means a traced code path;
“design” means a recommendation, not a demonstrated functional defect.

## Queue

| ID | Priority | Work item | Evidence | Primary owner |
| --- | --- | --- | --- | --- |
| GUI-10 | P2 | Explorer: fit the inspector beside the list at the 360-pixel minimum width | Regression bounds at 360x600 | Explorer layout; GUI style protocol |
| GUI-13 | P2 | Give cards and event rows coherent activation and selection | Screenshots + source | Examples + GUI interaction API |
| GUI-16 | P2 | Extend desktop regression coverage to Linux and richer environments | Executed on macOS only | GUI tests/tooling |
| GUI-18 | P2 | Make toolbars, inspectors, and tabular content easier to scan | Screenshots; design | Board/Explorer/Activity views |
| GUI-19 | P2 | Review minimal typography/alignment/truncation capabilities | Source; design | Public GUI style protocol |
| GUI-20 | P2 | Make shortcut and keyboard behavior discoverable and platform-appropriate | Source; cross-OS validation needed | Examples + native keyboard tests |
| GUI-21 | P3 | Make the teaching examples smaller and more idiomatic | Source | Example structure |
| GUI-22 | P3 | Correct maintained docs and small presentation-copy defects | Source + screenshots | Example/reference docs |
| GUI-23 | P3 | Finish the remaining application-controlled chrome/theming surface | Source; design | GUI/GPUI boundary |
| GUI-24 | P3 | Optional visual refinements, after operability | Design | Examples + narrowly justified API work |

## Correctness and operability

## Visual and interaction backlog

### GUI-10 — Explorer height/overflow

The height defect is closed. At 800×600 the list, inspector, preview, shortcut
hint and asset-status line are all laid out inside the window; the root bounds
itself, the content row takes the free height, and the list's virtual viewport
and the inspector each own their scrolling. `inspector-800x600` is an ordinary
check again, joined by `filter-sort-and-scroll-800x600`,
`long-path-360x600` and `preview-is-readable-1200x820`.

What remains is width, and only at the declared 360-pixel minimum. The content
row is wider than that window because neither child will shrink below the
minimum width of what it holds — the inspector's heading and button row, the
footer hint's single unbreakable line — so the inspector is laid out past the
right edge, where nothing can reach it. `long-path-360x600` records this by
asserting the list and the selection rather than the inspector's bounds, and
says so in its front matter.

Acceptance: the inspector is reachable at 360×600. The style vocabulary has no
responsive branch and no maximum length, so this is likely protocol work
(a minimum-width or wrap capability, or a way to express "beside, else below")
rather than another edit to the example. Whatever is chosen, keep the height
behaviour and the 44-pixel row contract that now hold.

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

### GUI-16 — Desktop regression coverage

Scripted interaction and capture scenarios now exist for all six apps in
`examples-gui/<app>/regression/*.script`, run by `scripts/gui_regression.py`
against the real window through the host's `--host-script` flag. They cover initial,
populated, selected, focused, disabled/read-only, modal, error/loading and
resized states at 1200×820, 800×600, 360×600 and the 360×240 host minimum,
including equal-text editor replacement (via native undo depth) and the
reachability of off-screen actions (via recorded layout bounds). Controls are
named by `test_id` or visible label, never by pixel coordinates; native
semantic assertions stay in `specs/` and presentation assertions in
`regression/`. Reports and macOS window captures are written per scenario and
kept for failures; captures name the window by the process id the driver
started and never grab a screen region.

No stated diagnostic is open. A diagnostic that starts passing fails the run,
so each fix has had to promote its own scenario to an ordinary check — that is
how the board editor ownership, board detail reachability, dialog bounds,
counter sizing and explorer inspector fixes were each confirmed.

Two limits found by running the driver against real fixes: a dialog is lifted
into its own render layer and the bounds probe records nothing for it, so
`expect-onscreen` cannot judge a dialog and those scenarios rely on their
capture instead; and a control inside a scrolling region is likewise not
recorded. Both are gaps in the probe, not properties of the applications.

Remaining: the driver has only been executed on Apple Silicon macOS. Window
captures are macOS-only; the scripts themselves need running under the Linux
Xvfb/Weston environment `gui_smoke.py --wayland` provides, and wiring into CI
alongside it. Representative scaling and font environments are not covered:
scenarios run at the default scale factor with the host's own font selection.
Real OS keyboard, pointer, IME and window-manager behaviour is still not
exercised — the scripts dispatch through GPUI's key dispatch inside the
process, which is not the same as the platform delivering the event.

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

Evidence from the closed GUI-12 work: reflowing Activity within the current
vocabulary fixed 800×600, but 360×600 still scrolls sideways because the
toolbar buttons and the filter input are intrinsically wider than the window
and nothing in the style record expresses wrapping, percentage or min/max
lengths. `Gui.heading` also ignores `font_size`, which forced a fixed-width
label column. Those are concrete requirements, not a general wish list.

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
about Signals, now that GUI-07 has removed
the handwritten JSON grammar. Prefer existing language facilities and clear numeric literals such as
`16.U32`; keep type annotations where they communicate record/nominal contracts.

### GUI-22 — Truthful maintained documentation

[Explorer README](../examples-gui/folder-explorer/README.md) says Linux and
`gio open`, while the native file services have Windows/macOS implementations;
it says 64-pixel virtual rows while the app declares 44. Counter's
whole-palette promise needs GUI-14.

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

1. Add GUI-16/17 regressions alongside each fix, not only at the end.
2. Apply current-API layout/readability fixes (GUI-10/11, GUI-13, GUI-18); use evidence
   from them to scope GUI-19/20/23.
3. Finish structure/docs and optional polish (GUI-21/22/24), then recapture the
   same states. Remove resolved work from this queue; do not treat a fresh
   screenshot alone as proof of lifecycle, performance, or cross-OS correctness.

This file tracks open work, not completed milestones or historical rationale.
Keep supporting evidence while it is useful to an open item; fold regression
cases into the maintained suite as fixes land. Git history retains prior plans.
