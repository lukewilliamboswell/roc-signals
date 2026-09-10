# GUI examples review backlog

Reviewed 2026-09-10 at `6067ce9745adafb48b363a6364e448322ecab213`.
Scope: all six maintained `examples-gui` apps, their public GUI/Files seams,
and the tests and documentation that teach their behavior. This is a triaged
backlog, not an implementation change or a replacement for `design.md`.

[macOS evidence, screenshots, commands, and reproductions](gui-examples-review/2026-09-10/README.md).
All six apps check, build and pass their Roc tests and their maintained semantic
specs. The four diagnostic specs this review shipped have been fixed and their
cases now live in the maintained suites. A scripted scenario harness drives real
windows for every app; one of its scenarios is still a stated diagnostic, for the
open half of GUI-10.

[Windows evidence](gui-examples-review/2026-09-10-windows/README.md), captured
2026-09-10 at `c5cc2188bc96ee037b868277b4aedfd43519e89e` with the attested
`x64mingw` host — **before** the fixes below landed. It adds one crash (GUI-29),
two dead workflows (GUI-27, GUI-32), and a set of Windows-specific items from
GUI-25 on. Its findings for items since closed on macOS are collected under
GUI-34, which is the honest state of those: fixed and unverified there rather
than fixed everywhere. Windows notes under other items say "Windows:" explicitly.

A passing suite does not establish that the examples are usable at the supported
window sizes, and a fix executed on one system is not a fix on the others.

P1 = data integrity or core workflow obstruction; P2 = substantive correctness,
usability, or maintainability; P3 = refinement. **All items below are open.**
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
| GUI-25 | P2 | Windows: window chrome, title bar theme, and icon | Windows screenshots + source | GPUI host window creation |
| GUI-26 | P2 | Windows: dark-theme host scrollbars are the only small-window fallback | Windows screenshots | Host scroll fallback; feeds GUI-10/23 |
| GUI-27 | P1 | Windows: `Home` directory is unresolvable, so Board Save and first Notes Save As never open a dialog | Windows reproduction + source; host fix landed 2026-09-11, unverified on Windows | Files boundary + Board/Notes |
| GUI-28 | P2 | Notes: CRLF, BOM, and paste line-ending handling | Windows reproduction + file bytes | Notes + native input |
| GUI-29 | P1 | Activity: closing the window while following a log crashes the process | Windows reproduction + WinDbg stack; exits cleanly on Linux | GPUI host file/timer lifecycle |
| GUI-30 | P3 | Windows: native dialog defaults (filters, start folder, titles) | Windows screenshots | Files boundary + examples |
| GUI-31 | P2 | Windows contributor workflow: local host build, docs, and spec fixtures | Local build failure + source | Scripts/docs/fixtures |
| GUI-32 | P1 | Explorer: Preview text and Open in app are inert for real Windows folders | Windows reproduction; works on Linux | Explorer + host hit-testing/effects |
| GUI-33 | P2 | Windows file-service edge cases: UNC, reparse points, sharing violations | Source; unverified | Windows file worker |
| GUI-34 | P1 | Re-verify on Windows the items closed on macOS | Windows evidence predates the fixes | Windows validation |

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

The driver now runs everywhere the GUI does: `scripts/minici gui-scenarios`
arranges the private display each system needs, reusing the smoke checks' Weston
compositor on Linux, and Linux CI runs it after `gui-smoke` and keeps the JSON
reports on failure. Only the window captures remain macOS-only.

Remaining: the scenarios have not yet been executed on Linux or Windows by
anyone — CI wiring is not the same as a green run. Window
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

