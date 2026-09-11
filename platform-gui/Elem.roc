import Node
import HostValue exposing [HostValue]
import Capability
import Gui
import Signal exposing [Signal]

## UI element descriptor tree. Markup nodes (`Element`, `Text`, `TextSignal`)
## carry no identity. Scope/binder nodes are the identity-bearing positions the
## host walk accounts for:
## - `State`: introduces a state binder (boxed init thunk + boxed is_eq thunk)
##   and a child subtree built with that binder in scope. Advances the scope
##   ordinal.
## - `When`: a value-selected lazy branch. Its retained builder materializes only
##   the live subtree, which owns a branch scope. Advances the scope ordinal.
## - `Each`: a keyed list backed by an immutable collection capability. Each row
##   is its own scope keyed by exact UTF-8 bytes. The row thunk receives the
##   host-owned key and stable row handle. Advances the scope ordinal.
## - `Component`: introduces a reusable local scope for helper-owned state.
##   Advances the parent scope ordinal and collects the child under a component
##   scope whose internal ordinals are local to the component instance.
## - `OnChange`: a non-rendering sink that runs a host command when a signal's
##   value changes, optionally including the first mounted value.
## - `OnMount`: a non-rendering sink that runs a host command when the owning
##   scope first enters the live tree.
## - `Cleanup`: a non-rendering descriptor run when the owning scope is disposed.
## On the native platform, every control constructor lives here as well: a
## props record whose fields all default, followed by children or a handler,
## for example `Elem.col({ test_id: "count", gap: 4 }, children)`. The style
## fields carry that control's own presentation defaults; optional attributes
## such as `test_id`, `selected`, or `on_drop` cost nothing when omitted; a
## `changes` signal supplies the whole style reactively and replaces the static
## style fields wholesale. A props record built outside the call, or inside a
## `Signal.map` transform, needs an explicit type such as `Elem.PanelProps.{ ... }`,
## because only a literal passed directly to the control absorbs the defaults.
Elem := [
	Component({ child : Box(Elem) }),
	Cleanup({ cleanup : Node.Cleanup }),
	Element({ namespace : [Html, Svg], tag : Str, attrs : List(Node.Attr), children : List(Elem) }),
	OnChange({ signal : Box(Node.SignalExpr), to_cmd : Box((HostValue -> Node.Cmd)) }),
	OnChangeInitial({ signal : Box(Node.SignalExpr), to_cmd : Box((HostValue -> Node.Cmd)) }),
	OnMount({ to_cmd : Box((() -> Node.Cmd)) }),
	Text(Str),
	TextSignal({ signal : Box(Node.SignalExpr), read : HostValue.TextReadHandle }),
	State({ binder : Node.BinderRef, initial : Box((() -> HostValue)), cap : HostValue.CapabilityHandle, child : Box(Elem) }),
	When(
		{
			condition : Box(Node.SignalExpr),
			ops : {
				case_capability : HostValue.CapabilityHandle,
				build : Box((HostValue -> Elem)),
			},
		},
	),
	Each(
		{
			rows : Box(Node.SignalExpr),
			ops : {
				rows_capability : HostValue.CapabilityHandle,
				item_capability : HostValue.CapabilityHandle,
				describe : Box((HostValue, U64 -> U64)),
				copy_snapshot : Box((HostValue, U64 -> U64)),
				copy_delta : Box((HostValue, U64 -> U64)),
				compare_slots : Box((HostValue, HostValue, List(U64), U64 -> U64)),
				clone_item : Box((HostValue, U64 -> HostValue)),
				row : Box((Str, U64 -> Elem)),
			},
		},
	),
].{
	## A string literal in an element position is literal text, so a child list
	## can hold `"Hello"` directly instead of `Html.text("Hello")`.
	from_quote : Str -> Try(Elem, [BadQuotedBytes(Str)])
	from_quote = |value| Ok(Text(value))

	## Props for `col`. Neutral presentation.
	## The style fields are the same as `Gui.Style`; their defaults are this control's
	## own presentation, so a literal names only what it changes.
	## `test_id` is a stable semantic locator. `label` is a semantic name independent
	## of styling. `font_family` names an installed or embedded family that
	## descendants inherit. `embedded_fonts` registers compile-time font bytes once,
	## on the app's root element only; the host rejects more than 8 fonts or fonts
	## over 8 MiB. `selected` marks selection independently of checkbox state.
	## `enabled` and `disabled` toggle input from a signal while retaining native
	## identity. `shortcuts` bind exact chords within this focused region; the
	## nearest matching ancestor receives one unit event and consumes the
	## keystroke, and duplicates or more than 32 on one element are errors.
	## `drag_source` offers a bounded key for an internal drag, and `on_drop`
	## accepts a live drag through `Ui.action_detail` or `State.update_detail`.
	ColProps := {
		label ?: Str,
		gap : U32 ?? 8,
		padding : U32 ?? 0,
		width : Gui.Length ?? Auto,
		height : Gui.Length ?? Auto,
		grow : Bool ?? False,
		bg : Gui.Color ?? Default,
		hover_bg : Gui.Color ?? Default,
		active_bg : Gui.Color ?? Default,
		fg : Gui.Color ?? Default,
		border_color : Gui.Color ?? Default,
		border_width : U32 ?? 0,
		radius : U32 ?? 0,
		font_size : U32 ?? 0,
		overflow_x : Gui.Overflow ?? Visible,
		overflow_y : Gui.Overflow ?? Visible,
		changes ?: Signal(Gui.Style),
		test_id ?: Str,
		font_family ?: Str,
		embedded_fonts : List({ family : Str, bytes : List(U8) }) ?? [],
		selected ?: Signal(Bool),
		enabled ?: Signal(Bool),
		disabled ?: Signal(Bool),
		shortcuts : List({ chord : Node.KeyChord, msg : Node.Handler }) ?? [],
		drag_source ?: Str,
		on_drop ?: Node.Handler,
	}

	## Props for `row`. Neutral presentation; see `ColProps` for the attributes.
	RowProps := {
		label ?: Str,
		gap : U32 ?? 8,
		padding : U32 ?? 0,
		width : Gui.Length ?? Auto,
		height : Gui.Length ?? Auto,
		grow : Bool ?? False,
		bg : Gui.Color ?? Default,
		hover_bg : Gui.Color ?? Default,
		active_bg : Gui.Color ?? Default,
		fg : Gui.Color ?? Default,
		border_color : Gui.Color ?? Default,
		border_width : U32 ?? 0,
		radius : U32 ?? 0,
		font_size : U32 ?? 0,
		overflow_x : Gui.Overflow ?? Visible,
		overflow_y : Gui.Overflow ?? Visible,
		changes ?: Signal(Gui.Style),
		test_id ?: Str,
		font_family ?: Str,
		embedded_fonts : List({ family : Str, bytes : List(U8) }) ?? [],
		selected ?: Signal(Bool),
		enabled ?: Signal(Bool),
		disabled ?: Signal(Bool),
		shortcuts : List({ chord : Node.KeyChord, msg : Node.Handler }) ?? [],
		drag_source ?: Str,
		on_drop ?: Node.Handler,
	}

	## Props for `panel`: padded, bordered, and rounded by default. See
	## `ColProps` for the attributes.
	PanelProps := {
		label ?: Str,
		gap : U32 ?? 8,
		padding : U32 ?? 16,
		width : Gui.Length ?? Auto,
		height : Gui.Length ?? Auto,
		grow : Bool ?? False,
		bg : Gui.Color ?? Default,
		hover_bg : Gui.Color ?? Default,
		active_bg : Gui.Color ?? Default,
		fg : Gui.Color ?? Default,
		border_color : Gui.Color ?? Rgb(4743275),
		border_width : U32 ?? 1,
		radius : U32 ?? 8,
		font_size : U32 ?? 0,
		overflow_x : Gui.Overflow ?? Visible,
		overflow_y : Gui.Overflow ?? Visible,
		changes ?: Signal(Gui.Style),
		test_id ?: Str,
		font_family ?: Str,
		embedded_fonts : List({ family : Str, bytes : List(U8) }) ?? [],
		selected ?: Signal(Bool),
		enabled ?: Signal(Bool),
		disabled ?: Signal(Bool),
		shortcuts : List({ chord : Node.KeyChord, msg : Node.Handler }) ?? [],
		drag_source ?: Str,
		on_drop ?: Node.Handler,
	}

	## Props for `dialog`. `label` names the dialog and `on_dismiss` receives the
	## Escape shortcut. See `ColProps` for the other attributes.
	DialogProps := {
		label : Str,
		on_dismiss : Node.Handler,
		gap : U32 ?? 16,
		padding : U32 ?? 24,
		width : Gui.Length ?? Px(520),
		height : Gui.Length ?? Auto,
		grow : Bool ?? False,
		bg : Gui.Color ?? Rgb(2174263),
		hover_bg : Gui.Color ?? Default,
		active_bg : Gui.Color ?? Default,
		fg : Gui.Color ?? Rgb(15658730),
		border_color : Gui.Color ?? Rgb(4743275),
		border_width : U32 ?? 1,
		radius : U32 ?? 8,
		font_size : U32 ?? 0,
		overflow_x : Gui.Overflow ?? Visible,
		overflow_y : Gui.Overflow ?? Visible,
		changes ?: Signal(Gui.Style),
		test_id ?: Str,
		font_family ?: Str,
		embedded_fonts : List({ family : Str, bytes : List(U8) }) ?? [],
		selected ?: Signal(Bool),
		enabled ?: Signal(Bool),
		disabled ?: Signal(Bool),
		shortcuts : List({ chord : Node.KeyChord, msg : Node.Handler }) ?? [],
		drag_source ?: Str,
		on_drop ?: Node.Handler,
	}

	## Props for `virtual_list`. `row_height` is the fixed logical row height,
	## and `follow_tail` keeps the final row in view as history grows. See
	## `ColProps` for the other attributes.
	VirtualListProps := {
		row_height : U32,
		follow_tail : Signal(Bool),
		label ?: Str,
		gap : U32 ?? 8,
		padding : U32 ?? 0,
		width : Gui.Length ?? Fill,
		height : Gui.Length ?? Px(480),
		grow : Bool ?? True,
		bg : Gui.Color ?? Default,
		hover_bg : Gui.Color ?? Default,
		active_bg : Gui.Color ?? Default,
		fg : Gui.Color ?? Default,
		border_color : Gui.Color ?? Default,
		border_width : U32 ?? 0,
		radius : U32 ?? 0,
		font_size : U32 ?? 0,
		overflow_x : Gui.Overflow ?? Visible,
		overflow_y : Gui.Overflow ?? Visible,
		changes ?: Signal(Gui.Style),
		test_id ?: Str,
		font_family ?: Str,
		embedded_fonts : List({ family : Str, bytes : List(U8) }) ?? [],
		selected ?: Signal(Bool),
		enabled ?: Signal(Bool),
		disabled ?: Signal(Bool),
		shortcuts : List({ chord : Node.KeyChord, msg : Node.Handler }) ?? [],
		drag_source ?: Str,
		on_drop ?: Node.Handler,
	}

	## Props for `image`. `source` is a relative path inside the host's assets
	## root and `label` is the picture's semantic name. See `ColProps` for the
	## other attributes.
	ImageProps := {
		source : Str,
		label : Str,
		gap : U32 ?? 8,
		padding : U32 ?? 0,
		width : Gui.Length ?? Auto,
		height : Gui.Length ?? Auto,
		grow : Bool ?? False,
		bg : Gui.Color ?? Default,
		hover_bg : Gui.Color ?? Default,
		active_bg : Gui.Color ?? Default,
		fg : Gui.Color ?? Default,
		border_color : Gui.Color ?? Default,
		border_width : U32 ?? 0,
		radius : U32 ?? 0,
		font_size : U32 ?? 0,
		overflow_x : Gui.Overflow ?? Visible,
		overflow_y : Gui.Overflow ?? Visible,
		changes ?: Signal(Gui.Style),
		test_id ?: Str,
		font_family ?: Str,
		embedded_fonts : List({ family : Str, bytes : List(U8) }) ?? [],
		selected ?: Signal(Bool),
		enabled ?: Signal(Bool),
		disabled ?: Signal(Bool),
		shortcuts : List({ chord : Node.KeyChord, msg : Node.Handler }) ?? [],
		drag_source ?: Str,
		on_drop ?: Node.Handler,
	}

	## Props for `action_button`. `caption` is the live button text, `label` an
	## optional semantic name that replaces the caption for locators, and
	## `enabled` defaults to always enabled. The style defaults are the button's
	## own colors. See `ColProps` for the other attributes.
	ActionButtonProps := {
		caption : Signal(Str),
		label ?: Str,
		gap : U32 ?? 8,
		padding : U32 ?? 8,
		width : Gui.Length ?? Auto,
		height : Gui.Length ?? Auto,
		grow : Bool ?? False,
		bg : Gui.Color ?? Rgb(3232873),
		hover_bg : Gui.Color ?? Rgb(0x3F6175),
		active_bg : Gui.Color ?? Rgb(0x2B4452),
		fg : Gui.Color ?? Default,
		border_color : Gui.Color ?? Default,
		border_width : U32 ?? 0,
		radius : U32 ?? 6,
		font_size : U32 ?? 0,
		overflow_x : Gui.Overflow ?? Visible,
		overflow_y : Gui.Overflow ?? Visible,
		changes ?: Signal(Gui.Style),
		test_id ?: Str,
		font_family ?: Str,
		embedded_fonts : List({ family : Str, bytes : List(U8) }) ?? [],
		selected ?: Signal(Bool),
		enabled : Signal(Bool) ?? Signal.const(True),
		disabled ?: Signal(Bool),
		shortcuts : List({ chord : Node.KeyChord, msg : Node.Handler }) ?? [],
		drag_source ?: Str,
		on_drop ?: Node.Handler,
	}

	## Props for `text_input`. `label` is the field's semantic name, `value` its
	## controlled text, and `placeholder` an explicit empty-field hint. See
	## `ColProps` for the other attributes.
	TextInputProps := {
		label : Str,
		value : Signal(Str),
		placeholder ?: Str,
		gap : U32 ?? 8,
		padding : U32 ?? 0,
		width : Gui.Length ?? Auto,
		height : Gui.Length ?? Auto,
		grow : Bool ?? False,
		bg : Gui.Color ?? Default,
		hover_bg : Gui.Color ?? Default,
		active_bg : Gui.Color ?? Default,
		fg : Gui.Color ?? Default,
		border_color : Gui.Color ?? Default,
		border_width : U32 ?? 0,
		radius : U32 ?? 0,
		font_size : U32 ?? 0,
		overflow_x : Gui.Overflow ?? Visible,
		overflow_y : Gui.Overflow ?? Visible,
		changes ?: Signal(Gui.Style),
		test_id ?: Str,
		font_family ?: Str,
		embedded_fonts : List({ family : Str, bytes : List(U8) }) ?? [],
		selected ?: Signal(Bool),
		enabled ?: Signal(Bool),
		disabled ?: Signal(Bool),
		shortcuts : List({ chord : Node.KeyChord, msg : Node.Handler }) ?? [],
		drag_source ?: Str,
		on_drop ?: Node.Handler,
	}

	## Props for `textarea`; the fields match `TextInputProps`.
	TextareaProps := {
		label : Str,
		value : Signal(Str),
		placeholder ?: Str,
		gap : U32 ?? 8,
		padding : U32 ?? 0,
		width : Gui.Length ?? Auto,
		height : Gui.Length ?? Auto,
		grow : Bool ?? False,
		bg : Gui.Color ?? Default,
		hover_bg : Gui.Color ?? Default,
		active_bg : Gui.Color ?? Default,
		fg : Gui.Color ?? Default,
		border_color : Gui.Color ?? Default,
		border_width : U32 ?? 0,
		radius : U32 ?? 0,
		font_size : U32 ?? 0,
		overflow_x : Gui.Overflow ?? Visible,
		overflow_y : Gui.Overflow ?? Visible,
		changes ?: Signal(Gui.Style),
		test_id ?: Str,
		font_family ?: Str,
		embedded_fonts : List({ family : Str, bytes : List(U8) }) ?? [],
		selected ?: Signal(Bool),
		enabled ?: Signal(Bool),
		disabled ?: Signal(Bool),
		shortcuts : List({ chord : Node.KeyChord, msg : Node.Handler }) ?? [],
		drag_source ?: Str,
		on_drop ?: Node.Handler,
		## Keeps the text focusable and selectable while refusing edits; lowers
		## to the native read-only field rather than disabling the control.
		read_only ?: Signal(Bool),
	}

	## Props for `checkbox`. `label` is the semantic name and `checked` the
	## controlled state. See `ColProps` for the other attributes.
	CheckboxProps := {
		label : Str,
		checked : Signal(Bool),
		gap : U32 ?? 8,
		padding : U32 ?? 0,
		width : Gui.Length ?? Auto,
		height : Gui.Length ?? Auto,
		grow : Bool ?? False,
		bg : Gui.Color ?? Default,
		hover_bg : Gui.Color ?? Default,
		active_bg : Gui.Color ?? Default,
		fg : Gui.Color ?? Default,
		border_color : Gui.Color ?? Default,
		border_width : U32 ?? 0,
		radius : U32 ?? 0,
		font_size : U32 ?? 0,
		overflow_x : Gui.Overflow ?? Visible,
		overflow_y : Gui.Overflow ?? Visible,
		changes ?: Signal(Gui.Style),
		test_id ?: Str,
		font_family ?: Str,
		embedded_fonts : List({ family : Str, bytes : List(U8) }) ?? [],
		selected ?: Signal(Bool),
		enabled ?: Signal(Bool),
		disabled ?: Signal(Bool),
		shortcuts : List({ chord : Node.KeyChord, msg : Node.Handler }) ?? [],
		drag_source ?: Str,
		on_drop ?: Node.Handler,
	}

	## Lay out children horizontally.
	row : RowProps, List(Elem) -> Elem
	row = |p, children| build_div(lower_common(0, { style: Gui.Style.{ gap: p.gap, padding: p.padding, width: p.width, height: p.height, grow: p.grow, bg: p.bg, hover_bg: p.hover_bg, active_bg: p.active_bg, fg: p.fg, border_color: p.border_color, border_width: p.border_width, radius: p.radius, font_size: p.font_size, overflow_x: p.overflow_x, overflow_y: p.overflow_y }, changes: opt(p.?changes), test_id: opt(p.?test_id), font_family: opt(p.?font_family), embedded_fonts: p.embedded_fonts, selected: opt(p.?selected), enabled: opt(p.?enabled), disabled: opt(p.?disabled), shortcuts: p.shortcuts, drag_source: opt(p.?drag_source), on_drop: opt(p.?on_drop), label: opt(p.?label), placeholder: None }), children)

	## Lay out children vertically.
	col : ColProps, List(Elem) -> Elem
	col = |p, children| build_div(lower_common(1, { style: Gui.Style.{ gap: p.gap, padding: p.padding, width: p.width, height: p.height, grow: p.grow, bg: p.bg, hover_bg: p.hover_bg, active_bg: p.active_bg, fg: p.fg, border_color: p.border_color, border_width: p.border_width, radius: p.radius, font_size: p.font_size, overflow_x: p.overflow_x, overflow_y: p.overflow_y }, changes: opt(p.?changes), test_id: opt(p.?test_id), font_family: opt(p.?font_family), embedded_fonts: p.embedded_fonts, selected: opt(p.?selected), enabled: opt(p.?enabled), disabled: opt(p.?disabled), shortcuts: p.shortcuts, drag_source: opt(p.?drag_source), on_drop: opt(p.?on_drop), label: opt(p.?label), placeholder: None }), children)

	## Group content in a padded, bordered vertical panel.
	panel : PanelProps, List(Elem) -> Elem
	panel = |p, children| build_div(lower_common(1, { style: Gui.Style.{ gap: p.gap, padding: p.padding, width: p.width, height: p.height, grow: p.grow, bg: p.bg, hover_bg: p.hover_bg, active_bg: p.active_bg, fg: p.fg, border_color: p.border_color, border_width: p.border_width, radius: p.radius, font_size: p.font_size, overflow_x: p.overflow_x, overflow_y: p.overflow_y }, changes: opt(p.?changes), test_id: opt(p.?test_id), font_family: opt(p.?font_family), embedded_fonts: p.embedded_fonts, selected: opt(p.?selected), enabled: opt(p.?enabled), disabled: opt(p.?disabled), shortcuts: p.shortcuts, drag_source: opt(p.?drag_source), on_drop: opt(p.?on_drop), label: opt(p.?label), placeholder: None }), children)

	## A native close request enters the ordinary event graph. KeepOpen cancels
	## it, AwaitDecision retains one pending request, and Close completes that
	## request after the decision's transaction commits. Close without a pending
	## request has no effect. Declare exactly one wrapper directly under the app
	## root; disposing or replacing it cancels its pending request.
	CloseDecision : [KeepOpen, AwaitDecision, Close]

	window_lifecycle : { on_close_requested : Node.Handler, decision : Signal(CloseDecision) }, List(Elem) -> Elem
	window_lifecycle = |props, children| {
		policy = props.decision.map(
			|decision| match decision {
				KeepOpen => "keep-open"
				AwaitDecision => "await-decision"
				Close => "close"
			},
		)
		Element({
			namespace: Html,
			tag: "window",
			attrs: [
				style_attr(1, Gui.Style.{ width: Fill, height: Fill }),
				signal_text(native_window_close_field, policy),
				Node.Attr.On({
					kind: { id: 0 },
					name: "close-requested",
					msg: props.on_close_requested,
					policy: event_policy_none,
					delivery: event_delivery_native,
					key_chord: None,
				}),
			],
			children,
		})
	}

	## Present a modal owned by this element's explicit Ui.when scope. The host
	## moves focus inside, traps Tab, routes Escape to on_dismiss, and restores
	## a still-live enabled control after disposal. Concurrent dialogs form one
	## chain of at most eight, each bounded to 1024 nodes and 256 enabled controls.
	dialog : DialogProps, List(Elem) -> Elem
	dialog = |p, children| {
		escape = { chord: { key: "Escape", control: False, shift: False, alt: False, meta: False }, msg: p.on_dismiss }
		common = { style: Gui.Style.{ gap: p.gap, padding: p.padding, width: p.width, height: p.height, grow: p.grow, bg: p.bg, hover_bg: p.hover_bg, active_bg: p.active_bg, fg: p.fg, border_color: p.border_color, border_width: p.border_width, radius: p.radius, font_size: p.font_size, overflow_x: p.overflow_x, overflow_y: p.overflow_y }, changes: opt(p.?changes), test_id: opt(p.?test_id), font_family: opt(p.?font_family), embedded_fonts: p.embedded_fonts, selected: opt(p.?selected), enabled: opt(p.?enabled), disabled: opt(p.?disabled), shortcuts: p.shortcuts, drag_source: opt(p.?drag_source), on_drop: opt(p.?on_drop), label: Some(p.label), placeholder: None }
		Element({
			namespace: Html,
			tag: "dialog",
			attrs: lower_common(1, { ..common, shortcuts: [escape].concat(p.shortcuts) }),
			children,
		})
	}

	## Presents direct child rows at a fixed logical height, creating GPUI layout
	## only for the visible range. Child scopes remain owned by ordinary Ui.each.
	## With follow_tail enabled, new history keeps the final row in view.
	virtual_list : VirtualListProps, List(Elem) -> Elem
	virtual_list = |p, children| {
		if p.row_height == 0 or p.row_height > 16384 {
			crash "Gui virtual row height must be between 1 and 16384"
		}
		encoded = p.follow_tail.map(
			|follow| "1,${p.row_height.to_str()},${
				if follow {
					"1"
				} else {
					"0"
				}
			}",
		)
		build_div(lower_common(1, { style: Gui.Style.{ gap: p.gap, padding: p.padding, width: p.width, height: p.height, grow: p.grow, bg: p.bg, hover_bg: p.hover_bg, active_bg: p.active_bg, fg: p.fg, border_color: p.border_color, border_width: p.border_width, radius: p.radius, font_size: p.font_size, overflow_x: p.overflow_x, overflow_y: p.overflow_y }, changes: opt(p.?changes), test_id: opt(p.?test_id), font_family: opt(p.?font_family), embedded_fonts: p.embedded_fonts, selected: opt(p.?selected), enabled: opt(p.?enabled), disabled: opt(p.?disabled), shortcuts: p.shortcuts, drag_source: opt(p.?drag_source), on_drop: opt(p.?on_drop), label: opt(p.?label), placeholder: None }).append(signal_text(native_viewport_field, encoded)), children)
	}

	## Render an image from a relative path inside the host's assets root.
	## Absolute paths, `..` traversal, and URIs never resolve; a missing or
	## undecodable source renders a neutral placeholder box of the styled size.
	## The label is a semantic name for the picture, never derived by the host.
	image : ImageProps -> Elem
	image = |p| {
		if p.source.is_empty() or p.source.to_utf8().len() > 1024 {
			crash "Gui image sources contain 1 to 1024 UTF-8 bytes"
		}
		Element({
			namespace: Html,
			tag: "img",
			attrs: lower_common(1, { style: Gui.Style.{ gap: p.gap, padding: p.padding, width: p.width, height: p.height, grow: p.grow, bg: p.bg, hover_bg: p.hover_bg, active_bg: p.active_bg, fg: p.fg, border_color: p.border_color, border_width: p.border_width, radius: p.radius, font_size: p.font_size, overflow_x: p.overflow_x, overflow_y: p.overflow_y }, changes: opt(p.?changes), test_id: opt(p.?test_id), font_family: opt(p.?font_family), embedded_fonts: p.embedded_fonts, selected: opt(p.?selected), enabled: opt(p.?enabled), disabled: opt(p.?disabled), shortcuts: p.shortcuts, drag_source: opt(p.?drag_source), on_drop: opt(p.?on_drop), label: Some(p.label), placeholder: None }).append(Node.Attr.StaticText({ field: native_image_source_field, name: "", value: p.source })),
			children: [],
		})
	}

	## Render a prominent heading.
	heading : Str -> Elem
	heading = |value| build_heading(value)

	## Render literal text without interpreting markup.
	text : Str -> Elem
	text = |value| Text(value)

	## Render only the text changes published by this signal.
	text_s : Signal(Str) -> Elem
	text_s = |value| build_text_s(value)

	## Create an enabled button with a static label for a unit action. Use
	## `action_button` for a styled button or one whose caption or availability
	## changes.
	button : Str, Node.Handler -> Elem
	button = |value, message| build_button(value, message)

	## Create a button whose caption and availability change independently.
	action_button : ActionButtonProps, Node.Handler -> Elem
	action_button = |p, message|
		build_action_button(p.caption, p.enabled.map(|is_enabled| !is_enabled), lower_common(1, { style: Gui.Style.{ gap: p.gap, padding: p.padding, width: p.width, height: p.height, grow: p.grow, bg: p.bg, hover_bg: p.hover_bg, active_bg: p.active_bg, fg: p.fg, border_color: p.border_color, border_width: p.border_width, radius: p.radius, font_size: p.font_size, overflow_x: p.overflow_x, overflow_y: p.overflow_y }, changes: opt(p.?changes), test_id: opt(p.?test_id), font_family: opt(p.?font_family), embedded_fonts: p.embedded_fonts, selected: opt(p.?selected), enabled: None, disabled: opt(p.?disabled), shortcuts: p.shortcuts, drag_source: opt(p.?drag_source), on_drop: opt(p.?on_drop), label: opt(p.?label), placeholder: None }), message)

	## Edit one controlled line; the label is a semantic name, not placeholder text.
	text_input : TextInputProps, Node.Handler -> Elem
	text_input = |p, message|
		build_text_input(p.label, p.value, lower_common(1, { style: Gui.Style.{ gap: p.gap, padding: p.padding, width: p.width, height: p.height, grow: p.grow, bg: p.bg, hover_bg: p.hover_bg, active_bg: p.active_bg, fg: p.fg, border_color: p.border_color, border_width: p.border_width, radius: p.radius, font_size: p.font_size, overflow_x: p.overflow_x, overflow_y: p.overflow_y }, changes: opt(p.?changes), test_id: opt(p.?test_id), font_family: opt(p.?font_family), embedded_fonts: p.embedded_fonts, selected: opt(p.?selected), enabled: opt(p.?enabled), disabled: opt(p.?disabled), shortcuts: p.shortcuts, drag_source: opt(p.?drag_source), on_drop: opt(p.?on_drop), label: None, placeholder: opt(p.?placeholder) }), message)

	## Edit controlled text with hard line breaks and a retained selection.
	## An explicit height includes caption and padding; the editor fills the rest.
	## Auto height retains a 320-pixel editing viewport.
	textarea : TextareaProps, Node.Handler -> Elem
	textarea = |p, message| {
		read_only = match opt(p.?read_only) {
			Some(value) => [signal_bool(native_read_only_field, value)]
			None => []
		}
		build_textarea(p.label, p.value, lower_common(1, { style: Gui.Style.{ gap: p.gap, padding: p.padding, width: p.width, height: p.height, grow: p.grow, bg: p.bg, hover_bg: p.hover_bg, active_bg: p.active_bg, fg: p.fg, border_color: p.border_color, border_width: p.border_width, radius: p.radius, font_size: p.font_size, overflow_x: p.overflow_x, overflow_y: p.overflow_y }, changes: opt(p.?changes), test_id: opt(p.?test_id), font_family: opt(p.?font_family), embedded_fonts: p.embedded_fonts, selected: opt(p.?selected), enabled: opt(p.?enabled), disabled: opt(p.?disabled), shortcuts: p.shortcuts, drag_source: opt(p.?drag_source), on_drop: opt(p.?on_drop), label: None, placeholder: opt(p.?placeholder) }).concat(read_only), message)
	}

	## Toggle a controlled boolean using the ordinary checked-value event route.
	checkbox : CheckboxProps, Node.Handler -> Elem
	checkbox = |p, message|
		build_checkbox(p.label, p.checked, lower_common(0, { style: Gui.Style.{ gap: p.gap, padding: p.padding, width: p.width, height: p.height, grow: p.grow, bg: p.bg, hover_bg: p.hover_bg, active_bg: p.active_bg, fg: p.fg, border_color: p.border_color, border_width: p.border_width, radius: p.radius, font_size: p.font_size, overflow_x: p.overflow_x, overflow_y: p.overflow_y }, changes: opt(p.?changes), test_id: opt(p.?test_id), font_family: opt(p.?font_family), embedded_fonts: p.embedded_fonts, selected: opt(p.?selected), enabled: opt(p.?enabled), disabled: opt(p.?disabled), shortcuts: p.shortcuts, drag_source: opt(p.?drag_source), on_drop: opt(p.?on_drop), label: None, placeholder: None }), message)
}

