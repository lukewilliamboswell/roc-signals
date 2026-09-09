# Design review of the native GUI examples

## Goal

Assess the four main native example applications — Launch Board
([examples-gui/task-board](../examples-gui/task-board)), Notes
([examples-gui/notes-editor](../examples-gui/notes-editor)), Activity Monitor
([examples-gui/activity-monitor](../examples-gui/activity-monitor)), and Folder
Explorer ([examples-gui/folder-explorer](../examples-gui/folder-explorer)) —
against a "polished desktop application" bar rather than a "working demo" bar,
and separate what the applications can fix today from what the styling surface
cannot yet express.

This is a review, not a new contract. The styling surface under review is the
`Presentation` record and attribute set in
[platform-gui/Gui.roc](../platform-gui/Gui.roc) (lines 12–26 and 28–39): gap,
uniform padding, width/height/grow, background, foreground, border color and
width, radius, font size, and overflow, plus placeholder, selected, enabled,
label, shortcut, and drag/drop attributes. The known theming gaps —
unstyleable `Gui.button`, hover/active state colors, editor chrome, selected
ring, and window-level chrome — are inventoried in
[theming.md](theming.md) and are not re-litigated here; where a finding lands
on one of those items this review says so and moves on. Image support,
embedded fonts, and compile-time themes are being built in parallel this
sprint and are referenced as in-flight, not proposed again.

Evidence: every rendering claim cites either a source line or one of four
screenshots taken from debug builds at this commit — `review-task-board.png`,
`review-notes-editor.png`, `review-activity-monitor.png`,
`review-folder-explorer.png` (scratchpad, 2026-09-09). States that cannot be
reached without pointer automation (dialogs, drags, error rows) are critiqued
from the code.

## What already works

The refresh established real conventions worth keeping:

- **One accent for the primary action.** `Rgb(0x2E6FA3)` marks exactly the
  workflow-starting button in each app: Save
  ([task-board/main.roc:698](../examples-gui/task-board/main.roc),
  [notes-editor/main.roc:74](../examples-gui/notes-editor/main.roc)), Open
  log ([activity-monitor/main.roc:99](../examples-gui/activity-monitor/main.roc)),
  Choose folder
  ([folder-explorer/main.roc:265](../examples-gui/folder-explorer/main.roc)),
  Preview text (line 110), Add task
  ([task-board/main.roc:402](../examples-gui/task-board/main.roc)).
- **A shared status vocabulary.** Amber `0xE8C27A` for unsaved/attention,
  green `0x8FD4A8` for saved/low, red `0xF09A93` for problems/high priority,
  and muted blue-greys for secondary text appear in all four apps.
- **Honest status visibility.** Every asynchronous phase has a visible textual
  state (task-board document status, lines 715–755; activity notice, line
  125; explorer notice, line 312), problems appear in red near their cause,
  and destructive or lossy actions confirm through dialogs.
- **Keyboard reality.** All four apps bind real shortcuts
  (task-board line 472, notes lines 57–61, explorer lines 245–250), and
  Folder Explorer even documents them (line 352).
- **Honest empty states.** "No matching tasks", "No matching events. Start
  the replay, open a log, or adjust the filter.", "Select a file to inspect
  it." — directive, plainly worded, in the interface's voice.

The failures below are therefore mostly *composition* failures — rhythm,
alignment, affordance, and typographic hierarchy — not color failures.

## Launch Board (task-board)

Screenshot: `review-task-board.png`.

**Works.** The three-column board plus detail panel is the right macro layout;
selected-card ring is clear; priority coloring gives cards a scannable second
line; the toolbar reads left-to-right as verbs → document identity → status.

**Fails the bar.**