Windows: `meta` maps to `Modifiers::platform`, which is the Windows key, and
the shell intercepts most Win-key chords; no example uses `meta: True`, but
the public docs give it no per-OS meaning. The editor has no Ctrl+Left/Right
word motion, Ctrl+Shift+arrow word selection, or Ctrl+Backspace/Delete: after
Ctrl+End, Ctrl+Left, typing `Y` lands at the end of the document
([capture](gui-examples-review/2026-09-10-windows/notes-win-ctrl-left.png)).
Board domain redo is Ctrl+Shift+Z only, while the text editor also accepts
Ctrl+Y, so Ctrl+Y means different things depending on focus.

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
it says 64-pixel virtual rows while the app declares 44. `gio open` is also
named as the mechanism in
[native-gui-protocol.md](../docs/native-gui-protocol.md) and
[reference.md](../www/content/docs/reference.md), while Windows uses
`rundll32 url.dll,FileProtocolHandler`. Three example READMEs tell Windows
users to run `python3`, which is usually the Store stub there.
[native-gui.md](../www/content/docs/native-gui.md) says native CI "confirmed
rendering for every app"; that is the two-second `--smoke` render count, not
a check of any Windows file operation, chrome, or dialog.

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
selection support are already available. Windows: the drag ghost is a chip
showing the row key `task-1` rather than the card
([hover](gui-examples-review/2026-09-10-windows/board-win-drag-hover-complete.png)).

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

## Windows

All captures here are real framed windows at 96 DPI; see the
[Windows evidence README](gui-examples-review/2026-09-10-windows/README.md)
for build identity, conditions, and reproduction scripts. Notes' `HOME`
behavior was observed both with Git Bash's `HOME` present and with it removed;
the latter is what a shortcut or Explorer launch gives a Windows app.

### GUI-25 — Windows window chrome, title bar theme, and icon

[lib.rs](../crates/gpui-host/src/lib.rs) line 948 requests
`WindowDecorations::Client`, and [window_frame.rs](../crates/gpui-host/src/window_frame.rs)
draws the custom frame only when the platform reports client decorations.
GPUI 0.2.2's Windows backend never does, so every app renders inside a
standard light DWM caption with the default executable icon and the generic
`Roc Signals` title, above a dark application
([Counter](gui-examples-review/2026-09-10-windows/counter-1200x820.png)).
The custom frame's close/minimize affordances and dark styling are
Linux/macOS-only in practice. A 360-pixel logical minimum becomes 540 or 720
physical pixels at common laptop scaling, so the small-window findings are
reached at different physical sizes on Windows; scaling itself was not tested.

Acceptance: decide the Windows chrome contract explicitly. Either accept the
server frame and make it coherent (immersive dark caption via
`DWMWA_USE_IMMERSIVE_DARK_MODE`, a real application icon resource, alongside
the window titles that now exist) or request a transparent title bar and extend the custom frame with
Windows hit-testing for drag, snap, and the system menu. Test both system
themes, maximize/restore, snap layouts, and 125 %/150 % scaling. Keep window
policy in the host; no example-level chrome code.

### GUI-26 — Host scrollbars are the only small-window fallback on Windows

At 800×600 every application, and at 376×600 even Counter and Keyed Rows,
shows the host's window-level horizontal scrollbar, drawn as a wide light
thumb across the bottom of the dark window; Board, Explorer, and Activity add
a vertical one
([Board](gui-examples-review/2026-09-10-windows/task-board-800x600.png),
[Explorer](gui-examples-review/2026-09-10-windows/folder-explorer-800x600.png),
[Activity](gui-examples-review/2026-09-10-windows/activity-monitor-800x600.png),
[Notes 376](gui-examples-review/2026-09-10-windows/notes-editor-360x600.png),
[Counter 376](gui-examples-review/2026-09-10-windows/counter-360x600.png)).
The captures predate the layout fixes: the Board detail panel, the Explorer
preview and the Activity and Counter sizing have all since been bounded on
macOS, so what these images show is the state GUI-34 asks someone to re-take.
What survives that is the scrollbar treatment itself, which belongs to GUI-23,
and the remaining width half of GUI-10.

Acceptance: once those layouts are bounded, recapture the same three sizes on
Windows and confirm the fallback scrollbars appear only for genuine overflow.
If the fallback remains, style it consistently with the application theme and
give it a keyboard path.

### GUI-27 — `Home` is unresolvable on Windows

[effects.rs](../crates/gpui-host/src/effects.rs) line 236 resolves
`Directory.Home` from the `HOME` environment variable, which ordinary Windows
processes do not have. Board always passes `Home` for Save and Save As
([main.roc](../examples-gui/task-board/main.roc), `choose_save_path` call), and
Notes uses it for an untitled note's first Save As
([Workflow.roc](../examples-gui/notes-editor/Workflow.roc), line 37). Started
without `HOME`, both show
`Native service unavailable: HOME is missing or is not UTF-8` and never open a
dialog
([Board](gui-examples-review/2026-09-10-windows/board-save-as-nohome-after-click.png),
[Notes](gui-examples-review/2026-09-10-windows/notes-save-as-nohome-after-click.png)).
Board documents therefore cannot be created at all from a normal Windows
launch. With Git Bash's `HOME` the dialog opens in the profile root, not
Documents ([dialog](gui-examples-review/2026-09-10-windows/board-win-save-as-dialog.png)).

