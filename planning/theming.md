# App-controlled theming for the native GUI

## Goal

Let a native application switch its complete visual style at runtime — for
example between a light and a dark palette — using ordinary application state
and the existing styling surface. A theme is app data: a record of colors held
in a signal, from which every element derives its `Gui.Style` through the
`changes` props field. No host theme protocol, no new theme record at the boundary, and
no host-owned palette registry. The host stays a renderer of explicit,
per-element presentation, as [design.md](../design.md) already frames it.

This is a plan, not a new public contract. The valuable part is the inventory
of what the pattern cannot reach today: control chrome that
[crates/gpui-host](../crates/gpui-host) hardcodes and that ignores application
styles. Closing those gaps means extending the app-facing styling surface, not
adding a parallel theming channel.

## The pattern that works today

The `changes ?: Signal(Style)` field on every control's props record
([platform-gui/Gui.roc](../platform-gui/Gui.roc)) already delivers
reactive presentation through ordinary typed, equality-pruned signal
propagation ([docs/native-gui-protocol.md](../docs/native-gui-protocol.md)).
An application defines a palette record, holds the current palette in state,
and maps per-element styles off that signal. Switching themes republishes only
the styles whose encoded records actually change; elements whose derived style
is identical under both palettes are pruned like any other unchanged signal.

The following compiles against the current platform (`roc check`, verified):

```roc
Theme : {
	surface : Gui.Color,
	panel : Gui.Color,
	content : Gui.Color,
	muted : Gui.Color,
	accent : Gui.Color,
	border : Gui.Color,
}

dark : Theme
dark = { surface: Rgb(0x16252C), panel: Rgb(0x1B2D36), content: Rgb(0xE6EBEE), muted: Rgb(0x9DB4C0), accent: Rgb(0x2B6A92), border: Rgb(0x33505E) }

light : Theme
light = { surface: Rgb(0xF4F6F7), panel: Rgb(0xFFFFFF), content: Rgb(0x1B2D36), muted: Rgb(0x51646F), accent: Rgb(0x2B6A92), border: Rgb(0xC3CED4) }

panel_style : Signal(Theme) -> Signal(Gui.Style)
panel_style = |theme| theme.map(|t| Gui.Style.{ padding: 24, gap: 16, border_width: 1, radius: 10, bg: t.panel, border_color: t.border, fg: t.content })

main : () -> Elem
main = || Ui.state(
	Dark,
	|mode| {
		theme = mode.signal().map(
			|current| match current {
				Dark => dark
				Light => light
			},
		)
		Gui.col(
			{ changes: theme.map(|t| Gui.Style.{ padding: 32, gap: 20, bg: t.surface, fg: t.content }) },
			[Gui.panel({ changes: panel_style(theme) }, [Gui.text("Themed content")])],
		)
	},
)
```

Because a theme is a plain record in a signal, per-subtree themes, animated
transitions, and user-selected palettes all reduce to ordinary signal
composition. Nothing in this pattern requires platform work. The current
Roc-side control defaults — the panel border `Rgb(4743275)` (0x48606B) at
[platform-gui/Gui.roc](../platform-gui/Gui.roc) line 250, the dialog palette at
line 301, and the action-button background `Rgb(3232873)` (0x315469) at line
353 — are only defaults: a supplied style replaces the complete record, so they
do not block the pattern.

## Existing foundation and gaps

What blocks a fully themed application is everything the app-facing `Style`
record cannot express and every control that accepts no attributes. Today the
de-facto theme lives as constants in the Rust host.

Controls with no styling route at all:

| Control | Gap |
| --- | --- |
| `Gui.button` | **Resolved:** `Gui.action_button` takes the full props record with the button's default style; `Gui.button` stays as the caption-and-message shorthand. |
| `Gui.heading`, `Gui.text`, `Gui.text_s` | No attributes. Foreground and font size inherit from a styled wrapper, so a wrapping `Gui.col` is a workaround, not a gap of the same severity. |

Host chrome that ignores application styles entirely:

