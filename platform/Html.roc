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
}