Landed 2026-09-11, on Linux: the host resolves `Home` from `HOME` on Linux and
macOS and from `USERPROFILE`, then `HOMEDRIVE` plus `HOMEPATH`, on Windows;
`Unavailable` now means the environment names no directory at all. `Home` is
the profile root on every system, and the protocol reference, module docs and
public reference say so. The resolver is unit-tested with a Windows-shaped
environment, but the Windows build has not been run without `HOME` since.

Remaining: run Board Save As and Notes' first Save As on Windows from a
shortcut or Explorer launch and confirm the dialog opens in the profile root.
The apps still refuse the workflow on a genuine `Unavailable` rather than
falling back to the dialog's own default folder; that fallback needs a way to
ask the platform for a dialog without an initial directory, which the current
save-chooser request does not have. Cover the resolution with a native spec once
fixtures can express a Windows directory (GUI-31).

### GUI-28 — Notes line endings and BOM

Opening a CRLF file, typing a new line, and saving writes mixed endings:
`First idea\r\nSecond idea with CRLF endings\r\n\nThird idea typed on Windows`
([after Ctrl+S](gui-examples-review/2026-09-10-windows/notes-win-after-ctrl-s.png)).
A UTF-8 BOM is kept as an invisible first character: after Ctrl+Home and one
Right, typing `X` yields `XBOM line one`, and the footer counts the BOM
([caret](gui-examples-review/2026-09-10-windows/notes-win-bom-caret-after-one-right.png)).
[input.rs](../crates/gpui-host/src/input.rs) splits lines on `\n` only and
pastes multiline clipboard text verbatim, and its single-line paste turns
each CRLF into two spaces. CRLF rendering showed no stray glyph in these
captures; caret math past `\r` was not measured. Activity's line stream
already handles CRLF correctly and needs no change.

Acceptance: choose a document line-ending policy (preserve the file's
dominant ending on save, or normalize on load and write back one ending) and
strip or preserve a BOM deliberately; state it in the Notes README. Test load,
edit, paste from a CRLF source, save, and round-trip on all three OSes, with
the footer counts and native undo agreeing with the visible text. Keep the
policy in the application or the typed Files boundary, not in the host's
generic input.

### GUI-29 — Activity Monitor crashes on close while following a log

Open any small UTF-8 log, wait until at least the seventh 500 ms poll, then
close the window: the process dies with access violation `0xC0000005`.
Six of six runs with a dwell of 3.5 s or more crashed; three with 2.5 s or
less, one after Pause following, and one with simulated replay running for
6 s exited cleanly. The WinDbg stack
([log](gui-examples-review/2026-09-10-windows/activity-close-crash-windbg.txt))
is on the main thread inside the window procedure dispatched from
`DispatchMessageWorker`, reading a byte at offset `0xF8` of freed heap memory;
the attested host carries no symbols, so frames are module offsets. The
symptom points at teardown ordering between the polling task/timer and the
runtime it reports into, not at the Roc application.

Linux, 2026-09-11: `activity-monitor/follow-and-close` opens the real
`regression/fixtures/events.log` through the worker, follows it for four
seconds (eight polls), and closes the window through the host's own close
request; the process exits cleanly under Wayland with the debug host. The
scenario is an ordinary check, and the driver now fails a scenario whose
process dies after writing its report, so the Windows crash would be caught
by `scripts/minici gui-scenarios` there rather than only by hand. That run has
not happened yet.

Acceptance: reproduce under a symbolized debug host on Windows (the same
runtime code exits cleanly on Linux), then fix the ownership so that pending
file-follow work cannot touch a dropped runtime. Add a host test that closes
the window with an active follow task; the scripted scenario is the
normal-close-path check on all three CI targets.

### GUI-30 — Native dialog defaults on Windows