- **A dead band above the board.** Roughly 60px of blank space sits between
  the toolbar and the new-task row. It is phantom structure: the always-present
  problem column ([main.roc:757–760](../examples-gui/task-board/main.roc))
  renders an empty string, and both `Ui.when` fallbacks (lines 761–775)
  render `Gui.text("")` — each an element that still occupies a gap slot in a
  `gap: 14` column (line 472). Empty text is not free; it is vertical rhythm
  noise. The same pattern recurs in every app.
- **Cards are not clickable; only their "Edit" button is.** Every card
  carries a full-size Edit button (lines 193–206) because a panel cannot
  receive activation. Twelve identical buttons dominate the board and the
  card surface itself — the natural target — is inert. This is the single
  largest affordance failure on the screen. (Container activation is an API
  gap; see the table.)
- **Priority color bleeds into the assignee.** The whole meta line
  "High priority · Maya" takes the priority color (lines 175–191), so the
  person's name renders red or green. Semantically the color belongs to one
  word. Fixable today by splitting the line into two text elements in a row.
- **Manual text on the canvas.** Two permanent instruction lines about drag
  behavior and undo bounds (lines 488–494) sit between the controls and the
  board. Polished applications teach through affordance and tooltips, not
  standing paragraphs; at minimum this belongs in a single quiet footer line
  like Folder Explorer's (folder-explorer line 352), which also would give
  the Ctrl+S/O/Z bindings (line 472) their only discoverability.
- **Off-grid padding as fake alignment.** The path column uses `padding: 6`
  (line 703) and the status column `padding: 7` (line 732) to visually
  baseline-align text against 8px-padded buttons. The screenshot shows the
  baselines still drifting. This is a symptom of missing row cross-axis
  alignment (API gap) papered over with off-scale values.
- **Flat heading scale.** `Gui.heading` is one fixed treatment, so "Launch
  Board" (line 475), "Planned" (line 219), and "Task details" (line 350)
  differ only by whatever the host renders — the page title does not clearly
  outrank the column titles in the screenshot. Weight is unavailable; today
  the only lever is wrapping headings in styled columns with `font_size`,
  which the app does not use for headings at all.
- **Two accents on one screen.** Save and Add task are both `0x2E6FA3`
  (lines 698, 402). Add task is the more frequent action; Save is the more
  consequential one. Pick one; make the other a quiet default.
- **The delete confirmation cannot look dangerous.** "Confirm delete"
  (line 327) is a plain `Gui.button`, which accepts no style
  ([theming.md](theming.md) already tracks the missing attribute list), so
  the most destructive action on the board renders identically to "Cancel
  deletion". Until the button gains attributes, the dialog copy carries all
  the weight.

**Prescriptions (today).** Collapse the conditional/problem rows into one
trailing `gap: 0` column so emptiness costs no rhythm; split priority/assignee
coloring; demote Add task to the default button treatment; replace the two
instruction paragraphs with one footer shortcut line; drop `padding: 6/7` in
favor of the shared scale and accept the misalignment until row alignment
exists; restyle Edit as a quiet ghost (background matching the card,
border-only) so cards stop reading as button trays.

## Notes (notes-editor)

Screenshot: `review-notes-editor.png`.

**Works.** This is the closest to polished: one column, one job, quiet copy
("A quiet place to collect your thoughts."), a correct toolbar, dirty-state
color on the status, live counts.

**Fails the bar.**

- **Unbounded measure.** The textarea is `width: Fill` (line 118), so at the
  default window size the writing line runs ~200 characters. For a writing
  app the measure is the design. Today: cap the editor (e.g. `Px(760)`) and
  center it with `grow` spacer columns on either side — flex-justify does not
  exist, but grow-spacers do.
- **Misaligned identity row.** "Untitled note" (font 18, line 83) and "No
  changes" (font 13, padding 4, line 98) sit in one `gap: 12` row with no
  baseline alignment; the screenshot shows the status floating high. Same
  root cause as the task-board toolbar (API gap: row alignment).
