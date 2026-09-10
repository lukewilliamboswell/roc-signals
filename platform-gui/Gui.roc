import Elem exposing [Elem]
import Html
import Node
import Signal exposing [Signal]

Length : [Auto, Fill, Px(U32)]

Color : [Default, Rgb(U32)]

Overflow : [Visible, Clip, Scroll]

Presentation : {
	gap : U32,
	padding : U32,
	width : Length,
	height : Length,
	grow : Bool,
	background : Color,
	hover_background : Color,
	active_background : Color,
	foreground : Color,
	border_color : Color,
	border_width : U32,
	radius : U32,
	font_size : U32,
	overflow_x : Overflow,
	overflow_y : Overflow,
}

Attribute := [
	Presentation(Presentation),
	PresentationSignal(Signal(Presentation)),
	Label(Str),
	Placeholder(Str),
	FontFamily(Str),
	EmbeddedFonts(List({ family : Str, bytes : List(U8) })),
	TestId(Str),
	Selected(Signal(Bool)),
	Enabled(Signal(Bool)),
	Shortcut(Node.KeyChord, Node.Msg),
	DragSource(Str),
	DropTarget(Node.Msg),
]

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

dimension : Length -> { kind : U32, value : U32 }
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
encode_style : U32, Presentation -> Str
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

style_attr : U32, Presentation -> Node.Attr
style_attr = |direction, style| Node.Attr.StaticText({ field: native_style_field, name: "", value: encode_style(direction, style) })

lower_attrs : U32, Presentation, List(Attribute) -> List(Node.Attr)
lower_attrs = |direction, defaults, attrs| {
	styles = attrs.keep_if(
		|attr| match attr {
			Attribute.Presentation(_) => True
			Attribute.PresentationSignal(_) => True
			_ => False
		},
	)
	if styles.len() > 1 {
		crash "Gui element accepts one style attribute"
	}
	initial = if styles.is_empty() {
		[style_attr(direction, defaults)]
	} else {
		[]
	}
	drop_targets = attrs.keep_if(
		|attr| match attr {
			Attribute.DropTarget(_) => True
			_ => False
		},
	)
	with_drop = if drop_targets.is_empty() {
		initial
	} else {
		initial.append(Node.Attr.StaticBool({ field: native_drop_target_field, name: "", value: True }))
	}
	with_drop.concat(
		attrs.map(
			|attr| match attr {
				Attribute.Presentation(value) => style_attr(direction, value)
				Attribute.PresentationSignal(value) => {
					text = value.map(|style| encode_style(direction, style))
					# Html provides the same capability-owned text sink construction.
					match Html.attr_s("", text) {
						Node.Attr.SignalText(payload) => Node.Attr.SignalText({ ..payload, field: native_style_field })
						_ => crash "expected a signal text descriptor"
					}
				}
				Attribute.Label(value) => Html.aria_label(value)
				Attribute.Placeholder(value) => Node.Attr.StaticText({ field: native_placeholder_field, name: "", value })
				Attribute.FontFamily(value) => Node.Attr.StaticText({ field: native_font_family_field, name: "", value })
				Attribute.EmbeddedFonts(fonts) => Node.Attr.StaticText({ field: native_fonts_field, name: "", value: encode_fonts(fonts) })
				Attribute.TestId(value) => Html.test_id(value)
				Attribute.Selected(value) => match Html.bool_attr_s("", value) {
					Node.Attr.SignalBool(payload) => Node.Attr.SignalBool({ ..payload, field: selected_field })
					_ => crash "expected a signal bool descriptor"
				}
				Attribute.Enabled(value) => match Html.bool_attr_s("", value.map(|enabled| !enabled)) {
					Node.Attr.SignalBool(payload) => Node.Attr.SignalBool({ ..payload, field: disabled_field })
					_ => crash "expected a signal bool descriptor"
				}
				Attribute.DragSource(key) => Node.Attr.StaticText({ field: native_drag_key_field, name: "", value: key })
				Attribute.DropTarget(msg) => Node.Attr.On({
					kind: { id: 0 },
					name: "drop",
					msg,
					policy: { ..Html.event_policy_none, prevent_default: True, stop_propagation: True },
					delivery: Html.event_delivery_native,
					key_chord: None,
				})
				Attribute.Shortcut(chord, msg) => Node.Attr.On({
					kind: { id: 0 },
					name: "keydown",
					msg,
					policy: { ..Html.event_policy_none, prevent_default: True, stop_propagation: True },
					delivery: Html.event_delivery_native,
					key_chord: Some(chord),
				})
			},
		),
	)
}