# BEGIN GENERATED PROTOCOL (scripts/generate_protocol.py; edit protocol/native-protocol.json)
# Versioned native presentation record; never encoded on the browser wire.
native_style_field : Node.TextField
native_style_field = { id: 8 }
# Fixed-row virtual list record `1,row_height,follow_tail`.
native_viewport_field : Node.TextField
native_viewport_field = { id: 9 }
# Bounded application key exposed by an internal drag source.
native_drag_key_field : Node.TextField
native_drag_key_field = { id: 10 }
# Window close policy: `keep-open`, `await-decision`, or `close`.
native_window_close_field : Node.TextField
native_window_close_field = { id: 11 }
# Static empty-field hint text shown while a controlled field is empty.
native_placeholder_field : Node.TextField
native_placeholder_field = { id: 12 }
# Relative image source resolved against the process-wide assets root.
native_image_source_field : Node.TextField
native_image_source_field = { id: 13 }
# Static font family joined into the element's inherited text style.
native_font_family_field : Node.TextField
native_font_family_field = { id: 14 }
# Versioned embedded-font registration declaration; registered once at startup.
native_fonts_field : Node.TextField
native_fonts_field = { id: 15 }
# Disables input while retaining native identity.
disabled_field : Node.BoolField
disabled_field = { id: 2 }
# Native selected presentation, independent of checkbox state.
selected_field : Node.BoolField
selected_field = { id: 4 }
# Marks an internal drop target that must bind a string-detail drop event.
native_drop_target_field : Node.BoolField
native_drop_target_field = { id: 5 }
# Refuses user edits and edit history while the control stays available at full contrast and in tab order.
native_read_only_field : Node.BoolField
native_read_only_field = { id: 6 }
# END GENERATED PROTOCOL