- **Save invites while status says "No changes".** Save is enabled whenever
  the session is idle (line 74) — the button and the status contradict each
  other. Gate Save on the same dirtiness `revert_ready` already computes
  (line 21).
- **Phantom rows at the bottom.** The problem column (lines 132–144) and two
  `Ui.when` fallbacks (lines 152, 191, 211) render empty strings under the
  counts, in a `gap: 16` column — visible as dead space below "0 words · 0
  characters" in the screenshot.
- **Redundant caption.** The textarea's host caption "Note text" (line 114)
  labels the only editor on a screen titled Notes — it adds a hierarchy level
  that says nothing. The label is semantically required; the *visible* caption
  styling is host chrome ([theming.md](theming.md), textarea caption row).
- **Invisible shortcuts, inconsistent dialogs.** Ctrl+N/O/S bindings
  (lines 57–61) are advertised nowhere. The discard dialog overrides the
  default dialog surface with a warm `Rgb(0x332E29)` (line 166) while the
  close dialog (line 195) keeps the standard `0x212D37` — two dialog styles
  inside one small app for the same class of decision.
- **Off-palette root.** The root background is `Rgb(0x14191E)` (line 56),
  while the other three apps sit on the host default `0x16252C`
  (crates/gpui-host/src/lib.rs:663). One app is noticeably blacker for no
  stated reason.

**Prescriptions (today).** Constrain and center the editor measure; gate Save
on dirtiness; group the trailing conditionals in a `gap: 0` column; unify both
dialogs on the default surface; add a one-line shortcut footer; move counts
into the identity row (title left, spacer, counts and status right via a grow
spacer) so the bottom of the window ends at the editor.

## Activity Monitor

Screenshot: `review-activity-monitor.png`.

**Works.** The provenance banner (SIMULATED REPLAY vs. PLAIN-TEXT LOG,
lines 65–93) is honest and well-placed; retention/eviction counters are
visible; follow-tail is a first-class control; the empty state names all
three ways forward.

**Fails the bar.**

- **Control sprawl.** Four separate ragged-left control rows stack before the
  content: source buttons (lines 94–124), replay transport (126–174),
  clear/counters (175–188), filter/toggles (189–196) — plus the notice line
  and the "Replay paused" orphan (197–214). Six bands of chrome for what is
  one toolbar and one filter bar. Today: merge to two rows — [source +
  transport + cancel] and [filter + toggles + counters] — and let the
  counters sit at the row's right edge behind a grow spacer.
- **Severity is not color-coded where it matters.** The list row renders the
  severity column in the same muted `0xA9BFCC` as the component column
  (entry_view, lines 19, 23) — an Error line looks exactly like an Info line
  in the feed. The status color vocabulary exists (red/amber/green) and
  `style_s` off the row signal is exactly the mechanism the task-board cards
  already use (task-board lines 177–190). This is the highest-leverage single
  change in the app.
- **Per-row "Inspect e17" buttons.** Selection is offered as a labeled button
  in every virtual row (line 17), consuming the row's left edge with
  repetitive text. Same container-activation gap as task-board cards; today
  the button label could at least become a uniform quiet "Inspect".
- **No column headers.** Severity / component / message columns (fixed widths
  70/110/grow, lines 19–26) have no header row, so the table must be
  deciphered. A muted 13px header row with the same fixed widths costs
  nothing today.
- **Cyan means two things.** `0x7FC9E8` is the "live log source" color
  (line 77) and also the "Retained: 0 / 1000" counter color (line 180) —
  a status hue doing decorative duty one row away from where it has meaning.
- **The inspector wastes its panel.** The event detail is one concatenated
  string "Event 3 · Info · engine · …" (line 256) inside a 340px panel that
  is 90% empty (screenshot). Today: break it into labeled rows (Id / severity
  / component / message) with the muted-caption-over-value pattern the
  task-board detail panel already uses, and color the severity value.