## Native controls and presentation over the shared Signals engine.
## Styles are typed native properties, independent of CSS and semantic locators.
Gui := [].{
	Attr : Attribute
	Style : Presentation
	Length : Length
	Color : Color
	Overflow : Overflow
	Msg : Node.Msg
	Cmd : Node.Cmd
	KeyChord : Node.KeyChord

	## Offer a bounded application key for an internal drag. The native adapter
	## separately validates source lifetime; this key never creates UI identity.
	drag_source : Str -> Attr
	drag_source = |key| {
		if key.is_empty() or key.to_utf8().len() > 256 {
			crash "Gui drag key must contain 1 to 256 UTF-8 bytes"
		}
		Attribute.DragSource(key)
	}

	## Accept a live internal drag through Ui.action_detail or State.on_detail.
	## The message receives the source key. Keep explicit move controls available.
	drop_target : Msg -> Attr
	drop_target = |message| Attribute.DropTarget(message)

	## Set the window identity shown by the desktop switcher and the titlebar.
	## The command travels the ordinary propagation path, so an unchanged title
	## is pruned before it reaches the window. Give the application a stable
	## name, and fold the open document and its unsaved state into the same
	## string when they are meaningful, as `"* Notes - draft"`.
	set_title : Str -> Cmd
	set_title = |title| Node.Cmd.SetDocumentTitle({ title: title })

	## Bind an exact key and all modifiers within this focused region. The nearest
	## matching ancestor receives one unit event and consumes the keystroke.
	## Letters are lowercase a-z; digits and the documented named keys are valid.
	## Duplicate chords and more than 32 shortcuts on one element are errors.
	on_shortcut : KeyChord, Msg -> Attr
	on_shortcut = |chord, message| Attribute.Shortcut(chord, message)

	## Neutral column presentation. Zero font size and Default colors inherit.
	## Dimensions, spacing and font size are logical pixels, bounded at 16384.
	style_default : Style
	style_default = {
		gap: 8,
		padding: 0,
		width: Auto,
		height: Auto,
		grow: False,
		background: Default,
		hover_background: Default,
		active_background: Default,
		foreground: Default,
		border_color: Default,
		border_width: 0,
		radius: 0,
		font_size: 0,
		overflow_x: Visible,
		overflow_y: Visible,
	}

	## Apply a complete presentation record. Each element accepts one style.
	style : Style -> Attr
	style = |value| Attribute.Presentation(value)

	## Update presentation through ordinary equality-pruned signal propagation.
	style_s : Signal(Style) -> Attr
	style_s = |value| Attribute.PresentationSignal(value)

	## Give a control or region a stable semantic test locator.
	test_id : Str -> Attr
	test_id = |value| Attribute.TestId(value)

	## Give a control or region a semantic name, independent of its styling.
	label : Str -> Attr
	label = |value| Attribute.Label(value)

	## Show an empty-field hint inside a text control. The hint is explicit
	## static text; the host never derives one from a label or a default.
	placeholder : Str -> Attr
	placeholder = |value| Attribute.Placeholder(value)

	## Render this element and its descendants with a named font family. The
	## family must be available to the native text system: either installed on
	## the machine or registered at startup through `embedded_fonts`. Text
	## styles inherit, so descendants without their own family use this one.
	font_family : Str -> Attr
	font_family = |value| Attribute.FontFamily(value)

	## Register embedded fonts with the native text system at startup. Declare
	## exactly one list on the app's root element; the bytes come from a
	## compile-time `import "font.ttf" as name : List(U8)`. The host registers
	## each family once and rejects more than 8 fonts or fonts over 8 MiB with
	## a visible host error. Re-publishing identical data never re-registers.
	embedded_fonts : List({ family : Str, bytes : List(U8) }) -> Attr
	embedded_fonts = |fonts| Attribute.EmbeddedFonts(fonts)

	## Mark selection independently of checkbox state or application identity.
	selected_s : Signal(Bool) -> Attr
	selected_s = |value| Attribute.Selected(value)

	## Enable or disable an input or control from a signal.
	enabled_s : Signal(Bool) -> Attr
	enabled_s = |value| Attribute.Enabled(value)

	## Disable an input or control while retaining its native identity.
	disabled_s : Signal(Bool) -> Attr
	disabled_s = |value| Attribute.Enabled(value.map(|disabled| !disabled))

	## Lay out children horizontally with the supplied native presentation.
	row : List(Attr), List(Elem) -> Elem
	row = |attrs, children| Html.div(lower_attrs(0, style_default, attrs), children)

	## Lay out children vertically with the supplied native presentation.
	column : List(Attr), List(Elem) -> Elem
	column = |attrs, children| Html.div(lower_attrs(1, style_default, attrs), children)

	## Group content in a padded, bordered vertical panel. A style replaces defaults.
	panel : List(Attr), List(Elem) -> Elem
	panel = |attrs, children| Html.div(lower_attrs(1, { ..style_default, padding: 16, border_width: 1, radius: 8, border_color: Rgb(4743275) }, attrs), children)

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
		policy_attr = match Html.attr_s("", policy) {
			Node.Attr.SignalText(payload) => Node.Attr.SignalText({ ..payload, field: native_window_close_field })
			_ => crash "expected a signal text descriptor"
		}
		Elem.Element({
			namespace: Html,
			tag: "window",
			attrs: [
				style_attr(1, { ..style_default, width: Fill, height: Fill }),
				policy_attr,
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
	dialog : { label : Str, on_dismiss : Msg }, List(Attr), List(Elem) -> Elem
	dialog = |props, attrs, children| Elem.Element({
		namespace: Html,
		tag: "dialog",
		attrs: lower_attrs(
			1,
			{ ..style_default, padding: 24, gap: 16, width: Px(520), background: Rgb(2174263), foreground: Rgb(15658730), border_width: 1, border_color: Rgb(4743275), radius: 8 },
			[
				Attribute.Label(props.label),
				Attribute.Shortcut({ key: "Escape", control: False, shift: False, alt: False, meta: False }, props.on_dismiss),
			].concat(attrs),
		),
		children,
	})

	## Presents direct child rows at a fixed logical height, creating GPUI layout
	## only for the visible range. Child scopes remain owned by ordinary Ui.each.
	## With follow_tail enabled, new history keeps the final row in view.
	virtual_list : { row_height : U32, follow_tail : Signal(Bool) }, List(Attr), List(Elem) -> Elem
	virtual_list = |props, attrs, children| {
		if props.row_height == 0 or props.row_height > 16384 {
			crash "Gui virtual row height must be between 1 and 16384"
		}
		encoded = props.follow_tail.map(
			|follow| "1,${props.row_height.to_str()},${
				if follow {
					"1"
				} else {
					"0"
				}
			}",
		)
		viewport = match Html.attr_s("", encoded) {
			Node.Attr.SignalText(payload) => Node.Attr.SignalText({ ..payload, field: native_viewport_field })
			_ => crash "expected a signal text descriptor"
		}
		Html.div(lower_attrs(1, { ..style_default, width: Fill, height: Px(480), grow: True }, attrs).append(viewport), children)
	}

	## Render an image from a relative path inside the host's assets root.
	## Absolute paths, `..` traversal, and URIs never resolve; a missing or
	## undecodable source renders a neutral placeholder box of the styled size.
	## The label is a semantic name for the picture, never derived by the host.
	image : { source : Str, label : Str }, List(Attr) -> Elem
	image = |props, attrs| {
		if props.source.is_empty() or props.source.to_utf8().len() > 1024 {
			crash "Gui image sources contain 1 to 1024 UTF-8 bytes"
		}
		Elem.Element({
			namespace: Html,
			tag: "img",
			attrs: lower_attrs(1, style_default, [Attribute.Label(props.label)].concat(attrs)).append(Node.Attr.StaticText({ field: native_image_source_field, name: "", value: props.source })),
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

	## Create an enabled button for a unit action.
	button : Str, Msg -> Elem
	button = |value, message| Html.button(value, message)

	## Create a static-label button that accepts native attributes: a style,
	## test id, label, selected and enabled signals, and shortcuts, like every
	## other control. A supplied style replaces the button's complete default
	## record, including its hover and active backgrounds.
	button_attrs : Str, List(Attr), Msg -> Elem
	button_attrs = |value, attrs, message|
		Html.button_attrs(value, lower_attrs(1, { ..style_default, padding: 8, radius: 6, background: Rgb(3232873), hover_background: Rgb(0x3F6175), active_background: Rgb(0x2B4452) }, attrs), message)

	## Create a button whose label and availability change independently.
	action_button : { label : Signal(Str), enabled : Signal(Bool) }, List(Attr), Msg -> Elem
	action_button = |props, attrs, message|
		Html.action_button_attrs(props.label, props.enabled.map(|enabled| !enabled), lower_attrs(1, { ..style_default, padding: 8, radius: 6, background: Rgb(3232873), hover_background: Rgb(0x3F6175), active_background: Rgb(0x2B4452) }, attrs), message)

	## Edit one controlled line; the label is a semantic name, not placeholder text.
	text_input : { label : Str, value : Signal(Str) }, List(Attr), Msg -> Elem
	text_input = |props, attrs, message|
		Html.text_input_attrs(props.label, props.value, lower_attrs(1, style_default, attrs), message)

	## Edit controlled text with hard line breaks and a retained selection.
	## An explicit height includes caption and padding; the editor fills the rest.
	## Auto height retains a 320-pixel editing viewport.
	textarea : { label : Str, value : Signal(Str) }, List(Attr), Msg -> Elem
	textarea = |props, attrs, message|
		Html.textarea_attrs(props.label, props.value, lower_attrs(1, style_default, attrs), message)

	## Toggle a controlled boolean using the ordinary checked-value event route.
	checkbox : { label : Str, checked : Signal(Bool) }, List(Attr), Msg -> Elem
	checkbox = |props, attrs, message|
		Html.checkbox_attrs(props.label, props.checked, lower_attrs(0, style_default, attrs), message)
}

## The native default encoding is a canonical v2 record shared with the Zig decoder.
expect encode_style(1, Gui.style_default) == "2,1,8,0,0,0,0,0,0,16777216,16777216,16777216,16777216,16777216,0,0,0,0,0"

## Base64 matches the canonical RFC 4648 vectors at every padding length.
expect encode_base64("foo".to_utf8()) == "Zm9v"
expect encode_base64("fo".to_utf8()) == "Zm8="
expect encode_base64("f".to_utf8()) == "Zg=="
expect encode_base64([0, 255, 127]) == "AP9/"

## The v1 declaration is one version line, then family and data lines per font.
expect encode_fonts([{ family: "Source Code Pro", bytes: "foo".to_utf8() }]) == "1\nSource Code Pro\nZm9v"