dimension : Gui.Length -> { kind : U32, value : U32 }
dimension = |length| match length {
	Auto => { kind: 0, value: 0 }
	Fill => { kind: 1, value: 0 }
	Px(value) => { kind: 2, value }
}

color_number : Gui.Color -> U32
color_number = |color| match color {
	Default => 16777216
	Rgb(value) => if value <= 16777215 {
		value
	} else {
		crash "Gui color must be a 24-bit RGB value"
	}
}

overflow_number : Gui.Overflow -> U32
overflow_number = |overflow| match overflow {
	Visible => 0
	Clip => 1
	Scroll => 2
}

# Native presentation protocol v2: fixed, canonical decimal fields. The host
# validates the complete record before publication; these are not CSS strings.
encode_style : U32, Gui.Style -> Str
encode_style = |direction, style| {
	width = dimension(style.width)
	height = dimension(style.height)
	grow = if style.grow {
		1.U32
	} else {
		0.U32
	}
	"2,${direction.to_str()},${style.gap.to_str()},${style.padding.to_str()},${width.kind.to_str()},${width.value.to_str()},${height.kind.to_str()},${height.value.to_str()},${grow.to_str()},${color_number(style.bg).to_str()},${color_number(style.hover_bg).to_str()},${color_number(style.active_bg).to_str()},${color_number(style.fg).to_str()},${color_number(style.border_color).to_str()},${style.border_width.to_str()},${style.radius.to_str()},${style.font_size.to_str()},${overflow_number(style.overflow_x).to_str()},${overflow_number(style.overflow_y).to_str()}"
}

