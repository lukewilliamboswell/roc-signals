import Elem exposing [Elem]
import HostValue exposing [HostValue]
import Capability exposing [Capability]
import Node
import Signal exposing [Signal]

field_text : Node.TextField
field_text = { id: 1 }

field_role : Node.TextField
field_role = { id: 2 }

field_label : Node.TextField
field_label = { id: 3 }

field_value : Node.TextField
field_value = { id: 5 }

field_class : Node.TextField
field_class = { id: 6 }

field_custom : Node.TextField
field_custom = { id: 7 }

bool_field_checked : Node.BoolField
bool_field_checked = { id: 1 }

bool_field_disabled : Node.BoolField
bool_field_disabled = { id: 2 }

bool_field_custom : Node.BoolField
bool_field_custom = { id: 3 }

fixed_event_click : Node.FixedEventKind
fixed_event_click = { id: 1 }

fixed_event_input : Node.FixedEventKind
fixed_event_input = { id: 2 }

fixed_event_check : Node.FixedEventKind
fixed_event_check = { id: 3 }

fixed_event_pointer_down : Node.FixedEventKind
fixed_event_pointer_down = { id: 4 }

fixed_event_pointer_up : Node.FixedEventKind
fixed_event_pointer_up = { id: 5 }

fixed_event_pointer_enter : Node.FixedEventKind
fixed_event_pointer_enter = { id: 6 }

fixed_event_pointer_leave : Node.FixedEventKind
fixed_event_pointer_leave = { id: 7 }

event_policy_none_value : Node.EventPolicy
event_policy_none_value = { prevent_default: False, stop_propagation: False, stop_immediate: False, capture: False, passive: False, once: False, self: False, trusted: False }

event_policy_prevent_default_value : Node.EventPolicy
event_policy_prevent_default_value = { ..event_policy_none_value, prevent_default: True }

event_policy_stop_propagation_value : Node.EventPolicy
event_policy_stop_propagation_value = { ..event_policy_none_value, stop_propagation: True }

event_policy_stop_immediate_value : Node.EventPolicy
event_policy_stop_immediate_value = { ..event_policy_none_value, stop_immediate: True }

event_delivery_auto_value : Node.EventDelivery
event_delivery_auto_value = { native: False }

event_delivery_native_value : Node.EventDelivery
event_delivery_native_value = { native: True }

fixed_event_binding : Node.FixedEventKind, Node.Msg -> Node.EventBinding
fixed_event_binding = |kind, msg| { kind, msg, policy: event_policy_none_value, delivery: event_delivery_auto_value, name: "" }

named_event_binding : Str, Node.EventPolicy, Node.Msg -> Node.EventBinding
named_event_binding = |name, policy, msg| {
	{ kind: { id: 0 }, msg, policy, delivery: event_delivery_auto_value, name }
}

event_attr : Node.EventBinding -> Node.Attr
event_attr = |binding| Node.Attr.On(binding)