- **All-caps banner.** "SIMULATED REPLAY · …" (line 87) is the loudest text
  on screen after the title. The distinction deserves the panel and the
  color; it does not need capitals doing a font-weight impression — a
  weight-bearing `font_size` bump on a mixed-case "Simulated replay" reads
  better until weight exists.

**Prescriptions (today).** Severity colors in rows; two-row toolbar
consolidation; header row for the feed; inspector detail layout; retire the
cyan counter to the muted grey; sentence-case the banner.

## Folder Explorer

Screenshot: `review-folder-explorer.png`.

**Works.** Deepest keyboard support of the four, and the only app that
documents it (line 352); the sample-workspace on-ramp is a good first-run
answer; sort toggles use the selected ring correctly (line 322); disabled
navigation (Back/Forward/Up) communicates history state.

**Fails the bar.**

- **The file list is a wall of buttons.** Each entry name is a full-width
  `action_button` (lines 39–43), so six rows render as six large pills
  (screenshot) — the heaviest possible treatment for the lightest, most
  repeated element on screen. Same container-activation root cause; today the
  effect can be halved by giving the entry button a background matching the
  list panel (`0x1B2A33`) so rest state is flat text and only hover/selection
  lifts it — accepting that an explicit background currently sacrifices hover
  feedback ([theming.md](theming.md), hover interaction note).
- **Eight buttons, one row, four of them dead.** Back / Forward / Up /
  Refresh / Choose folder / Use sample / Cancel / Retry all sit in one
  toolbar (lines 258–269) with half disabled at first run. Cancel and Retry
  are rare-phase controls; today they can appear only in their phases via
  `Ui.when` (as task-board's "Cancel operation" already does, task-board
  line 775), shrinking the resting toolbar to six.
- **Breadcrumbs don't read as a path.** The trail renders as detached
  buttons with no separators (lines 271–291); at the sample root it is a
  single orphan "Sample" pill floating below the toolbar (screenshot).
  Today: interleave muted "/" text elements and drop the button padding; a
  true breadcrumb still wants container activation and hover cursors.
- **No column headers, sizes unaligned.** Kind and size columns (fixed 90px,
  lines 45–50) have no header and are left-aligned, so byte counts ("1536 B",
  "0 B") don't rank visually. Header row is possible today; right-aligned
  numerals are not (text alignment gap).
- **Three redundant preview statements.** The details panel simultaneously
  shows the 64 KiB hint (line 121), "No preview loaded." (line 134), and a
  placeholder "Preview a file to read it here." (line 155) — three phrasings
  of the same emptiness stacked in one panel (screenshot). Keep the
  placeholder; make hint and status conditional on an actual preview.
- **Five control bands before content.** Toolbar, breadcrumb row, filter
  row, sort row, and two summary lines (lines 258–329) push the actual file
  list below the window's midpoint at default size. Merging filter + sort +
  summaries into one band is possible today with grow spacers.

**Prescriptions (today).** Flatten entry rows; phase-gate Cancel/Retry; add
"/" separators and quiet breadcrumb styling; add a header row; deduplicate
preview messaging; consolidate the control bands.

## Cross-app observations

**Conventions to ratify (they are already ~80% true):**

- One `0x2E6FA3` accent per screen, on the single primary action.
- Status hues: amber = unsaved/attention, green = safe/saved, red =
  problem/destructive, `0xA9BFCC` = secondary text, `0x93A9B6` = tertiary
  hints. The two muted greys are currently interchanged freely (e.g.
  task-board uses `0x93A9B6` for column counts at line 221 but `0xA9BFCC`
  for the same role in the detail panel at line 360); pick one meaning each.
- Surfaces: host root `0x16252C` → list/board panels `0x1B2A33` → raised
  cards/detail panels `0x283A47`. Three levels are enough; Notes' `0x14191E`
  root (notes line 56) and its `0x332E29` dialog (line 166) are the two
  violations.