base64_table : List(U8)
base64_table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".to_utf8()

# Standard base64 with '=' padding. Font bytes are embedded raw at compile
# time; this runs once at startup while the app's element tree is built.
encode_base64 : List(U8) -> Str
encode_base64 = |bytes| {
	char = |index| base64_table.get(index.to_u64()) ?? crash "base64 index is always below 64"
	encoded = bytes.fold(
		{ out: [], carry: 0.U8, phase: 0.U8 },
		|state, byte| match state.phase {
			0 => { out: state.out.append(char(byte.shr_wrap(2))), carry: byte.bitwise_and(3).shl_wrap(4), phase: 1 }
			1 => { out: state.out.append(char(state.carry.bitwise_or(byte.shr_wrap(4)))), carry: byte.bitwise_and(15).shl_wrap(2), phase: 2 }
			_ => { out: state.out.append(char(state.carry.bitwise_or(byte.shr_wrap(6)))).append(char(byte.bitwise_and(63))), carry: 0, phase: 0 }
		},
	)
	completed = match encoded.phase {
		0 => encoded.out
		1 => encoded.out.append(char(encoded.carry)).append(61).append(61)
		_ => encoded.out.append(char(encoded.carry)).append(61)
	}
	Str.from_utf8(completed) ?? crash "base64 output is ASCII"
}