Open dialogs have no file-type filter at all, Save As offers only
`All files`, Save As opens in the profile root while Open opens in Documents,
and dialog titles are the generic `Open`/`Save As`/`Select Folder`
([Open](gui-examples-review/2026-09-10-windows/notes-win-open-dialog.png),
[Save As](gui-examples-review/2026-09-10-windows/notes-win-save-as-untitled.png),
[Select Folder](gui-examples-review/2026-09-10-windows/explorer-win-choose-folder-dialog.png)).
Board's suggested name `My project.board.json` appears as `My project.board`
because Explorer hides the known extension; that is expected, but nothing
verifies the saved name still ends in `.json`.

Acceptance: add optional typed filters and titles to the choose requests only
if the examples need them; otherwise document the defaults. Verify the
extension handling and the start folder on Windows and macOS once GUI-27
settles what `Home` means.

### GUI-31 — Windows contributor workflow and spec fixtures

`python scripts/build_gui.py --debug` on Windows fails before compiling
because [windows_gnu_build.py](../scripts/windows_gnu_build.py) shells out to
`pwsh`, requires the 10.0.26100 SDK's FXC, and pins rustup 1.95.0 with the
`gnullvm` target; none of that is checked or explained up front, and the
contributing page only lists the toolchain. The CI path
(`GUI_HOST_LOCK=gui-host.lock.json python scripts/test.py gui`) works locally
but needs authenticated `gh` and an absent `platform-gui/targets/x64mingw`.
`gui_smoke.py` is Linux-flavored (`wayland`) and the smoke assertion is a
render count. The typed fixture guard has since been taught drive,
UNC and POSIX spellings, so a spec can now express a Windows path; the specs
that inject `/tmp` have not all been revisited, and the Windows CI job still
does not exercise this section. The Rust request-codec tests also hard-code `/tmp`
where `ABSOLUTE_DIRECTORY` exists for that purpose.

Acceptance: fail fast with a clear message listing missing Windows build
prerequisites, or accept Windows PowerShell 5.1 where `pwsh` is only used for
`Get-AuthenticodeSignature`; document the host-lock path as the supported
local verification route. Teach `validPath` platform-shaped absolute paths
(drive, UNC, POSIX) behind an explicit fixture platform tag, port the Linux
diagnostics to real Windows shapes, and extend the smoke to exercise one real
file operation per OS. This is the tooling half of GUI-16.

### GUI-32 — Explorer preview and open are inert for real Windows folders

After choosing a real folder and selecting a file, Preview text and Open in
app are enabled but clicking either changes nothing: the notice line stays
`3 entries loaded.`, the status stays `No preview loaded.`, no error appears,
the button never takes focus, and no external application starts. This holds
for a 47-character path with no layout overflow
([selected](gui-examples-review/2026-09-10-windows/explorer-win-short-path-selected.png),
[after click](gui-examples-review/2026-09-10-windows/explorer-win-short-path-preview.png))
and for a deep path
([after click](gui-examples-review/2026-09-10-windows/explorer-win-tall-readme-preview.png)).
In the sample workspace the same click previews immediately and focuses the
button ([sample](gui-examples-review/2026-09-10-windows/explorer-win-sample-readme-preview.png)).
`Session.preview_selected` would set the notice to `Reading a preview of …`
before any worker result, so the transition is not running; whether the click
never reaches the button or the action is dropped before the update is
undetermined. Tab from the list moves focus to the toolbar's Up, not to the
details buttons.

Linux, 2026-09-11: not reproduced. `folder-explorer/real-folder-preview`
chooses the real `regression/fixtures/project` folder through the worker,
selects `note.txt`, and Preview text loads it; the CRLF fixture `crlf.txt`
previews with its `\r\n` endings intact in the read-only editor. The maintained
`preview-open.scm` spec already selects a `Folder` source entry and invokes the
preview action, and it passes on Windows too, so whatever is wrong there is in
the presentation layer or the Windows worker, not in the session model.

Acceptance: run the scenario on Windows with `--host-trace-engine` to see
whether the click reaches the engine at all. Fix the dispatch or worker gap,
then verify that Open in app reports the `rundll32` launch honestly (an
unassociated extension still returns success).

### GUI-33 — Windows file-service edge cases