| Chrome | Location | Constant |
| --- | --- | --- |
| Button default background, padding, radius | crates/gpui-host/src/lib.rs:140 | `rgb(0x315469)`, `px_3 py_1 rounded_md` |
| Button hover / active backgrounds | **Resolved:** style-v2 `hover_bg`/`active_bg` | host constants remain the default-background fallback |
| Checkbox glyphs | crates/gpui-host/src/lib.rs:171 | `"☑"` / `"☐"` literals |
| Selected ring | crates/gpui-host/src/lib.rs:197 | `border_2`, `rgb(0x70c5e8)` |
| Disabled treatment | crates/gpui-host/src/lib.rs:200 | `opacity(0.45)` |
| Textarea caption color | crates/gpui-host/src/lib.rs:218 | `rgb(0x9db4c0)` |
| Editor field background / text / border | **Resolved:** flows from the element style record | host constants remain the sentinel defaults |
| Root window background / text | crates/gpui-host/src/lib.rs:663–664 | `rgb(0x16252c)` / `rgb(0xeeeeea)` |
| Dialog scrim | crates/gpui-host/src/lib.rs:702 | `rgba(0x00000088)` |
| Editor placeholder text | **Resolved:** derives from the effective foreground at reduced alpha | - |
| Editor cursor | **Resolved:** explicit style foreground tints it | `rgb(0x70c5e8)` remains the default |
| Editor selection highlight | **Resolved:** cursor color at low alpha | `rgba(0x70c5e845)` remains the default |
| Editor text color, line height, size | **Resolved:** style foreground/font_size; line height proportional | old constants remain the sentinel defaults |
| Titlebar background / text | crates/gpui-host/src/window_frame.rs:32–33 | `rgb(0x243842)` / `rgb(0xeeeeea)` |
| Window frame border | crates/gpui-host/src/window_frame.rs:74 | `rgb(0x526874)` |
| Frame button hover | crates/gpui-host/src/window_frame.rs:178 | `rgb(0x45616f)` |
| Scrollbar track / thumb | crates/gpui-host/src/scrollbars.rs:194–195 | `rgb(0x273942)` / `rgb(0x91aab6)` |
| Drag ghost background / text | crates/gpui-host/src/drag.rs:28–29 | `rgb(0x315b85)` / `rgb(0xffffff)` |
| Drop-target highlight | crates/gpui-host/src/drag.rs:73 | `rgb(0x294962)` |

Two of these interacted badly with the working pattern; both are resolved:

- **Resolved:** style version 2 adds `hover_bg` and
  `active_bg`. An explicit state color always wins on enabled
  buttons; the sentinels preserve the old behavior (host feedback for
  default-background buttons, none for explicitly colored ones), so themed
  buttons declare their own state colors - see the accent buttons across
  [examples-gui](../examples-gui).
- **Resolved:** the editor's inner field, placeholder, cursor, and selection
  now resolve from the element's style record (background, foreground,
  border color, radius, font size), with the old constants as sentinels; a
  light-background editor derives a dark placeholder from its foreground.

A third gap from the same review - `height: Fill` overshooting padded
parents and panels kissing the exact window bottom - is **resolved** in
`apply_style`: Fill now means the parent's content box (main-axis flex
distribution of free space instead of a border-box percentage).

The root background is reachable in practice — a `Fill`/`Fill` styled root
column covers it — but window frame, scrollbars, dialog scrim, and drag ghost
have no application route at all.

## Proposed direction

Out of scope by decision of the project owner: a host-owned theme record,
a theme field in the boundary protocol, or any host-side palette resolution.
Theming stays application data flowing through the existing style machinery.
The additions below extend that machinery in the smallest steps that close the
table above.

### 1. Attributes for the remaining controls

**Shipped** as `Gui.action_button : ActionButtonProps, Msg`;
`Gui.button` keeps its two-argument shape so no call site moved. Leave
`heading`, `text`, and `text_s` alone initially; wrapping in a styled
container already themes them through inheritance, and adding attributes
there can follow demand.

### 2. Style record version 2