# Host-enforced embedded font bounds, mirrored by the native adapters.
max_fonts : U64
max_fonts = 8

max_font_bytes : U64
max_font_bytes = 8388608

encode_fonts : List({ family : Str, bytes : List(U8) }) -> Str
encode_fonts = |fonts| {
	if fonts.is_empty() or fonts.len() > max_fonts {
		crash "Gui.embedded_fonts registers 1 to 8 fonts"
	}
	lines = fonts.fold(
		["1"],
		|acc, font| {
			family_bytes = font.family.to_utf8()
			if family_bytes.is_empty() or family_bytes.len() > 128 {
				crash "Gui embedded font family name must contain 1 to 128 UTF-8 bytes"
			}
			if family_bytes.any(|byte| byte < 32 or byte == 127) {
				crash "Gui embedded font family name must not contain control characters"
			}
			if font.bytes.is_empty() or font.bytes.len() > max_font_bytes {
				crash "Gui embedded font data must contain 1 to 8388608 bytes"
			}
			acc.append(font.family).append(encode_base64(font.bytes))
		},
	)
	Str.join_with(lines, "\n")
}

## One control's fully resolved attributes, ready for native lowering.
Common : {
	style : Gui.Style,
	changes : [None, Some(Signal(Gui.Style))],
	test_id : [None, Some(Str)],
	label : [None, Some(Str)],
	placeholder : [None, Some(Str)],
	font_family : [None, Some(Str)],
	embedded_fonts : List({ family : Str, bytes : List(U8) }),
	selected : [None, Some(Signal(Bool))],
	enabled : [None, Some(Signal(Bool))],
	disabled : [None, Some(Signal(Bool))],
	shortcuts : List({ chord : Node.KeyChord, msg : Node.Handler }),
	drag_source : [None, Some(Str)],
	on_drop : [None, Some(Node.Handler)],
}

