import Elem exposing [Elem]
import Html
import Node
import Signal exposing [Signal]


Color : [Default, Rgb(U32)]

Overflow : [Visible, Clip, Scroll]

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
# END GENERATED PROTOCOL

dimension : Gui.Length -> { kind : U32, value : U32 }
dimension = |length| match length {
	Auto => { kind: 0, value: 0 }
	Fill => { kind: 1, value: 0 }
	Px(value) => { kind: 2, value }
}

color_number : Color -> U32
color_number = |color| match color {
	Default => 16777216
	Rgb(value) => if value <= 16777215 {
		value
	} else {
		crash "Gui color must be a 24-bit RGB value"
	}
}

overflow_number : Overflow -> U32
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
	"2,${direction.to_str()},${style.gap.to_str()},${style.padding.to_str()},${width.kind.to_str()},${width.value.to_str()},${height.kind.to_str()},${height.value.to_str()},${grow.to_str()},${color_number(style.background).to_str()},${color_number(style.hover_background).to_str()},${color_number(style.active_background).to_str()},${color_number(style.foreground).to_str()},${color_number(style.border_color).to_str()},${style.border_width.to_str()},${style.radius.to_str()},${style.font_size.to_str()},${overflow_number(style.overflow_x).to_str()},${overflow_number(style.overflow_y).to_str()}"
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
	shortcuts : List({ chord : Node.KeyChord, msg : Node.Msg }),
	drag_source : [None, Some(Str)],
	on_drop : [None, Some(Node.Msg)],
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
signal_text = |field, value| match Html.attr_s("", value) {
	# Html provides the same capability-owned text sink construction.
	Node.Attr.SignalText(payload) => Node.Attr.SignalText({ ..payload, field })
	_ => crash "expected a signal text descriptor"
}

signal_bool : Node.BoolField, Signal(Bool) -> Node.Attr
signal_bool = |field, value| match Html.bool_attr_s("", value) {
	Node.Attr.SignalBool(payload) => Node.Attr.SignalBool({ ..payload, field })
	_ => crash "expected a signal bool descriptor"
}

