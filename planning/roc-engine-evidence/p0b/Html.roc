import Elem
import Node
import Val

## Markup in context `ctx`. Every reactive argument accepts any `v` with a
## `to_val` method, so the same helper takes a root `Signal(a)`, a row
## projection `Val(Site(...), a)`, or a `Ui.RowState`. The `_s` suffix is kept
## from today's vocabulary and now means "reactive in this context".
Html := [].{

	## An attribute usable in context `ctx`.
	Attr(ctx) : Node.Attr(ctx)

	## Any element. Public, so a row template never needs `Elem` constructors.
	element : Str, List(Node.Attr(ctx)), List(Elem(ctx)) -> Elem(ctx)
	element = |tag, attrs, children| Elem.platform_element(tag, attrs, children)

	div : List(Node.Attr(ctx)), List(Elem(ctx)) -> Elem(ctx)
	div = |attrs, children| Elem.platform_element("div", attrs, children)

	div_c : Str, List(Elem(ctx)) -> Elem(ctx)
	div_c = |class, children| Elem.platform_element("div", [Node.static_text("class", class)], children)

	## Static text.
	text : Str -> Elem(ctx)
	text = |value| Elem.platform_text(value)

	## Reactive text: a signal, a row value, or row-local state.
	text_s : v -> Elem(ctx)
		where [
			v.to_val : v -> Val(ctx, Str),
		]
	text_s = |value| Elem.platform_text_val(value.to_val())

	heading : Str -> Elem(ctx)
	heading = |value| Elem.platform_element("h1", [], [Elem.platform_text(value)])

	paragraph_s : v -> Elem(ctx)
		where [
			v.to_val : v -> Val(ctx, Str),
		]
	paragraph_s = |value| Elem.platform_element("p", [], [Elem.platform_text_val(value.to_val())])

	class_attr : Str -> Node.Attr(ctx)
	class_attr = |value| Node.static_text("class", value)

	class_attr_s : v -> Node.Attr(ctx)
		where [
			v.to_val : v -> Val(ctx, Str),
		]
	class_attr_s = |value| Node.dyn_text("class", value.to_val())

	attr : Str, Str -> Node.Attr(ctx)
	attr = |name, value| Node.static_text(name, value)

	attr_s : Str, v -> Node.Attr(ctx)
		where [
			v.to_val : v -> Val(ctx, Str),
		]
	attr_s = |name, value| Node.dyn_text(name, value.to_val())

	test_id : Str -> Node.Attr(ctx)
	test_id = |value| Node.static_text("data-testid", value)

	test_id_s : v -> Node.Attr(ctx)
		where [
			v.to_val : v -> Val(ctx, Str),
		]
	test_id_s = |value| Node.dyn_text("data-testid", value.to_val())

	aria_label : Str -> Node.Attr(ctx)
	aria_label = |value| Node.static_text("aria-label", value)

	aria_label_s : v -> Node.Attr(ctx)
		where [
			v.to_val : v -> Val(ctx, Str),
		]
	aria_label_s = |value| Node.dyn_text("aria-label", value.to_val())

	disabled_s : v -> Node.Attr(ctx)
		where [
			v.to_val : v -> Val(ctx, Bool),
		]
	disabled_s = |value| Node.dyn_bool("disabled", value.to_val())

	aria_invalid_s : v -> Node.Attr(ctx)
		where [
			v.to_val : v -> Val(ctx, Bool),
		]
	aria_invalid_s = |value| Node.dyn_bool("aria-invalid", value.to_val())

	on_click : Node.Handler(ctx) -> Node.Attr(ctx)
	on_click = |handler| Node.on("click", handler)

	on_submit_prevent_default : Node.Handler(ctx) -> Node.Attr(ctx)
	on_submit_prevent_default = |handler| Node.on("submit", handler)

	button : Str, Node.Handler(ctx) -> Elem(ctx)
	button = |label, handler| Elem.platform_element("button", [Node.on("click", handler)], [Elem.platform_text(label)])

	button_attrs : Str, List(Node.Attr(ctx)), Node.Handler(ctx) -> Elem(ctx)
	button_attrs = |label, attrs, handler| Elem.platform_element("button", attrs.append(Node.on("click", handler)), [Elem.platform_text(label)])

	text_input : Str, v, Node.Handler(ctx) -> Elem(ctx)
		where [
			v.to_val : v -> Val(ctx, Str),
		]
	text_input = |label, value, handler|
		Elem.platform_element(
			"input",
			[Node.static_text("aria-label", label), Node.dyn_text("value", value.to_val()), Node.on("input", handler)],
			[],
		)

	checkbox : Str, v, Node.Handler(ctx) -> Elem(ctx)
		where [
			v.to_val : v -> Val(ctx, Bool),
		]
	checkbox = |label, checked, handler|
		Elem.platform_element(
			"input",
			[Node.static_text("type", "checkbox"), Node.static_text("aria-label", label), Node.dyn_bool("checked", checked.to_val()), Node.on("change", handler)],
			[],
		)
}