## Read an optional props field as a plain option.
opt : Try(a, err) -> [None, Some(a)]
opt = |field| match field {
	Ok(value) => Some(value)
	Err(_) => None
}

style_attr : U32, Gui.Style -> Node.Attr
style_attr = |direction, style| Node.Attr.StaticText({ field: native_style_field, name: "", value: encode_style(direction, style) })

signal_text : Node.TextField, Signal(Str) -> Node.Attr
signal_text = |field, value| {
	cap = value.cap
	read : HostValue -> Str
	read = |host_value| Box.unbox(Capability.get(host_value, cap))
	Node.Attr.SignalText({ field, name: "", signal: Signal.to_expr(value), read: { capability: Capability.handle(cap), read: Box.box(read) } })
}

signal_bool : Node.BoolField, Signal(Bool) -> Node.Attr
signal_bool = |field, value| {
	cap = value.cap
	read : HostValue -> Bool
	read = |host_value| Box.unbox(Capability.get(host_value, cap))
	Node.Attr.SignalBool({ field, name: "", signal: Signal.to_expr(value), read: { capability: Capability.handle(cap), read: Box.box(read) } })
}

native_event : Str, Node.Handler, [None, Some(Node.KeyChord)] -> Node.Attr
native_event = |name, msg, key_chord| Node.Attr.On({
	kind: { id: 0 },
	name,
	msg,
	policy: { ..event_policy_none, prevent_default: True, stop_propagation: True },
	delivery: event_delivery_native,
	key_chord,
})