The encoded style record is versioned by construction — the first field is a
version number and the Zig validator rejects unknown shapes
([docs/native-gui-protocol.md](../docs/native-gui-protocol.md)) — so adding
fields is the anticipated evolution, not a format break. Propose a version 2
with a small set of state and role colors, each defaulting to the inherit
sentinel so an omitted `Gui.Style` field continues to mean "host behavior":

- `hover_bg`, `active_bg` — **shipped** in style v2 (protocol
  10) for buttons; an explicit value always wins, sentinels preserve the old
  behavior exactly, and checkboxes deliberately ignore the state slots. The
  drop-target highlight still uses its constant.
- `accent` — cursor, selection highlight (host derives the alpha), selected
  ring, and scrollbar thumb within that element's scroll region.
- `muted` — placeholder text, textarea caption, scrollbar track.

Precedence is uniform: host control default ← explicit style field. Selected
state draws the ring in `accent` (falling back to the current constant);
disabled state keeps the opacity treatment on top of whatever colors resolve;
hover/active resolve from the new fields first, then — only when the
background is also default — from the current host constants. Whether a
default hover over an explicit background should derive a shade or do nothing
is an open question below.

Editor chrome stops being special — **shipped**: the inner field uses the
element's `bg`, `fg`, `border_color`, `radius`, and
`font_size` when supplied; the foreground drives placeholder, cursor, and
selection tint, so no dedicated `accent`/`muted` fields were needed for the
editor rows. The textarea caption color remains a host constant for now.

### 3. Window-level chrome

Scrollbars on the window, the frame, the dialog scrim, and the drag ghost are
not per-element. `Gui.window_lifecycle` is already the single app-root wrapper
and already carries a style attribute
([platform-gui/Gui.roc](../platform-gui/Gui.roc) lines 259–289); its resolved
style — including the version-2 `accent`/`muted` fields — is the natural source
for frame, root scrollbars, scrim, and ghost colors. This keeps window chrome
app-declared through the existing field machinery rather than a new protocol
surface. Defer committing to this until packages 1–2 have validated the
version-2 fields.

## Work packages

1. **Themed example and inventory check.** Add a light/dark toggle example
   under [examples-gui](../examples-gui) using only today's API, structured as
   the sketch above. It demonstrates the pattern and makes every gap in the
   table visible on screen. Documentation: extend
   [www/content/docs/native-gui.md](../www/content/docs/native-gui.md) with the
   pattern (no example there uses `changes` today).
2. **Button attributes.** `Gui.action_button` carries the button's props;
   migrate examples and specs together.
3. **Style version 2.** Roc encoder, Zig validation, extern struct extension,
   Rust application for `hover_bg`, `active_bg`, `accent`,
   `muted`; buttons, drop targets, selected ring, and scrollable elements
   consume them. The Zig display-free host validates and stores the longer
   record exactly as it stores version 1; native specs need only tolerate the
   added fields.
4. **Editor chrome from element style.** Inner field colors, cursor,
   selection, placeholder, caption resolve per the precedence rules; remove
   the corresponding constants from lib.rs and input.rs.
5. **Window-level resolution.** Frame, scrollbar, scrim, and ghost colors from
   the `window_lifecycle` style, behind the deferred decision above.

Each package updates protocol documentation and rebuilds host and app together,
as the version-7 boundary already requires.

## Testing

- GPUI adapter tests assert resolved colors for each precedence case: default
  chrome, explicit field, hover/active with and without explicit background,
  selected and disabled combinations.
- Native semantic specs confirm the version-2 record round-trips through
  validation and publication and that version-1 records remain accepted.
- The themed example switches palettes in a driven session; a screenshot-level
  or property assertion confirms no control retains a dark-only constant.
- All documentation snippets compile (`roc check`), per house practice.

## Open questions

- Should a default hover state over an explicit background derive a
  lightened/darkened shade, or render no hover feedback? Deriving is
  convenient but invents color math in the host.
- Checkbox glyphs are text literals; is glyph choice presentation (a future
  style field) or control identity (leave fixed)?
- OS dark-mode detection would need a host-published signal or event; that is
  a separate capability decision and deliberately outside this note.
- Contrast guarantees remain the application's responsibility under this
  direction; the platform only promises faithful color application.
