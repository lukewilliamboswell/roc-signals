import Engine exposing [Attr, Elem, Handler, Val]

## Small HTML vocabulary over the engine (the ported apps share it). Every
## helper is generic in the context, so it is specialised once per context
## type that uses it. Accessible names go in aria-label, as the original
## platform's Html module does, so the specs locate the same nodes.
Html := [].{
	div : Str, List(Elem(ctx)) -> Elem(ctx)
	div = |cls, kids| Engine.element("div", [Engine.class(cls)], kids)

	## A named region.
	section : Str, Str, List(Elem(ctx)) -> Elem(ctx)
	section = |name, cls, kids| Engine.element("section", [Engine.attr("aria-label", name), Engine.class(cls)], kids)

	## A region whose name depends on the context (a row key).
	section_v : Val(ctx, Str), Str, List(Elem(ctx)) -> Elem(ctx)
	section_v = |name, cls, kids| Engine.element("section", [Engine.attr_v("aria-label", name), Engine.class(cls)], kids)

	h1 : Str, Str -> Elem(ctx)
	h1 = |t, cls| Engine.element("h1", [Engine.class(cls)], [Engine.text(t)])

	h2 : Str, Str -> Elem(ctx)
	h2 = |t, cls| Engine.element("h2", [Engine.class(cls)], [Engine.text(t)])

	p : Str, Str -> Elem(ctx)
	p = |t, cls| Engine.element("p", [Engine.class(cls)], [Engine.text(t)])

	p_v : Val(ctx, Str), List(Attr(ctx)) -> Elem(ctx)
	p_v = |v, attrs| Engine.element("p", attrs, [Engine.text_v(v)])

	span_v : Val(ctx, Str), List(Attr(ctx)) -> Elem(ctx)
	span_v = |v, attrs| Engine.element("span", attrs, [Engine.text_v(v)])

	bool_str : Bool -> Str
	bool_str = |b| if (b) "true" else "false"

	## A boolean attribute rendered "true"/"false" (disabled, checked,
	## aria-invalid, aria-pressed).
	flag : Str, Val(ctx, Bool) -> Attr(ctx)
	flag = |name, v| Engine.attr_v(name, v.map(Html.bool_str))

	## "true" or absent ("" removes the attribute), as `aria_invalid_s` does.
	flag_maybe : Str, Val(ctx, Bool) -> Attr(ctx)
	flag_maybe = |name, v| Engine.attr_v(name, v.map(|b| if (b) "true" else ""))

	button : Str, List(Attr(ctx)), Handler(ctx) -> Elem(ctx)
	button = |label, attrs, h| Engine.element("button", attrs.append(Engine.on_click(h)), [Engine.text(label)])

	## A glyph button whose accessible name is `name`.
	icon_button : Str, Val(ctx, Str), Str, Handler(ctx) -> Elem(ctx)
	icon_button = |glyph, name, cls, h| Engine.element("button", [Engine.attr_v("aria-label", name), Engine.attr("type", "button"), Engine.class(cls), Engine.on_click(h)], [Engine.text(glyph)])

	## A text box: `input` fires with the new value as payload.
	text_input : Val(ctx, Str), Str, Val(ctx, Str), List(Attr(ctx)), Handler(ctx) -> Elem(ctx)
	text_input = |name, kind, v, attrs, h| Engine.element("input", [Engine.attr_v("aria-label", name), Engine.attr("type", kind), Engine.attr_v("value", v), Engine.on("input", h)].concat(attrs), [])

	## A checkbox: `change` fires with "true"/"false".
	checkbox : Val(ctx, Str), Val(ctx, Bool), List(Attr(ctx)), Handler(ctx) -> Elem(ctx)
	checkbox = |name, v, attrs, h| Engine.element("input", [Engine.attr_v("aria-label", name), Engine.attr("type", "checkbox"), Html.flag("checked", v), Engine.on("change", h)].concat(attrs), [])

	## A select: `change` fires with the chosen option's value.
	select : Val(ctx, Str), Val(ctx, Str), List(Attr(ctx)), List(Elem(ctx)), Handler(ctx) -> Elem(ctx)
	select = |name, v, attrs, opts, h| Engine.element("select", [Engine.attr_v("aria-label", name), Engine.attr_v("value", v), Engine.on("change", h)].concat(attrs), opts)

	option : Str, Str -> Elem(ctx)
	option = |value, label| Engine.element("option", [Engine.attr("value", value)], [Engine.text(label)])

	option_v : Val(ctx, Str) -> Elem(ctx)
	option_v = |v| Engine.element("option", [Engine.attr_v("value", v)], [Engine.text_v(v)])

	# ------------------------------------------------------------ structure

	## A `div` with attributes rather than a class.
	div_attrs : List(Attr(ctx)), List(Elem(ctx)) -> Elem(ctx)
	div_attrs = |attrs, kids| Engine.element("div", attrs, kids)

	## A `div` whose class depends on the context.
	div_v : Val(ctx, Str), List(Elem(ctx)) -> Elem(ctx)
	div_v = |cls, kids| Engine.element("div", [Engine.class_v(cls)], kids)

	## A named region with extra attributes.
	section_attrs : Str, List(Attr(ctx)), List(Elem(ctx)) -> Elem(ctx)
	section_attrs = |name, attrs, kids| Engine.element("section", [Engine.attr("aria-label", name)].concat(attrs), kids)

	## A paragraph of static text with attributes.
	p_attrs : Str, List(Attr(ctx)) -> Elem(ctx)
	p_attrs = |t, attrs| Engine.element("p", attrs, [Engine.text(t)])

	## Preformatted text that depends on the context.
	pre_v : Val(ctx, Str), List(Attr(ctx)) -> Elem(ctx)
	pre_v = |v, attrs| Engine.element("pre", attrs, [Engine.text_v(v)])

	## A heading (role `heading`) whose text depends on the context.
	h2_v : Val(ctx, Str), List(Attr(ctx)) -> Elem(ctx)
	h2_v = |v, attrs| Engine.element("h2", attrs, [Engine.text_v(v)])

	h3 : Str, Str -> Elem(ctx)
	h3 = |t, cls| Engine.element("h3", [Engine.class(cls)], [Engine.text(t)])

	## An unordered list and its items.
	ul : List(Attr(ctx)), List(Elem(ctx)) -> Elem(ctx)
	ul = |attrs, kids| Engine.element("ul", attrs, kids)

	li : List(Attr(ctx)), List(Elem(ctx)) -> Elem(ctx)
	li = |attrs, kids| Engine.element("li", attrs, kids)

	## A link (role `link`) to `href` whose accessible name is its text.
	link : Str, Str, List(Attr(ctx)) -> Elem(ctx)
	link = |label, href, attrs| Engine.element("a", [Engine.attr("href", href)].concat(attrs), [Engine.text(label)])

	## A caption for the control named `for_id`.
	label_for : Str, Str, List(Attr(ctx)) -> Elem(ctx)
	label_for = |t, for_id, attrs| Engine.element("label", [Engine.attr("for", for_id)].concat(attrs), [Engine.text(t)])

	# ---------------------------------------------------------- attributes

	## The accessible name (`aria-label`), which `label` and `role` locators
	## match.
	aria_label : Str -> Attr(ctx)
	aria_label = |name| Engine.attr("aria-label", name)

	aria_label_v : Val(ctx, Str) -> Attr(ctx)
	aria_label_v = |v| Engine.attr_v("aria-label", v)

	aria_describedby : Str -> Attr(ctx)
	aria_describedby = |id| Engine.attr("aria-describedby", id)

	## `aria-invalid="true"` while the value is true, absent otherwise.
	aria_invalid : Val(ctx, Bool) -> Attr(ctx)
	aria_invalid = |v| Html.flag_maybe("aria-invalid", v)

	## Present (`disabled`) while the value is true.
	disabled : Val(ctx, Bool) -> Attr(ctx)
	disabled = |v| Html.flag("disabled", v)

	# --------------------------------------------------------------- events

	## `focus` and `blur` handlers receive the control's value.
	on_focus : Handler(ctx) -> Attr(ctx)
	on_focus = |h| Engine.on("focus", h)

	on_blur : Handler(ctx) -> Attr(ctx)
	on_blur = |h| Engine.on("blur", h)

	## `input` receives the control's new value.
	on_input : Handler(ctx) -> Attr(ctx)
	on_input = |h| Engine.on("input", h)

	## `change` receives "true"/"false" for a checkbox or radio, else the
	## control's value.
	on_change : Handler(ctx) -> Attr(ctx)
	on_change = |h| Engine.on("change", h)

	## `keydown` receives the key.
	on_keydown : Handler(ctx) -> Attr(ctx)
	on_keydown = |h| Engine.on("keydown", h)

	## A form's `submit`. The runtime always prevents the browser's default
	## (forms are app-managed), so the page never navigates.
	on_submit : Handler(ctx) -> Attr(ctx)
	on_submit = |h| Engine.on("submit", h)

	# ------------------------------------------------------------- controls

	## A form (role `form`) named `name`.
	form : Str, List(Attr(ctx)), List(Elem(ctx)) -> Elem(ctx)
	form = |name, attrs, kids| Engine.element("form", [Engine.attr("aria-label", name)].concat(attrs), kids)

	## A button whose label depends on the context.
	button_v : Val(ctx, Str), List(Attr(ctx)), Handler(ctx) -> Elem(ctx)
	button_v = |label, attrs, h| Engine.element("button", attrs.append(Engine.on_click(h)), [Engine.text_v(label)])

	## A button with a dynamic label that is disabled while `off` is true.
	action_button : Val(ctx, Str), Val(ctx, Bool), List(Attr(ctx)), Handler(ctx) -> Elem(ctx)
	action_button = |label, off, attrs, h| Engine.element("button", [Html.disabled(off)].concat(attrs).append(Engine.on_click(h)), [Engine.text_v(label)])

	## A form's submit button (its click submits the form).
	submit_button : Str, List(Attr(ctx)) -> Elem(ctx)
	submit_button = |label, attrs| Engine.element("button", [Engine.attr("type", "submit")].concat(attrs), [Engine.text(label)])

	## A multi-line text box: `input` fires with the new value.
	textarea : Val(ctx, Str), Val(ctx, Str), List(Attr(ctx)), Handler(ctx) -> Elem(ctx)
	textarea = |name, v, attrs, h| Engine.element("textarea", [Engine.attr_v("aria-label", name), Engine.attr_v("value", v), Engine.on("input", h)].concat(attrs), [])

	## A number box: `input` fires with the draft text (the app parses it).
	number_input : Val(ctx, Str), Val(ctx, Str), List(Attr(ctx)), Handler(ctx) -> Elem(ctx)
	number_input = |name, v, attrs, h| Html.text_input(name, "number", v, attrs, h)

	## One radio of group `group`, checked while `selected` equals `value`.
	## Its `change` handler fires when the user picks it (payload "true").
	radio : Str, Str, Str, Val(ctx, Str), List(Attr(ctx)), Handler(ctx) -> Elem(ctx)
	radio = |name, group, value, selected, attrs, h| Engine.element(
		"input",
		[
			Engine.attr("aria-label", name),
			Engine.attr("type", "radio"),
			Engine.attr("name", group),
			Engine.attr("value", value),
			Html.flag("checked", selected.map(|cur| cur == value)),
			Engine.on("change", h),
		].concat(attrs),
		[],
	)

	## An option with extra attributes.
	option_attrs : Str, Str, List(Attr(ctx)) -> Elem(ctx)
	option_attrs = |value, label, attrs| Engine.element("option", [Engine.attr("value", value)].concat(attrs), [Engine.text(label)])
}