## Lower resolved attributes to native descriptors. A `changes` signal
## replaces the static style; every other attribute lowers only when present.
lower_common : U32, Common -> List(Node.Attr)
lower_common = |direction, common| {
	style = match common.changes {
		Some(value) => signal_text(native_style_field, value.map(|record| encode_style(direction, record)))
		None => style_attr(direction, common.style)
	}
	drag_source = match common.drag_source {
		Some(key) => {
			if key.is_empty() or key.to_utf8().len() > 256 {
				crash "Gui drag key must contain 1 to 256 UTF-8 bytes"
			}
			[Node.Attr.StaticText({ field: native_drag_key_field, name: "", value: key })]
		}
		None => []
	}
	on_drop = match common.on_drop {
		Some(msg) => [
			Node.Attr.StaticBool({ field: native_drop_target_field, name: "", value: True }),
			native_event("drop", msg, None),
		]
		None => []
	}
	text = |field, value| match value {
		Some(text_value) => [Node.Attr.StaticText({ field, name: "", value: text_value })]
		None => []
	}
	label = match common.label {
		Some(value) => [static_text(field_label, value)]
		None => []
	}
	test_id = match common.test_id {
		Some(value) => [static_text(field_test_id, value)]
		None => []
	}
	fonts = if common.embedded_fonts.is_empty() {
		[]
	} else {
		[Node.Attr.StaticText({ field: native_fonts_field, name: "", value: encode_fonts(common.embedded_fonts) })]
	}
	selected = match common.selected {
		Some(value) => [signal_bool(selected_field, value)]
		None => []
	}
	enabled = match common.enabled {
		Some(value) => [signal_bool(disabled_field, value.map(|is_enabled| !is_enabled))]
		None => []
	}
	disabled = match common.disabled {
		Some(value) => [signal_bool(disabled_field, value)]
		None => []
	}
	shortcuts = common.shortcuts.map(|shortcut| native_event("keydown", shortcut.msg, Some(shortcut.chord)))
	[style]
		.concat(on_drop)
		.concat(label)
		.concat(text(native_placeholder_field, common.placeholder))
		.concat(text(native_font_family_field, common.font_family))
		.concat(fonts)
		.concat(test_id)
		.concat(selected)
		.concat(enabled)
		.concat(disabled)
		.concat(drag_source)
		.concat(shortcuts)
}