- Panels of equal rank get equal padding: the detail panels use 16
  (task-board line 348, activity line 233, explorer line 75), but root
  padding is 20 / 24 / 24 / 16 across the four apps and gaps are 14 / 16 /
  12 / 10 — no shared rhythm. Adopt a 4/8 scale (4, 8, 12, 16, 24) and ban
  6 and 7 (currently at task-board lines 703, 732 and activity line 180).

**Systemic anti-patterns:**

1. **Phantom empty elements.** Every app pays gap-rhythm for `Gui.text("")`
   fallbacks and always-rendered empty problem rows. House rule: conditional
   regions live in a trailing `gap: 0` wrapper, or the visible branch carries
   its own spacing.
2. **Buttons are the only affordance.** Because activation exists only on
   buttons, every clickable concept — cards, list rows, breadcrumbs, sort
   modes, priorities — becomes the same pill. The screen loses its figure/
   ground: chrome and content have equal visual weight in three of four apps.
3. **Every window is titled "Roc Signals".** The native host hardcodes the
   title (crates/gpui-host/src/lib.rs:764); `SetDocumentTitle` exists in the
   shared node protocol ([platform-gui/Node.roc:112](../platform-gui/Node.roc))
   but is not surfaced or applied natively. Four different applications are
   indistinguishable in the window switcher, and document names ("Untitled
   board — edited") have no home.
4. **Shortcut discoverability is one-for-four.** Only Folder Explorer prints
   its bindings. Until tooltips exist, the footer line is the pattern; adopt
   it everywhere.
5. **First-run is good in three apps, absent in one.** Task-board and
   explorer seed sample content; activity offers a replay; Notes opens
   correctly empty. No action needed — noted as a strength to preserve.

## Prioritized gap table

### (a) Achievable today, in priority order

| # | Change | Where | Evidence |
| --- | --- | --- | --- |
| 1 | Severity color-coding in the event feed via `style_s` on the row | activity-monitor/main.roc:19 | review-activity-monitor.png; pattern exists at task-board/main.roc:177 |
| 2 | Kill phantom empty rows: trailing `gap: 0` wrappers for problem lines and `Ui.when` fallbacks | task-board/main.roc:757–775; notes-editor/main.roc:132–154; both other apps | dead bands in review-task-board.png, review-notes-editor.png |
| 3 | Flatten list rows: panel-colored entry buttons, uniform quiet labels; phase-gate Cancel/Retry | folder-explorer/main.roc:39–43, 267–268; activity-monitor/main.roc:17 | review-folder-explorer.png |
| 4 | Constrain and center the Notes measure with grow spacers (`Px(760)`), gate Save on dirtiness | notes-editor/main.roc:118, 74 | review-notes-editor.png |
| 5 | One accent per screen (demote Add task), split priority color from assignee text | task-board/main.roc:402, 191 | review-task-board.png |
| 6 | Header rows for both tables (fixed widths already exist) | activity-monitor/main.roc:19–26; folder-explorer/main.roc:45–50 | both screenshots |
| 7 | Toolbar consolidation with grow spacers; counters/status pushed to row ends | activity-monitor/main.roc:94–196; task-board/main.roc:694–755 | review-activity-monitor.png |
| 8 | Shared spacing scale (4/8/12/16/24); remove padding 6/7 | task-board/main.roc:703, 732; activity-monitor/main.roc:180 | — |
| 9 | Dialog and surface unification in Notes (default dialog bg, host root bg) | notes-editor/main.roc:166, 56 | — |
| 10 | Shortcut footer line in task-board and notes; replace task-board's standing instruction copy | task-board/main.roc:488–494; notes-editor | folder-explorer/main.roc:352 as model |
| 11 | Inspector detail layout (labeled rows) and breadcrumb "/" separators | activity-monitor/main.roc:256; folder-explorer/main.roc:271–291 | both screenshots |

### (b) Blocked on missing API

Excluded as already tracked or in-flight: styleable `Gui.button`,
hover/active/selected/disabled state colors, editor inner chrome, window-level
chrome ([theming.md](theming.md) packages 2–5); images/icons, embedded fonts,
compile-time themes (in-flight this sprint).

| # | Missing capability | Minimal addition | Suffers most | Why |
| --- | --- | --- | --- | --- |
| 1 | Font weight | `weight : U32` (400/600/700) in the version-2 style record theming.md already plans | task-board | The board is three nested heading levels plus card titles distinguished only by size and color; all-caps and size are currently faking weight (activity banner, main.roc:87) |
| 2 | Container activation | An activation message on row/column/panel (click + Enter/Space when focusable), or `action_button` accepting child elements | task-board, folder-explorer | Cards need per-card Edit buttons (task-board:193); file entries and breadcrumbs are full-width pills (folder-explorer:39); rows carry "Inspect" buttons (activity:17) |
| 3 | Row/column alignment and justification | `align : [Start, Center, End, Baseline]`, `justify : [Start, Center, End, SpaceBetween]` on the container style | all four | Baseline drift wherever text meets buttons (task-board padding 6/7 hack:703, 732; notes identity row:83–98); grow-spacer centering is a workaround with no vertical-text answer |
| 4 | Text alignment within an element | `text_align : [Start, Center, End]` | folder-explorer, activity-monitor | Numeric size columns cannot right-align (folder-explorer:49); empty states cannot center in their panels |
| 5 | Per-app window/document title | Surface `SetDocumentTitle` (Node.roc:112) in the native host in place of the constant at gpui-host/src/lib.rs:764 | all four | Every window is "Roc Signals"; dirty-state titling ("edited") is a desktop convention the apps cannot follow |
| 6 | Per-side padding | Padding as one or four values in style v2 | task-board, notes | Uniform padding forces symmetric insets; badge/pill and caption spacing all approximate with off-scale uniform values |
| 7 | Text truncation and line height | `text_overflow : [Clip, Ellipsis]`, `line_height : U32` | activity-monitor, notes | Long log messages hard-clip mid-glyph under `overflow_x: Clip` (activity:26); the editor's line height is a host constant (theming.md editor row) and body text cannot be given prose leading |
| 8 | Hover cursor | `cursor : [Default, Pointer, Text]` style field or attribute | folder-explorer | Nothing on any screen changes the pointer; flattened list rows (item a3) will read as text without it |
| 9 | Tooltips | `Gui.tooltip : Str -> Attr` rendering a delayed native overlay | task-board | Shortcut discoverability currently costs a permanent footer line; icon-only buttons (post images-in-flight) will require it |
| 10 | Divider element / per-side borders | Per-side `border_width`, or a host hairline honoring `border_color` | task-board, activity-monitor | Priority stripes on cards and section separations currently need full boxes; a 1px background column works today but couples to panel color |
| 11 | Elevation and motion | `shadow : [None, Low, Medium]`; transitions deferred | all (dialogs) | Dialogs separate from the page only by scrim and border (review screenshots of dialog code paths); flat stacking limits the surface hierarchy to background steps |

Ordering rationale: 1–3 unlock hierarchy and affordance — the two failures
every app shares; 4–6 fix alignment and identity; 7–11 are refinements whose
absence is visible but tolerable.

## Suggested sequence

1. Land the (a) table as one visual-consistency pass across the four apps —
   no platform work, mechanical diffs, screenshot-verified.
2. Fold gaps b1 (weight), b3 (alignment), b4 (text align), b6 (padding
   sides), and b7 (truncation/line height) into the version-2 style record
   [theming.md](theming.md) already plans, so the boundary changes once.
3. Treat b2 (container activation) and b5 (window title) as their own small
   design notes; both touch event routing rather than styling.
4. Re-screenshot the four apps after each package; the review's screenshots
   are the baseline.