native_event : Str, Node.Msg, [None, Some(Node.KeyChord)] -> Node.Attr
native_event = |name, msg, key_chord| Node.Attr.On({
	kind: { id: 0 },
	name,
	msg,
	policy: { ..Html.event_policy_none, prevent_default: True, stop_propagation: True },
	delivery: Html.event_delivery_native,
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
		Some(value) => [Html.aria_label(value)]
		None => []
	}
	test_id = match common.test_id {
		Some(value) => [Html.test_id(value)]
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

## Native controls and presentation over the shared Signals engine.
## Styles are typed native properties, independent of CSS and semantic locators.
##
## Every control takes one props record whose fields all have defaults, so a
## literal names only what it changes: `Gui.column({ test_id: "count", gap: 4 }, children)`.
## The style fields carry that control's own presentation defaults. Optional
## attributes such as `test_id`, `selected`, or `on_drop` cost nothing when
## omitted. A `changes` signal supplies the whole style reactively; each value
## it publishes replaces the static style fields wholesale.
## A props record built outside the call, or inside a `Signal.map` transform,
## needs an explicit type, such as `Gui.PanelProps.{ ... }`, because only a
## literal passed directly to the control absorbs the defaults.
Gui := [].{
	## Native presentation record with defaults for every field. Use it for
	## `changes` signals: `signal.map(|value| Gui.Style.{ padding: 12 })`.
	## Zero font size and Default colors inherit from the host. Dimensions,
	## spacing and font size are logical pixels, bounded at 16384.
	Style := {
		gap : U32 ?? 8,
		padding : U32 ?? 0,
		width : Length ?? Auto,
		height : Length ?? Auto,
		grow : Bool ?? False,
		background : Color ?? Default,
		hover_background : Color ?? Default,
		active_background : Color ?? Default,
		foreground : Color ?? Default,
		border_color : Color ?? Default,
		border_width : U32 ?? 0,
		radius : U32 ?? 0,
		font_size : U32 ?? 0,
		overflow_x : Overflow ?? Visible,
		overflow_y : Overflow ?? Visible,
	}.{
		is_eq : _
	}
	## A logical-pixel dimension. A number literal in a `Length` position is
	## pixels, written explicitly as `380.Px`; `Px(380)` is the same value.
	Length := [Auto, Fill, Px(U32)].{
		is_eq : _

		from_numeral : Numeral -> Try(Length, [InvalidNumeral(Str)])
		from_numeral = |numeral| {
			Pixels : U32
			match Pixels.from_numeral(numeral) {
				Ok(value) => Ok(Px(value))
				Err(err) => Err(err)
			}
		}
	}

	## Types a number literal as pixels: `width: 380.Px`.
	Px : Length
	Color : Color
	Overflow : Overflow
	Msg : Node.Msg
	Cmd : Node.Cmd
	KeyChord : Node.KeyChord

	## Props for `column`. Neutral presentation.
	## The style fields are the same as `Style`; their defaults are this control's
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
	## accepts a live drag through `Ui.action_detail` or `State.on_detail`.
	ColumnProps := {
		label ?: Str,
		gap : U32 ?? 8,
		padding : U32 ?? 0,
		width : Length ?? Auto,
		height : Length ?? Auto,
		grow : Bool ?? False,
		background : Color ?? Default,
		hover_background : Color ?? Default,
		active_background : Color ?? Default,
		foreground : Color ?? Default,
		border_color : Color ?? Default,
		border_width : U32 ?? 0,
		radius : U32 ?? 0,
		font_size : U32 ?? 0,
		overflow_x : Overflow ?? Visible,
		overflow_y : Overflow ?? Visible,
		changes ?: Signal(Style),
		test_id ?: Str,
		font_family ?: Str,
		embedded_fonts : List({ family : Str, bytes : List(U8) }) ?? [],
		selected ?: Signal(Bool),
		enabled ?: Signal(Bool),
		disabled ?: Signal(Bool),
		shortcuts : List({ chord : Node.KeyChord, msg : Node.Msg }) ?? [],
		drag_source ?: Str,
		on_drop ?: Node.Msg,
	}

	## Props for `row`. Neutral presentation; see `ColumnProps` for the attributes.
	RowProps := {
		label ?: Str,
		gap : U32 ?? 8,
		padding : U32 ?? 0,
		width : Length ?? Auto,
		height : Length ?? Auto,
		grow : Bool ?? False,
		background : Color ?? Default,
		hover_background : Color ?? Default,
		active_background : Color ?? Default,
		foreground : Color ?? Default,
		border_color : Color ?? Default,
		border_width : U32 ?? 0,
		radius : U32 ?? 0,
		font_size : U32 ?? 0,
		overflow_x : Overflow ?? Visible,
		overflow_y : Overflow ?? Visible,
		changes ?: Signal(Style),
		test_id ?: Str,
		font_family ?: Str,
		embedded_fonts : List({ family : Str, bytes : List(U8) }) ?? [],
		selected ?: Signal(Bool),
		enabled ?: Signal(Bool),
		disabled ?: Signal(Bool),
		shortcuts : List({ chord : Node.KeyChord, msg : Node.Msg }) ?? [],
		drag_source ?: Str,
		on_drop ?: Node.Msg,
	}

	## Props for `panel`: padded, bordered, and rounded by default. See
	## `ColumnProps` for the attributes.
	PanelProps := {
		label ?: Str,
		gap : U32 ?? 8,
		padding : U32 ?? 16,
		width : Length ?? Auto,
		height : Length ?? Auto,
		grow : Bool ?? False,
		background : Color ?? Default,
		hover_background : Color ?? Default,
		active_background : Color ?? Default,
		foreground : Color ?? Default,
		border_color : Color ?? Rgb(4743275),
		border_width : U32 ?? 1,
		radius : U32 ?? 8,
		font_size : U32 ?? 0,
		overflow_x : Overflow ?? Visible,
		overflow_y : Overflow ?? Visible,
		changes ?: Signal(Style),
		test_id ?: Str,
		font_family ?: Str,
		embedded_fonts : List({ family : Str, bytes : List(U8) }) ?? [],
		selected ?: Signal(Bool),
		enabled ?: Signal(Bool),
		disabled ?: Signal(Bool),
		shortcuts : List({ chord : Node.KeyChord, msg : Node.Msg }) ?? [],
		drag_source ?: Str,
		on_drop ?: Node.Msg,
	}

	## Props for `dialog`. `label` names the dialog and `on_dismiss` receives the
	## Escape shortcut. See `ColumnProps` for the other attributes.
	DialogProps := {
		label : Str,
		on_dismiss : Node.Msg,
		gap : U32 ?? 16,
		padding : U32 ?? 24,
		width : Length ?? Px(520),
		height : Length ?? Auto,
		grow : Bool ?? False,
		background : Color ?? Rgb(2174263),
		hover_background : Color ?? Default,
		active_background : Color ?? Default,
		foreground : Color ?? Rgb(15658730),
		border_color : Color ?? Rgb(4743275),
		border_width : U32 ?? 1,
		radius : U32 ?? 8,
		font_size : U32 ?? 0,
		overflow_x : Overflow ?? Visible,
		overflow_y : Overflow ?? Visible,
		changes ?: Signal(Style),
		test_id ?: Str,
		font_family ?: Str,
		embedded_fonts : List({ family : Str, bytes : List(U8) }) ?? [],
		selected ?: Signal(Bool),
		enabled ?: Signal(Bool),
		disabled ?: Signal(Bool),
		shortcuts : List({ chord : Node.KeyChord, msg : Node.Msg }) ?? [],
		drag_source ?: Str,
		on_drop ?: Node.Msg,
	}

	## Props for `virtual_list`. `row_height` is the fixed logical row height,
	## and `follow_tail` keeps the final row in view as history grows. See
	## `ColumnProps` for the other attributes.
	VirtualListProps := {
		row_height : U32,
		follow_tail : Signal(Bool),
		label ?: Str,
		gap : U32 ?? 8,
		padding : U32 ?? 0,
		width : Length ?? Fill,
		height : Length ?? Px(480),
		grow : Bool ?? True,
		background : Color ?? Default,
		hover_background : Color ?? Default,
		active_background : Color ?? Default,
		foreground : Color ?? Default,
		border_color : Color ?? Default,
		border_width : U32 ?? 0,
		radius : U32 ?? 0,
		font_size : U32 ?? 0,
		overflow_x : Overflow ?? Visible,
		overflow_y : Overflow ?? Visible,
		changes ?: Signal(Style),
		test_id ?: Str,
		font_family ?: Str,
		embedded_fonts : List({ family : Str, bytes : List(U8) }) ?? [],
		selected ?: Signal(Bool),
		enabled ?: Signal(Bool),
		disabled ?: Signal(Bool),
		shortcuts : List({ chord : Node.KeyChord, msg : Node.Msg }) ?? [],
		drag_source ?: Str,
		on_drop ?: Node.Msg,
	}

	## Props for `image`. `source` is a relative path inside the host's assets
	## root and `label` is the picture's semantic name. See `ColumnProps` for the
	## other attributes.
	ImageProps := {
		source : Str,
		label : Str,
		gap : U32 ?? 8,
		padding : U32 ?? 0,
		width : Length ?? Auto,
		height : Length ?? Auto,
		grow : Bool ?? False,
		background : Color ?? Default,
		hover_background : Color ?? Default,
		active_background : Color ?? Default,
		foreground : Color ?? Default,
		border_color : Color ?? Default,
		border_width : U32 ?? 0,
		radius : U32 ?? 0,
		font_size : U32 ?? 0,
		overflow_x : Overflow ?? Visible,
		overflow_y : Overflow ?? Visible,
		changes ?: Signal(Style),
		test_id ?: Str,
		font_family ?: Str,
		embedded_fonts : List({ family : Str, bytes : List(U8) }) ?? [],
		selected ?: Signal(Bool),
		enabled ?: Signal(Bool),
		disabled ?: Signal(Bool),
		shortcuts : List({ chord : Node.KeyChord, msg : Node.Msg }) ?? [],
		drag_source ?: Str,
		on_drop ?: Node.Msg,
	}

	## Props for `action_button`. `caption` is the live button text, `label` an
	## optional semantic name that replaces the caption for locators, and
	## `enabled` defaults to always enabled. The style defaults are the button's
	## own colors. See `ColumnProps` for the other attributes.
	ActionButtonProps := {
		caption : Signal(Str),
		label ?: Str,
		gap : U32 ?? 8,
		padding : U32 ?? 8,
		width : Length ?? Auto,
		height : Length ?? Auto,
		grow : Bool ?? False,
		background : Color ?? Rgb(3232873),
		hover_background : Color ?? Rgb(0x3F6175),
		active_background : Color ?? Rgb(0x2B4452),
		foreground : Color ?? Default,
		border_color : Color ?? Default,
		border_width : U32 ?? 0,
		radius : U32 ?? 6,
		font_size : U32 ?? 0,
		overflow_x : Overflow ?? Visible,
		overflow_y : Overflow ?? Visible,
		changes ?: Signal(Style),
		test_id ?: Str,
		font_family ?: Str,
		embedded_fonts : List({ family : Str, bytes : List(U8) }) ?? [],
		selected ?: Signal(Bool),
		enabled : Signal(Bool) ?? Signal.const(True),
		disabled ?: Signal(Bool),
		shortcuts : List({ chord : Node.KeyChord, msg : Node.Msg }) ?? [],
		drag_source ?: Str,
		on_drop ?: Node.Msg,
	}

	## Props for `text_input`. `label` is the field's semantic name, `value` its
	## controlled text, and `placeholder` an explicit empty-field hint. See
	## `ColumnProps` for the other attributes.
	TextInputProps := {
		label : Str,
		value : Signal(Str),
		placeholder ?: Str,
		gap : U32 ?? 8,
		padding : U32 ?? 0,
		width : Length ?? Auto,
		height : Length ?? Auto,
		grow : Bool ?? False,
		background : Color ?? Default,
		hover_background : Color ?? Default,
		active_background : Color ?? Default,
		foreground : Color ?? Default,
		border_color : Color ?? Default,
		border_width : U32 ?? 0,
		radius : U32 ?? 0,
		font_size : U32 ?? 0,
		overflow_x : Overflow ?? Visible,
		overflow_y : Overflow ?? Visible,
		changes ?: Signal(Style),
		test_id ?: Str,
		font_family ?: Str,
		embedded_fonts : List({ family : Str, bytes : List(U8) }) ?? [],
		selected ?: Signal(Bool),
		enabled ?: Signal(Bool),
		disabled ?: Signal(Bool),
		shortcuts : List({ chord : Node.KeyChord, msg : Node.Msg }) ?? [],
		drag_source ?: Str,
		on_drop ?: Node.Msg,
	}

	## Props for `textarea`; the fields match `TextInputProps`.
	TextareaProps := {
		label : Str,
		value : Signal(Str),
		placeholder ?: Str,
		gap : U32 ?? 8,
		padding : U32 ?? 0,
		width : Length ?? Auto,
		height : Length ?? Auto,
		grow : Bool ?? False,
		background : Color ?? Default,
		hover_background : Color ?? Default,
		active_background : Color ?? Default,
		foreground : Color ?? Default,
		border_color : Color ?? Default,
		border_width : U32 ?? 0,
		radius : U32 ?? 0,
		font_size : U32 ?? 0,
		overflow_x : Overflow ?? Visible,
		overflow_y : Overflow ?? Visible,
		changes ?: Signal(Style),
		test_id ?: Str,
		font_family ?: Str,
		embedded_fonts : List({ family : Str, bytes : List(U8) }) ?? [],
		selected ?: Signal(Bool),
		enabled ?: Signal(Bool),
		disabled ?: Signal(Bool),
		shortcuts : List({ chord : Node.KeyChord, msg : Node.Msg }) ?? [],
		drag_source ?: Str,
		on_drop ?: Node.Msg,
	}

	## Props for `checkbox`. `label` is the semantic name and `checked` the
	## controlled state. See `ColumnProps` for the other attributes.
	CheckboxProps := {
		label : Str,
		checked : Signal(Bool),
		gap : U32 ?? 8,
		padding : U32 ?? 0,
		width : Length ?? Auto,
		height : Length ?? Auto,
		grow : Bool ?? False,
		background : Color ?? Default,
		hover_background : Color ?? Default,
		active_background : Color ?? Default,
		foreground : Color ?? Default,
		border_color : Color ?? Default,
		border_width : U32 ?? 0,
		radius : U32 ?? 0,
		font_size : U32 ?? 0,
		overflow_x : Overflow ?? Visible,
		overflow_y : Overflow ?? Visible,
		changes ?: Signal(Style),
		test_id ?: Str,
		font_family ?: Str,
		embedded_fonts : List({ family : Str, bytes : List(U8) }) ?? [],
		selected ?: Signal(Bool),
		enabled ?: Signal(Bool),
		disabled ?: Signal(Bool),
		shortcuts : List({ chord : Node.KeyChord, msg : Node.Msg }) ?? [],
		drag_source ?: Str,
		on_drop ?: Node.Msg,
	}

	## Lay out children horizontally.
	row : RowProps, List(Elem) -> Elem
	row = |p, children| Html.div(lower_common(0, { style: Style.{ gap: p.gap, padding: p.padding, width: p.width, height: p.height, grow: p.grow, background: p.background, hover_background: p.hover_background, active_background: p.active_background, foreground: p.foreground, border_color: p.border_color, border_width: p.border_width, radius: p.radius, font_size: p.font_size, overflow_x: p.overflow_x, overflow_y: p.overflow_y }, changes: opt(p.?changes), test_id: opt(p.?test_id), font_family: opt(p.?font_family), embedded_fonts: p.embedded_fonts, selected: opt(p.?selected), enabled: opt(p.?enabled), disabled: opt(p.?disabled), shortcuts: p.shortcuts, drag_source: opt(p.?drag_source), on_drop: opt(p.?on_drop), label: opt(p.?label), placeholder: None }), children)

	## Lay out children vertically.
	column : ColumnProps, List(Elem) -> Elem
	column = |p, children| Html.div(lower_common(1, { style: Style.{ gap: p.gap, padding: p.padding, width: p.width, height: p.height, grow: p.grow, background: p.background, hover_background: p.hover_background, active_background: p.active_background, foreground: p.foreground, border_color: p.border_color, border_width: p.border_width, radius: p.radius, font_size: p.font_size, overflow_x: p.overflow_x, overflow_y: p.overflow_y }, changes: opt(p.?changes), test_id: opt(p.?test_id), font_family: opt(p.?font_family), embedded_fonts: p.embedded_fonts, selected: opt(p.?selected), enabled: opt(p.?enabled), disabled: opt(p.?disabled), shortcuts: p.shortcuts, drag_source: opt(p.?drag_source), on_drop: opt(p.?on_drop), label: opt(p.?label), placeholder: None }), children)

	## Group content in a padded, bordered vertical panel.
	panel : PanelProps, List(Elem) -> Elem
	panel = |p, children| Html.div(lower_common(1, { style: Style.{ gap: p.gap, padding: p.padding, width: p.width, height: p.height, grow: p.grow, background: p.background, hover_background: p.hover_background, active_background: p.active_background, foreground: p.foreground, border_color: p.border_color, border_width: p.border_width, radius: p.radius, font_size: p.font_size, overflow_x: p.overflow_x, overflow_y: p.overflow_y }, changes: opt(p.?changes), test_id: opt(p.?test_id), font_family: opt(p.?font_family), embedded_fonts: p.embedded_fonts, selected: opt(p.?selected), enabled: opt(p.?enabled), disabled: opt(p.?disabled), shortcuts: p.shortcuts, drag_source: opt(p.?drag_source), on_drop: opt(p.?on_drop), label: opt(p.?label), placeholder: None }), children)

	## A native close request enters the ordinary event graph. KeepOpen cancels
	## it, AwaitDecision retains one pending request, and Close completes that
	## request after the decision's transaction commits. Close without a pending
	## request has no effect. Declare exactly one wrapper directly under the app
	## root; disposing or replacing it cancels its pending request.
	CloseDecision : [KeepOpen, AwaitDecision, Close]

	window_lifecycle : { on_close_requested : Msg, decision : Signal(CloseDecision) }, List(Elem) -> Elem
	window_lifecycle = |props, children| {
		policy = props.decision.map(
			|decision| match decision {
				KeepOpen => "keep-open"
				AwaitDecision => "await-decision"
				Close => "close"
			},
		)
		Elem.Element({
			namespace: Html,
			tag: "window",
			attrs: [
				style_attr(1, Style.{ width: Fill, height: Fill }),
				signal_text(native_window_close_field, policy),
				Node.Attr.On({
					kind: { id: 0 },
					name: "close-requested",
					msg: props.on_close_requested,
					policy: Html.event_policy_none,
					delivery: Html.event_delivery_native,
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
		common = { style: Style.{ gap: p.gap, padding: p.padding, width: p.width, height: p.height, grow: p.grow, background: p.background, hover_background: p.hover_background, active_background: p.active_background, foreground: p.foreground, border_color: p.border_color, border_width: p.border_width, radius: p.radius, font_size: p.font_size, overflow_x: p.overflow_x, overflow_y: p.overflow_y }, changes: opt(p.?changes), test_id: opt(p.?test_id), font_family: opt(p.?font_family), embedded_fonts: p.embedded_fonts, selected: opt(p.?selected), enabled: opt(p.?enabled), disabled: opt(p.?disabled), shortcuts: p.shortcuts, drag_source: opt(p.?drag_source), on_drop: opt(p.?on_drop), label: Some(p.label), placeholder: None }
		Elem.Element({
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
		Html.div(lower_common(1, { style: Style.{ gap: p.gap, padding: p.padding, width: p.width, height: p.height, grow: p.grow, background: p.background, hover_background: p.hover_background, active_background: p.active_background, foreground: p.foreground, border_color: p.border_color, border_width: p.border_width, radius: p.radius, font_size: p.font_size, overflow_x: p.overflow_x, overflow_y: p.overflow_y }, changes: opt(p.?changes), test_id: opt(p.?test_id), font_family: opt(p.?font_family), embedded_fonts: p.embedded_fonts, selected: opt(p.?selected), enabled: opt(p.?enabled), disabled: opt(p.?disabled), shortcuts: p.shortcuts, drag_source: opt(p.?drag_source), on_drop: opt(p.?on_drop), label: opt(p.?label), placeholder: None }).append(signal_text(native_viewport_field, encoded)), children)
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
		Elem.Element({
			namespace: Html,
			tag: "img",
			attrs: lower_common(1, { style: Style.{ gap: p.gap, padding: p.padding, width: p.width, height: p.height, grow: p.grow, background: p.background, hover_background: p.hover_background, active_background: p.active_background, foreground: p.foreground, border_color: p.border_color, border_width: p.border_width, radius: p.radius, font_size: p.font_size, overflow_x: p.overflow_x, overflow_y: p.overflow_y }, changes: opt(p.?changes), test_id: opt(p.?test_id), font_family: opt(p.?font_family), embedded_fonts: p.embedded_fonts, selected: opt(p.?selected), enabled: opt(p.?enabled), disabled: opt(p.?disabled), shortcuts: p.shortcuts, drag_source: opt(p.?drag_source), on_drop: opt(p.?on_drop), label: Some(p.label), placeholder: None }).append(Node.Attr.StaticText({ field: native_image_source_field, name: "", value: p.source })),
			children: [],
		})
	}

	## Render a prominent heading.
	heading : Str -> Elem
	heading = |value| Html.heading(value)

	## Render literal text without interpreting markup.
	text : Str -> Elem
	text = |value| Html.text(value)

	## Render only the text changes published by this signal.
	text_s : Signal(Str) -> Elem
	text_s = |value| Html.text_s(value)

	## Create an enabled button with a static label for a unit action. Use
	## `action_button` for a styled button or one whose caption or availability
	## changes.
	button : Str, Msg -> Elem
	button = |value, message| Html.button(value, message)

	## Create a button whose caption and availability change independently.
	action_button : ActionButtonProps, Msg -> Elem
	action_button = |p, message|
		Html.action_button_attrs(p.caption, p.enabled.map(|is_enabled| !is_enabled), lower_common(1, { style: Style.{ gap: p.gap, padding: p.padding, width: p.width, height: p.height, grow: p.grow, background: p.background, hover_background: p.hover_background, active_background: p.active_background, foreground: p.foreground, border_color: p.border_color, border_width: p.border_width, radius: p.radius, font_size: p.font_size, overflow_x: p.overflow_x, overflow_y: p.overflow_y }, changes: opt(p.?changes), test_id: opt(p.?test_id), font_family: opt(p.?font_family), embedded_fonts: p.embedded_fonts, selected: opt(p.?selected), enabled: None, disabled: opt(p.?disabled), shortcuts: p.shortcuts, drag_source: opt(p.?drag_source), on_drop: opt(p.?on_drop), label: opt(p.?label), placeholder: None }), message)

	## Edit one controlled line; the label is a semantic name, not placeholder text.
	text_input : TextInputProps, Msg -> Elem
	text_input = |p, message|
		Html.text_input_attrs(p.label, p.value, lower_common(1, { style: Style.{ gap: p.gap, padding: p.padding, width: p.width, height: p.height, grow: p.grow, background: p.background, hover_background: p.hover_background, active_background: p.active_background, foreground: p.foreground, border_color: p.border_color, border_width: p.border_width, radius: p.radius, font_size: p.font_size, overflow_x: p.overflow_x, overflow_y: p.overflow_y }, changes: opt(p.?changes), test_id: opt(p.?test_id), font_family: opt(p.?font_family), embedded_fonts: p.embedded_fonts, selected: opt(p.?selected), enabled: opt(p.?enabled), disabled: opt(p.?disabled), shortcuts: p.shortcuts, drag_source: opt(p.?drag_source), on_drop: opt(p.?on_drop), label: None, placeholder: opt(p.?placeholder) }), message)

	## Edit controlled text with hard line breaks and a retained selection.
	## An explicit height includes caption and padding; the editor fills the rest.
	## Auto height retains a 320-pixel editing viewport.
	textarea : TextareaProps, Msg -> Elem
	textarea = |p, message|
		Html.textarea_attrs(p.label, p.value, lower_common(1, { style: Style.{ gap: p.gap, padding: p.padding, width: p.width, height: p.height, grow: p.grow, background: p.background, hover_background: p.hover_background, active_background: p.active_background, foreground: p.foreground, border_color: p.border_color, border_width: p.border_width, radius: p.radius, font_size: p.font_size, overflow_x: p.overflow_x, overflow_y: p.overflow_y }, changes: opt(p.?changes), test_id: opt(p.?test_id), font_family: opt(p.?font_family), embedded_fonts: p.embedded_fonts, selected: opt(p.?selected), enabled: opt(p.?enabled), disabled: opt(p.?disabled), shortcuts: p.shortcuts, drag_source: opt(p.?drag_source), on_drop: opt(p.?on_drop), label: None, placeholder: opt(p.?placeholder) }), message)

	## Toggle a controlled boolean using the ordinary checked-value event route.
	checkbox : CheckboxProps, Msg -> Elem
	checkbox = |p, message|
		Html.checkbox_attrs(p.label, p.checked, lower_common(0, { style: Style.{ gap: p.gap, padding: p.padding, width: p.width, height: p.height, grow: p.grow, background: p.background, hover_background: p.hover_background, active_background: p.active_background, foreground: p.foreground, border_color: p.border_color, border_width: p.border_width, radius: p.radius, font_size: p.font_size, overflow_x: p.overflow_x, overflow_y: p.overflow_y }, changes: opt(p.?changes), test_id: opt(p.?test_id), font_family: opt(p.?font_family), embedded_fonts: p.embedded_fonts, selected: opt(p.?selected), enabled: opt(p.?enabled), disabled: opt(p.?disabled), shortcuts: p.shortcuts, drag_source: opt(p.?drag_source), on_drop: opt(p.?on_drop), label: None, placeholder: None }), message)
}

## The native default encoding is a canonical v2 record shared with the Zig decoder.
expect encode_style(1, Gui.Style.{}) == "2,1,8,0,0,0,0,0,0,16777216,16777216,16777216,16777216,16777216,0,0,0,0,0"

## A column props literal keeps the neutral style and lowers only present attributes.
expect {
	attrs = Gui.column({ test_id: "root", padding: 4 }, [])
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