# Browser-protocol descriptor ids and event helpers with the same values as
# platform-shared/Html.roc, so native controls build the element descriptors
# their web counterparts do and both hosts see one contract.
field_text : Node.TextField
field_text = { id: 1 }
field_role : Node.TextField
field_role = { id: 2 }
field_label : Node.TextField
field_label = { id: 3 }
field_test_id : Node.TextField
field_test_id = { id: 4 }
field_value : Node.TextField
field_value = { id: 5 }
bool_field_checked : Node.BoolField
bool_field_checked = { id: 1 }
bool_field_disabled : Node.BoolField
bool_field_disabled = { id: 2 }
fixed_event_click : Node.FixedEventKind
fixed_event_click = { id: 1 }
fixed_event_input : Node.FixedEventKind
fixed_event_input = { id: 2 }
fixed_event_check : Node.FixedEventKind
fixed_event_check = { id: 3 }

event_policy_none : Node.EventPolicy
event_policy_none = { prevent_default: False, stop_propagation: False, stop_immediate: False, capture: False, passive: False, once: False, self: False, trusted: False }

event_delivery_auto : Node.EventDelivery
event_delivery_auto = { native: False }

event_delivery_native : Node.EventDelivery
event_delivery_native = { native: True }

fixed_event : Node.FixedEventKind, Node.Handler -> Node.Attr
fixed_event = |kind, msg| Node.Attr.On({ kind, msg, policy: event_policy_none, delivery: event_delivery_auto, name: "", key_chord: None })

static_text : Node.TextField, Str -> Node.Attr
static_text = |field, value| Node.Attr.StaticText({ field, name: "", value })

build_div : List(Node.Attr), List(Elem) -> Elem
build_div = |attrs, children| Elem.Element({ namespace: Html, tag: "div", attrs, children })

build_heading : Str -> Elem
build_heading = |value| Elem.Element({ namespace: Html, tag: "h2", attrs: [static_text(field_role, "heading"), static_text(field_text, value)], children: [] })

build_text_s : Signal(Str) -> Elem
build_text_s = |value| {
	cap = value.cap
	read : HostValue -> Str
	read = |host_value| Box.unbox(Capability.get(host_value, cap))
	Elem.TextSignal({ signal: Signal.to_expr(value), read: { capability: Capability.handle(cap), read: Box.box(read) } })
}

build_button : Str, Node.Handler -> Elem
build_button = |label, msg| Elem.Element({ namespace: Html, tag: "button", attrs: [static_text(field_text, label), fixed_event(fixed_event_click, msg)], children: [] })

build_action_button : Signal(Str), Signal(Bool), List(Node.Attr), Node.Handler -> Elem
build_action_button = |label, disabled, attrs, msg| Elem.Element({
	namespace: Html,
	tag: "button",
	attrs: [signal_text(field_text, label), signal_bool(bool_field_disabled, disabled), fixed_event(fixed_event_click, msg)].concat(attrs),
	children: [],
})

build_text_input : Str, Signal(Str), List(Node.Attr), Node.Handler -> Elem
build_text_input = |label, value, attrs, msg| Elem.Element({
	namespace: Html,
	tag: "input",
	attrs: [static_text(field_role, "textbox"), static_text(field_label, label), signal_text(field_value, value), fixed_event(fixed_event_input, msg)].concat(attrs),
	children: [],
})

build_textarea : Str, Signal(Str), List(Node.Attr), Node.Handler -> Elem
build_textarea = |label, value, attrs, msg| Elem.Element({
	namespace: Html,
	tag: "textarea",
	attrs: [static_text(field_role, "textbox"), static_text(field_label, label), signal_text(field_value, value), fixed_event(fixed_event_input, msg)].concat(attrs),
	children: [],
})

build_checkbox : Str, Signal(Bool), List(Node.Attr), Node.Handler -> Elem
build_checkbox = |label, checked, attrs, msg| Elem.Element({
	namespace: Html,
	tag: "input",
	attrs: [static_text(field_role, "checkbox"), static_text(field_label, label), signal_bool(bool_field_checked, checked), fixed_event(fixed_event_check, msg)].concat(attrs),
	children: [],
})

## The native default encoding is a canonical v2 record shared with the Zig decoder.
expect encode_style(1, Gui.Style.{}) == "2,1,8,0,0,0,0,0,0,16777216,16777216,16777216,16777216,16777216,0,0,0,0,0"

## A col props literal keeps the neutral style and lowers only present attributes.
expect {
	attrs = Elem.col({ test_id: "root", padding: 4 }, [])
	match attrs {
		Elem.Element(element) => element.attrs.len() == 2
		_ => False
	}
}

## Base64 matches the canonical RFC 4648 vectors at every padding length.
expect encode_base64("foo".to_utf8()) == "Zm9v"
expect encode_base64("fo".to_utf8()) == "Zm8="
expect encode_base64("f".to_utf8()) == "Zg=="
expect encode_base64([0, 255, 127]) == "AP9/"

## The v1 declaration is one version line, then family and data lines per font.
expect encode_fonts([{ family: "Source Code Pro", bytes: "foo".to_utf8() }]) == "1\nSource Code Pro\nZm9v"