## Static UI structure and attributes. Markup carries no identity; dynamic text
## and attributes reference signals, and event handlers carry reducer messages.
Html := [].{
	Attr : Node.Attr
	EventPolicy : Node.EventPolicy
	EventDelivery : Node.EventDelivery

	## Default event policy: no prevention, propagation change, or listener option.
	event_policy_none : EventPolicy
	event_policy_none = event_policy_none_value

	## Event policy that calls `preventDefault`.
	event_policy_prevent_default : EventPolicy
	event_policy_prevent_default = event_policy_prevent_default_value

	## Event policy that stops bubbling after the current target.
	event_policy_stop_propagation : EventPolicy
	event_policy_stop_propagation = event_policy_stop_propagation_value

	## Event policy that stops later listeners on the current target too.
	event_policy_stop_immediate : EventPolicy
	event_policy_stop_immediate = event_policy_stop_immediate_value

	## Let the host choose compact or native event delivery.
	event_delivery_auto : EventDelivery
	event_delivery_auto = event_delivery_auto_value

	## Force native browser listener delivery for custom event bindings.
	event_delivery_native : EventDelivery
	event_delivery_native = event_delivery_native_value

	## Static class attribute.
	class_attr : Str -> Node.Attr
	class_attr = |value| Node.Attr.StaticText({ field: field_class, name: "", value })

	## Signal-backed class attribute.
	class_attr_s : Signal(Str) -> Node.Attr
	class_attr_s = |signal| {
		cap = signal.cap
		read : HostValue -> Str
		read = |value| Box.unbox(Capability.get(value, cap))
		Node.Attr.SignalText({ field: field_class, name: "", signal: Signal.to_expr(signal), read: { capability: Capability.handle(cap), read: Box.box(read) } })
	}

	## Static text attribute by name.
	attr : Str, Str -> Node.Attr
	attr = |name, value| Node.Attr.StaticText({ field: field_custom, name, value })

	## Signal-backed text attribute by name.
	attr_s : Str, Signal(Str) -> Node.Attr
	attr_s = |name, signal| {
		cap = signal.cap
		read : HostValue -> Str
		read = |value| Box.unbox(Capability.get(value, cap))
		Node.Attr.SignalText({ field: field_custom, name, signal: Signal.to_expr(signal), read: { capability: Capability.handle(cap), read: Box.box(read) } })
	}

	## Static boolean attribute set to true.
	bool_attr : Str -> Node.Attr
	bool_attr = |name| Node.Attr.StaticBool({ field: bool_field_custom, name, value: True })

	## Return a one-item boolean attr list only when present.
	bool_attr_if : Str, Bool -> List(Node.Attr)
	bool_attr_if = |name, present| {
		if present {
			[bool_attr(name)]
		} else {
			[]
		}
	}

	## Signal-backed boolean attribute by name.
	bool_attr_s : Str, Signal(Bool) -> Node.Attr
	bool_attr_s = |name, signal| {
		cap = signal.cap
		read : HostValue -> Bool
		read = |value| Box.unbox(Capability.get(value, cap))
		Node.Attr.SignalBool({ field: bool_field_custom, name, signal: Signal.to_expr(signal), read: { capability: Capability.handle(cap), read: Box.box(read) } })
	}

	## Static `required` boolean attribute.
	required : Node.Attr
	required = bool_attr("required")

	## Static `readonly` boolean attribute.
	readonly : Node.Attr
	readonly = bool_attr("readonly")

	## Signal-backed `aria-invalid` boolean attribute.
	aria_invalid_s : Signal(Bool) -> Node.Attr
	aria_invalid_s = |signal| bool_attr_s("aria-invalid", signal)

	## Static `aria-describedby` attribute.
	aria_describedby : Str -> Node.Attr
	aria_describedby = |id| attr("aria-describedby", id)

	## Pointer-down event binding.
	on_pointer_down : Node.Msg -> Node.Attr
	on_pointer_down = |msg| event_attr(fixed_event_binding(fixed_event_pointer_down, msg))

	## Pointer-up event binding.
	on_pointer_up : Node.Msg -> Node.Attr
	on_pointer_up = |msg| event_attr(fixed_event_binding(fixed_event_pointer_up, msg))

	## Pointer-enter event binding.
	on_pointer_enter : Node.Msg -> Node.Attr
	on_pointer_enter = |msg| event_attr(fixed_event_binding(fixed_event_pointer_enter, msg))

	## Pointer-leave event binding.
	on_pointer_leave : Node.Msg -> Node.Attr
	on_pointer_leave = |msg| event_attr(fixed_event_binding(fixed_event_pointer_leave, msg))

	## Named event binding with an explicit static policy.
	on_event : Str, EventPolicy, Node.Msg -> Node.Attr
	on_event = |name, policy, msg| event_attr(named_event_binding(name, policy, msg))

	## Named event binding with explicit policy and delivery request.
	on_event_delivery : Str, EventPolicy, EventDelivery, Node.Msg -> Node.Attr
	on_event_delivery = |name, policy, delivery, msg| event_attr({ kind: { id: 0 }, msg, policy, delivery, name })

	## Keydown event binding.
	on_key_down : Node.Msg -> Node.Attr
	on_key_down = |msg| on_event("keydown", event_policy_none, msg)

	## Submit event binding that prevents browser navigation.
	on_submit_prevent_default : Node.Msg -> Node.Attr
	on_submit_prevent_default = |msg| on_event("submit", event_policy_prevent_default, msg)

	## Focus event binding.
	on_focus : Node.Msg -> Node.Attr
	on_focus = |msg| on_event("focus", event_policy_none, msg)

	## Blur event binding.
	on_blur : Node.Msg -> Node.Attr
	on_blur = |msg| on_event("blur", event_policy_none, msg)

	## Change event binding.
	on_change : Node.Msg -> Node.Attr
	on_change = |msg| on_event("change", event_policy_none, msg)

	## Composition-start event binding.
	on_composition_start : Node.Msg -> Node.Attr
	on_composition_start = |msg| on_event("compositionstart", event_policy_none, msg)

	## Composition-end event binding.
	on_composition_end : Node.Msg -> Node.Attr
	on_composition_end = |msg| on_event("compositionend", event_policy_none, msg)

	## Generic `div` element with attrs and children.
	div : List(Node.Attr), List(Elem) -> Elem
	div = |attrs, children| Elem.Element({ tag: "div", attrs, children })

	## Generic `form` element with attrs and children.
	form : List(Node.Attr), List(Elem) -> Elem
	form = |attrs, children| Elem.Element({ tag: "form", attrs, children })

	## Form element with role and accessible label metadata.
	form_label : Str, List(Node.Attr), List(Elem) -> Elem
	form_label = |label, attrs, children| {
		base = [
			Node.Attr.StaticText({ field: field_role, name: "", value: "form" }),
			Node.Attr.StaticText({ field: field_label, name: "", value: label }),
		]
		form(List.concat(base, attrs), children)
	}

	## Link element with text, role, and accessible label metadata.
	link : Str, List(Node.Attr) -> Elem
	link = |label, attrs| {
		base = [
			Node.Attr.StaticText({ field: field_role, name: "", value: "link" }),
			Node.Attr.StaticText({ field: field_label, name: "", value: label }),
			Node.Attr.StaticText({ field: field_text, name: "", value: label }),
		]
		Elem.Element({ tag: "a", attrs: List.concat(base, attrs), children: [] })
	}

	## `div` with a static class attribute.
	div_c : Str, List(Elem) -> Elem
	div_c = |classes, children| div([class_attr(classes)], children)

	## `div` with a signal-backed class attribute.
	div_sc : Signal(Str), List(Elem) -> Elem
	div_sc = |classes, children| div([class_attr_s(classes)], children)

	## Labeled section region.
	section : Str, List(Node.Attr), List(Elem) -> Elem
	section = |label, attrs, children| {
		base = [
			Node.Attr.StaticText({ field: field_role, name: "", value: "region" }),
			Node.Attr.StaticText({ field: field_label, name: "", value: label }),
		]
		Elem.Element({ tag: "section", attrs: List.concat(base, attrs), children })
	}

	## Labeled section region with a static class.
	section_c : Str, Str, List(Elem) -> Elem
	section_c = |label, classes, children| section(label, [class_attr(classes)], children)

	## Labeled section region with a signal-backed class.
	section_sc : Str, Signal(Str), List(Elem) -> Elem
	section_sc = |label, classes, children| section(label, [class_attr_s(classes)], children)

	## Heading element with static text.
	heading : Str -> Elem
	heading = |text_value| {
		Elem.Element(
			{
				tag: "h2",
				attrs: [
					Node.Attr.StaticText({ field: field_role, name: "", value: "heading" }),
					Node.Attr.StaticText({ field: field_text, name: "", value: text_value }),
				],
				children: [],
			},
		)
	}

	## Heading element with static text and class.
	heading_c : Str, Str -> Elem
	heading_c = |text_value, classes| {
		Elem.Element(
			{
				tag: "h2",
				attrs: [
					Node.Attr.StaticText({ field: field_role, name: "", value: "heading" }),
					Node.Attr.StaticText({ field: field_text, name: "", value: text_value }),
					class_attr(classes),
				],
				children: [],
			},
		)
	}

	## Paragraph element with static text.
	paragraph : Str -> Elem
	paragraph = |text_value| {
		paragraph_attrs(text_value, [])
	}

	## Paragraph element with static text and extra attrs.
	paragraph_attrs : Str, List(Node.Attr) -> Elem
	paragraph_attrs = |text_value, attrs| {
		Elem.Element(
			{
				tag: "p",
				attrs: List.concat([Node.Attr.StaticText({ field: field_text, name: "", value: text_value })], attrs),
				children: [],
			},
		)
	}

	## Paragraph element with static text and class.
	paragraph_c : Str, Str -> Elem
	paragraph_c = |text_value, classes| paragraph_attrs(text_value, [class_attr(classes)])

	## Paragraph element with signal-backed text.
	paragraph_s : Signal(Str) -> Elem
	paragraph_s = |signal| paragraph_s_c(signal, "")

	## Paragraph element with signal-backed text and static class.
	paragraph_s_c : Signal(Str), Str -> Elem
	paragraph_s_c = |signal, classes| {
		cap = signal.cap
		read : HostValue -> Str
		read = |value| Box.unbox(Capability.get(value, cap))
		Elem.Element(
			{
				tag: "p",
				attrs: [
					Node.Attr.SignalText({ field: field_text, name: "", signal: Signal.to_expr(signal), read: { capability: Capability.handle(cap), read: Box.box(read) } }),
					class_attr(classes),
				],
				children: [],
			},
		)
	}

	## Raw text node with static text.
	text : Str -> Elem
	text = |value| Elem.Text(value)

	## Signal-backed text content.
	text_s : Signal(Str) -> Elem
	text_s = |signal| {
		cap = signal.cap
		read : HostValue -> Str
		read = |value| Box.unbox(Capability.get(value, cap))
		Elem.TextSignal({ signal: Signal.to_expr(signal), read: { capability: Capability.handle(cap), read: Box.box(read) } })
	}

	## Signal-backed preformatted text block.
	pre_s_c : Signal(Str), Str -> Elem
	pre_s_c = |signal, classes| {
		cap = signal.cap
		read : HostValue -> Str
		read = |value| Box.unbox(Capability.get(value, cap))
		Elem.Element(
			{
				tag: "pre",
				attrs: [
					Node.Attr.SignalText({ field: field_text, name: "", signal: Signal.to_expr(signal), read: { capability: Capability.handle(cap), read: Box.box(read) } }),
					class_attr(classes),
				],
				children: [],
			},
		)
	}

	## A button whose label is static text and whose click fires `msg`.
	button : Str, Node.Msg -> Elem
	button = |label, msg| button_attrs(label, [], msg)

	## Static-label button with a class.
	button_c : Str, Str, Node.Msg -> Elem
	button_c = |label, classes, msg| button_attrs(label, [class_attr(classes)], msg)

	## Static-label button with extra attrs.
	button_attrs : Str, List(Node.Attr), Node.Msg -> Elem
	button_attrs = |label, attrs, msg| {
		Elem.Element(
			{
				tag: "button",
				attrs: List.concat(
					[
						Node.Attr.StaticText({ field: field_text, name: "", value: label }),
						event_attr(fixed_event_binding(fixed_event_click, msg)),
					],
					attrs,
				),
				children: [],
			},
		)
	}

	## A button whose label is signal-backed.
	button_s : Signal(Str), Node.Msg -> Elem
	button_s = |label, msg| button_s_attrs(label, [], msg)

	## Signal-label button with a class.
	button_s_c : Signal(Str), Str, Node.Msg -> Elem
	button_s_c = |label, classes, msg| button_s_attrs(label, [class_attr(classes)], msg)

	## Signal-label button with extra attrs.
	button_s_attrs : Signal(Str), List(Node.Attr), Node.Msg -> Elem
	button_s_attrs = |label, attrs, msg| {
		label_cap = label.cap
		read_label : HostValue -> Str
		read_label = |value| Box.unbox(Capability.get(value, label_cap))
		Elem.Element(
			{
				tag: "button",
				attrs: List.concat(
					[
						Node.Attr.SignalText({ field: field_text, name: "", signal: Signal.to_expr(label), read: { capability: Capability.handle(label_cap), read: Box.box(read_label) } }),
						event_attr(fixed_event_binding(fixed_event_click, msg)),
					],
					attrs,
				),
				children: [],
			},
		)
	}

	## A button whose label and disabled state are signal-backed.
	action_button : Signal(Str), Signal(Bool), Node.Msg -> Elem
	action_button = |label, disabled, msg| action_button_attrs(label, disabled, [], msg)

	## Signal-label action button with signal-backed disabled state and class.
	action_button_c : Signal(Str), Signal(Bool), Str, Node.Msg -> Elem
	action_button_c = |label, disabled, classes, msg| action_button_attrs(label, disabled, [class_attr(classes)], msg)

	## Signal-label action button with signal-backed disabled state and attrs.
	action_button_attrs : Signal(Str), Signal(Bool), List(Node.Attr), Node.Msg -> Elem
	action_button_attrs = |label, disabled, attrs, msg| {
		label_cap = label.cap
		disabled_cap = disabled.cap
		read_label : HostValue -> Str
		read_label = |value| Box.unbox(Capability.get(value, label_cap))
		read_disabled : HostValue -> Bool
		read_disabled = |value| Box.unbox(Capability.get(value, disabled_cap))
		Elem.Element(
			{
				tag: "button",
				attrs: List.concat(
					[
						Node.Attr.SignalText({ field: field_text, name: "", signal: Signal.to_expr(label), read: { capability: Capability.handle(label_cap), read: Box.box(read_label) } }),
						Node.Attr.SignalBool({ field: bool_field_disabled, name: "", signal: Signal.to_expr(disabled), read: { capability: Capability.handle(disabled_cap), read: Box.box(read_disabled) } }),
						event_attr(fixed_event_binding(fixed_event_click, msg)),
					],
					attrs,
				),
				children: [],
			},
		)
	}

	## A text input bound to a signal value, firing `msg` (a str-payload reducer)
	## on input.
	text_input : Str, Signal(Str), Node.Msg -> Elem
	text_input = |label, value, msg| text_input_attrs(label, value, [], msg)

	## Text input with a static class.
	text_input_c : Str, Signal(Str), Str, Node.Msg -> Elem
	text_input_c = |label, value, classes, msg| text_input_attrs(label, value, [class_attr(classes)], msg)

	## Text input with extra attrs.
	text_input_attrs : Str, Signal(Str), List(Node.Attr), Node.Msg -> Elem
	text_input_attrs = |label, value, attrs, msg| {
		value_cap = value.cap
		read_value : HostValue -> Str
		read_value = |host_value| Box.unbox(Capability.get(host_value, value_cap))
		Elem.Element(
			{
				tag: "input",
				attrs: List.concat(
					[
						Node.Attr.StaticText({ field: field_role, name: "", value: "textbox" }),
						Node.Attr.StaticText({ field: field_label, name: "", value: label }),
						Node.Attr.SignalText({ field: field_value, name: "", signal: Signal.to_expr(value), read: { capability: Capability.handle(value_cap), read: Box.box(read_value) } }),
						event_attr(fixed_event_binding(fixed_event_input, msg)),
					],
					attrs,
				),
				children: [],
			},
		)
	}

	## A checkbox bound to a signal value, firing `msg` (a bool-payload reducer) on
	## change.
	checkbox : Str, Signal(Bool), Node.Msg -> Elem
	checkbox = |label, checked, msg| checkbox_attrs(label, checked, [], msg)

	## Checkbox with a static class.
	checkbox_c : Str, Signal(Bool), Str, Node.Msg -> Elem
	checkbox_c = |label, checked, classes, msg| checkbox_attrs(label, checked, [class_attr(classes)], msg)

	## Checkbox with extra attrs.
	checkbox_attrs : Str, Signal(Bool), List(Node.Attr), Node.Msg -> Elem
	checkbox_attrs = |label, checked, attrs, msg| {
		checked_cap = checked.cap
		read_checked : HostValue -> Bool
		read_checked = |value| Box.unbox(Capability.get(value, checked_cap))
		Elem.Element(
			{
				tag: "input",
				attrs: List.concat(
					[
						Node.Attr.StaticText({ field: field_role, name: "", value: "checkbox" }),
						Node.Attr.StaticText({ field: field_label, name: "", value: label }),
						Node.Attr.SignalBool({ field: bool_field_checked, name: "", signal: Signal.to_expr(checked), read: { capability: Capability.handle(checked_cap), read: Box.box(read_checked) } }),
						event_attr(fixed_event_binding(fixed_event_check, msg)),
					],
					attrs,
				),
				children: [],
			},
		)
	}
}