Source-traced in [windows.rs](../crates/gpui-host/src/file_io/windows.rs),
not exercised here: `path_parts` refuses UNC prefixes while `validate_path`
in [effects.rs](../crates/gpui-host/src/effects.rs) accepts them, so a
network-share pick fails only at read time; any reparse point is reported as
`SymbolicLink`, which would classify OneDrive placeholders and junctions as
links and refuse previews (this machine's OneDrive holds only `desktop.ini`,
so it was not observed); sharing violations map to `PermissionDenied`, which
matters for tailing a log a Win32 writer holds without `FILE_SHARE_READ`;
listed entry paths inherit the separator spelling of the requested root; and
an executable on a UNC share yields an unusable default assets root.

Acceptance: decide UNC support explicitly and make both validators agree;
distinguish symbolic links from other reparse points (cloud placeholders,
junctions, mount points) with the reparse tag; give sharing violations their
own error text and a Retry hint in Activity; normalize separators at the
boundary. Cover each with a fixture that a Windows CI job actually runs.

### GUI-34 — Re-verify the closed items on Windows

The Windows pass recorded real failures in items that have since been fixed and
closed, but every one of those fixes was written and executed on macOS. The
evidence below therefore describes behaviour that *was* broken on Windows and is
believed fixed, not behaviour anyone has re-run there. Until it is re-run, the
closure is a macOS closure.

- **Paths (was GUI-05).** Notes showed the whole `C:\…\Ideas.txt` as the
  document title and Save As failed before any dialog with `Invalid path: /`
  because the parent was `/`; Explorer rendered breadcrumbs as `/` plus the
  entire path, labelled every row with its full path, kept Up enabled
  everywhere, and produced `Invalid path:` at `C:\`; Board showed the saved
  document's full path as the board name, pushing the detail panel off-screen.
  A typed `Files.Path` boundary now handles drive roots, UNC paths and
  backslashes, and Explorer walks components from the path's own root.
  [Notes title](gui-examples-review/2026-09-10-windows/notes-win-opened-windows-path.png),
  [Save As](gui-examples-review/2026-09-10-windows/notes-win-after-save-as-click.png),
  [Explorer](gui-examples-review/2026-09-10-windows/explorer-win-project-folder.png),
  [Up at the drive root](gui-examples-review/2026-09-10-windows/explorer-win-drive-root-up.png),
  [Board](gui-examples-review/2026-09-10-windows/board-win-after-save-as.png).
- **Dialogs (was GUI-04).** The Notes discard dialog and the Board close dialog
  clipped on both sides at the 376-pixel outer width, losing the heading's first
  word and the safe action's label. Dialogs are now bounded to the padded
  viewport in the host, verified at the 360×240 minimum on macOS.
  [Notes](gui-examples-review/2026-09-10-windows/notes-win-discard-dialog-360.png),
  [Board](gui-examples-review/2026-09-10-windows/board-win-close-dialog-360.png).
- **Window identity (was GUI-15).** Every Windows capture showed the generic
  `Roc Signals` title. Titles now name the application and its document; the
  executable icon is separate and stays open as GUI-25.

Acceptance: run the maintained specs and the scripted scenarios on Windows and
re-take these captures. Anything that survives comes back onto this queue as its
own item with the Windows evidence attached; anything that does not is closed for
both systems rather than for one. `scripts/minici gui-scenarios` runs the
scenarios there; window captures are still macOS-only, so the Windows captures
remain manual for now.

## Delivery sequence

1. Fix the Windows P1s: GUI-29 (crash on close while following a log),
   GUI-27 (`Home` unresolvable), and GUI-32 (inert preview and open).
2. Re-verify the closed items on Windows (GUI-34) and add GUI-16 regressions
   alongside each fix, not only at the end.
3. Apply current-API layout/readability fixes (GUI-10/11, GUI-13, GUI-18); use evidence
   from them to scope GUI-19/20/23.
4. Finish structure/docs and optional polish (GUI-21/22/24), then recapture the
   same states. Remove resolved work from this queue; do not treat a fresh
   screenshot alone as proof of lifecycle, performance, or cross-OS correctness.

This file tracks open work, not completed milestones or historical rationale.
Keep supporting evidence while it is useful to an open item; fold regression
cases into the maintained suite as fixes land. Git history retains prior plans.
