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
	TestId(Str),
	Selected(Signal(Bool)),
	Enabled(Signal(Bool)),
	Shortcut(Node.KeyChord, Node.Msg),
	DragSource(Str),
	DropTarget(Node.Msg),
]

native_style_field : Node.TextField
native_style_field = { id: 8 }

selected_field : Node.BoolField
selected_field = { id: 4 }

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

# Native presentation protocol v1: fixed, canonical decimal fields. The host
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
	"1,${direction.to_str()},${style.gap.to_str()},${style.padding.to_str()},${width.kind.to_str()},${width.value.to_str()},${height.kind.to_str()},${height.value.to_str()},${grow.to_str()},${color_number(style.background).to_str()},${color_number(style.foreground).to_str()},${color_number(style.border_color).to_str()},${style.border_width.to_str()},${style.radius.to_str()},${style.font_size.to_str()},${overflow_number(style.overflow_x).to_str()},${overflow_number(style.overflow_y).to_str()}"
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
		initial.append(Node.Attr.StaticBool({ field: { id: 5 }, name: "", value: True }))
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
				Attribute.TestId(value) => Html.test_id(value)
				Attribute.Selected(value) => match Html.bool_attr_s("", value) {
					Node.Attr.SignalBool(payload) => Node.Attr.SignalBool({ ..payload, field: selected_field })
					_ => crash "expected a signal bool descriptor"
				}
				Attribute.Enabled(value) => match Html.bool_attr_s("", value.map(|enabled| !enabled)) {
					Node.Attr.SignalBool(payload) => Node.Attr.SignalBool({ ..payload, field: { id: 2 } })
					_ => crash "expected a signal bool descriptor"
				}
				Attribute.DragSource(key) => Node.Attr.StaticText({ field: { id: 10 }, name: "", value: key })
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
			Node.Attr.SignalText(payload) => Node.Attr.SignalText({ ..payload, field: { id: 11 } })
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
			Node.Attr.SignalText(payload) => Node.Attr.SignalText({ ..payload, field: { id: 9 } })
			_ => crash "expected a signal text descriptor"
		}
		Html.div(lower_attrs(1, { ..style_default, width: Fill, height: Px(480), grow: True }, attrs).append(viewport), children)
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

	## Create a button whose label and availability change independently.
	action_button : { label : Signal(Str), enabled : Signal(Bool) }, List(Attr), Msg -> Elem
	action_button = |props, attrs, message|
		Html.action_button_attrs(props.label, props.enabled.map(|enabled| !enabled), lower_attrs(1, { ..style_default, padding: 8, radius: 6, background: Rgb(3232873) }, attrs), message)

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

## The native default encoding is a canonical v1 record shared with the Zig decoder.
expect encode_style(1, Gui.style_default) == "1,1,8,0,0,0,0,0,0,16777216,16777216,16777216,0,0,0,0,0"
