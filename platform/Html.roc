import Engine exposing [Attr, Elem, FilesHandler, Handler, Signal]

## Typed helpers for common HTML elements, attributes and events, built on
## `Engine.element`, `Engine.attr` and `Engine.on`.
##
## Every helper is generic in the context `ctx`, so it works at the top level,
## inside a `state` or `derive` body and in a row of an `each` or a `table_view`.
## Controls take their accessible name as `aria-label`, which spec `label` and
## `role` locators match. Signals keep the DOM in step with state; plain
## `Str` arguments are static.
Html := [].{

	## A `div` with a static class.
	div : Str, List(Elem(ctx)) -> Elem(ctx)
	div = |cls, kids| Engine.element("div", [Engine.class(cls)], kids)

	## `section(name, class, children)`: a region whose accessible name is `name`.
	## The name is set as `aria-label` and is not shown: for a visible title, put
	## a heading among the children.
	section : Str, Str, List(Elem(ctx)) -> Elem(ctx)
	section = |name, cls, kids| Engine.element("section", [Engine.attr("aria-label", name), Engine.class(cls)], kids)

	## A region whose accessible name follows a value (such as a row key).
	section_s : Signal(ctx, Str), Str, List(Elem(ctx)) -> Elem(ctx)
	section_s = |name, cls, kids| Engine.element("section", [Engine.attr_s("aria-label", name), Engine.class(cls)], kids)

	## `h1(text, class)`: a top-level heading with static text.
	h1 : Str, Str -> Elem(ctx)
	h1 = |t, cls| Engine.element("h1", [Engine.class(cls)], [Engine.text(t)])

	## `h2(text, class)`: a second-level heading with static text.
	h2 : Str, Str -> Elem(ctx)
	h2 = |t, cls| Engine.element("h2", [Engine.class(cls)], [Engine.text(t)])

	## `p(text, class)`: a paragraph of static text.
	p : Str, Str -> Elem(ctx)
	p = |t, cls| Engine.element("p", [Engine.class(cls)], [Engine.text(t)])

	## A paragraph whose text follows a value.
	p_s : Signal(ctx, Str), List(Attr(ctx)) -> Elem(ctx)
	p_s = |v, attrs| Engine.element("p", attrs, [Engine.text_s(v)])

	## A `span` whose text follows a value.
	span_s : Signal(ctx, Str), List(Attr(ctx)) -> Elem(ctx)
	span_s = |v, attrs| Engine.element("span", attrs, [Engine.text_s(v)])

	## A boolean attribute rendered `"true"` or `"false"` (such as `disabled` or
	## `aria-pressed`).
	flag : Str, Signal(ctx, Bool) -> Attr(ctx)
	flag = |name, v| Engine.attr_s(name, v.map(bool_str))

	## An attribute that is `"true"` while the value is true and absent otherwise
	## (such as `aria-invalid`).
	flag_maybe : Str, Signal(ctx, Bool) -> Attr(ctx)
	flag_maybe = |name, v| Engine.attr_presence(name, v.map(|b| if (b) Present("true") else Absent))

	## `button(label, attrs, handler)`: a button with a static label that runs
	## `handler` on click.
	button : Str, List(Attr(ctx)), Handler(ctx) -> Elem(ctx)
	button = |label, attrs, h| Engine.element("button", attrs.append(Engine.on_click(h)), [Engine.text(label)])

	## `icon_button(glyph, name, class, handler)`: a button showing `glyph`
	## whose accessible name follows `name`, for icon-only actions.
	icon_button : Str, Signal(ctx, Str), Str, Handler(ctx) -> Elem(ctx)
	icon_button = |glyph, name, cls, h| Engine.element("button", [Engine.attr_s("aria-label", name), Engine.attr("type", "button"), Engine.class(cls), Engine.on_click(h)], [Engine.text(glyph)])

	## `text_input(name, type, value, attrs, handler)`: an `input` of the given
	## `type` whose value follows `value`. `handler` receives the new text on every
	## `input` event. While the input is focused, the user's draft wins over a
	## differing `value`; it is applied on blur.
	text_input : Signal(ctx, Str), Str, Signal(ctx, Str), List(Attr(ctx)), Handler(ctx) -> Elem(ctx)
	text_input = |name, kind, v, attrs, h| Engine.element("input", [Engine.attr_s("aria-label", name), Engine.attr("type", kind), Engine.prop_s(Engine.Prop.value, v), Engine.on("input", h)].concat(attrs), [])

	## What a file input lets the user choose.
	##
	## - `selection`: one file at a time (`Single`, the default) or several
	##   (`Multiple`).
	## - `accept`: any file (`Any`, the default), or the browser's list of
	##   types (`Types(".docx,application/pdf")`), which its chooser offers
	##   first. It is a hint to the chooser, not a check: a dropped or pasted
	##   file, or one the user picks with "all files", can be of any type.
	FileInputProps := {
		selection : [Single, Multiple] ?? Single,
		accept : [Any, Types(Str)] ?? Any,
	}

	## `file_input(name, props, handler)`: a file picker whose accessible name
	## is `name`, as `file_input(Engine.const("Document"), {}, handler)` or
	## `file_input(name, { selection: Multiple }, handler)`. The browser opens
	## its own chooser when the user activates it; `handler`
	## (`State.set_value`) receives the chosen files as handles.
	file_input : Signal(ctx, Str), FileInputProps, FilesHandler(ctx) -> Elem(ctx)
	file_input = |name, FileInputProps.({ selection, accept }), h| {
		attrs = [Engine.attr_s("aria-label", name), Engine.attr("type", "file"), Engine.on_files(Change, h)]
		with_accept = match accept {
			Any => attrs
			Types(types) => attrs.append(Engine.attr("accept", types))
		}
		with_selection = match selection {
			Single => with_accept
			Multiple => with_accept.append(Engine.attr("multiple", "true"))
		}
		Engine.element("input", with_selection, [])
	}

	## Make the element a drop target for files: `handler` (`State.set_value`)
	## receives the files dropped on it or a descendant, and the browser does
	## not open them.
	on_drop_files : FilesHandler(ctx) -> Attr(ctx)
	on_drop_files = |h| Engine.on_files(Drop, h)

	## `handler` (`State.set_value`) receives the files pasted into the element
	## or a descendant (an image copied from another app, say). A paste that
	## carries no files reaches no handler.
	on_paste_files : FilesHandler(ctx) -> Attr(ctx)
	on_paste_files = |h| Engine.on_files(Paste, h)

	## Mark this element as the nearest pointer zone under it. Empty text
	## disables it without removing the element or changing its identity.
	zone : Str -> Attr(ctx)
	zone = |key| Engine.prop(Engine.Prop.pointer_zone, key)

	## Follow a signal with this element's pointer-zone key.
	zone_s : Signal(ctx, Str) -> Attr(ctx)
	zone_s = |key| Engine.prop_s(Engine.Prop.pointer_zone, key)

	## Receive a pointer press without capturing it.
	on_pointer_down : Engine.HandlerOf(ctx, Engine.Pointer) -> Attr(ctx)
	on_pointer_down = |handler| Engine.on_pointer(Down, handler)

	## Receive a pointer press and capture it on this element immediately.
	on_pointer_down_capture : Engine.HandlerOf(ctx, Engine.Pointer) -> Attr(ctx)
	on_pointer_down_capture = |handler| Engine.on_pointer_capture(handler)

	## Receive every pointer move as a separate occurrence.
	on_pointer_move : Engine.HandlerOf(ctx, Engine.Pointer) -> Attr(ctx)
	on_pointer_move = |handler| Engine.on_pointer(Move, handler)

	## Receive only the newest waiting move of each pointer per frame.
	on_pointer_move_paced : Engine.HandlerOf(ctx, Engine.Pointer) -> Attr(ctx)
	on_pointer_move_paced = |handler| Engine.on_pointer_paced(handler)

	## Receive a pointer release, after any earlier waiting paced move.
	on_pointer_up : Engine.HandlerOf(ctx, Engine.Pointer) -> Attr(ctx)
	on_pointer_up = |handler| Engine.on_pointer(Up, handler)

	## Receive browser cancellation so a drag can discard its pending target.
	on_pointer_cancel : Engine.HandlerOf(ctx, Engine.Pointer) -> Attr(ctx)
	on_pointer_cancel = |handler| Engine.on_pointer(Cancel, handler)

	## `checkbox(name, checked, attrs, handler)`: a checkbox that follows
	## `checked`. `handler` receives `"true"` or `"false"` on `change`.
	checkbox : Signal(ctx, Str), Signal(ctx, Bool), List(Attr(ctx)), Handler(ctx) -> Elem(ctx)
	checkbox = |name, v, attrs, h| Engine.element("input", [Engine.attr_s("aria-label", name), Engine.attr("type", "checkbox"), Engine.prop_s(Engine.Prop.checked, v), Engine.on("change", h)].concat(attrs), [])

	## `select(name, value, attrs, options, handler)`: a drop-down that shows
	## `value`. `handler` receives the chosen option's value on `change`.
	select : Signal(ctx, Str), Signal(ctx, Str), List(Attr(ctx)), List(Elem(ctx)), Handler(ctx) -> Elem(ctx)
	select = |name, v, attrs, opts, h| Engine.element("select", [Engine.attr_s("aria-label", name), Engine.prop_s(Engine.Prop.value, v), Engine.on("change", h)].concat(attrs), opts)

	## `option(value, label)`: an option for `select`.
	option : Str, Str -> Elem(ctx)
	option = |value, label| Engine.element("option", [Engine.prop(Engine.Prop.value, value)], [Engine.text(label)])

	## An option whose value and label both follow a value.
	option_s : Signal(ctx, Str) -> Elem(ctx)
	option_s = |v| Engine.element("option", [Engine.prop_s(Engine.Prop.value, v)], [Engine.text_s(v)])

	# ------------------------------------------------------------ structure

	## A `div` with attributes rather than a class.
	div_attrs : List(Attr(ctx)), List(Elem(ctx)) -> Elem(ctx)
	div_attrs = |attrs, kids| Engine.element("div", attrs, kids)

	## A `div` whose class follows a value.
	div_s : Signal(ctx, Str), List(Elem(ctx)) -> Elem(ctx)
	div_s = |cls, kids| Engine.element("div", [Engine.class_s(cls)], kids)

	## A named region with extra attributes.
	section_attrs : Str, List(Attr(ctx)), List(Elem(ctx)) -> Elem(ctx)
	section_attrs = |name, attrs, kids| Engine.element("section", [Engine.attr("aria-label", name)].concat(attrs), kids)

	## A paragraph of static text with attributes.
	p_attrs : Str, List(Attr(ctx)) -> Elem(ctx)
	p_attrs = |t, attrs| Engine.element("p", attrs, [Engine.text(t)])

	## Preformatted text that follows a value.
	pre_s : Signal(ctx, Str), List(Attr(ctx)) -> Elem(ctx)
	pre_s = |v, attrs| Engine.element("pre", attrs, [Engine.text_s(v)])

	## A second-level heading whose text follows a value.
	h2_s : Signal(ctx, Str), List(Attr(ctx)) -> Elem(ctx)
	h2_s = |v, attrs| Engine.element("h2", attrs, [Engine.text_s(v)])

	## `h3(text, class)`: a third-level heading with static text.
	h3 : Str, Str -> Elem(ctx)
	h3 = |t, cls| Engine.element("h3", [Engine.class(cls)], [Engine.text(t)])

	## An unordered list; its children are usually `li` elements or an `each`.
	ul : List(Attr(ctx)), List(Elem(ctx)) -> Elem(ctx)
	ul = |attrs, kids| Engine.element("ul", attrs, kids)

	## A list item.
	li : List(Attr(ctx)), List(Elem(ctx)) -> Elem(ctx)
	li = |attrs, kids| Engine.element("li", attrs, kids)

	## `link(label, href, attrs)`: a link to `href` whose accessible name is its
	## label. Following it is ordinary browser navigation.
	link : Str, Str, List(Attr(ctx)) -> Elem(ctx)
	link = |label, href, attrs| Engine.element("a", [Engine.attr("href", href)].concat(attrs), [Engine.text(label)])

	## `label_for(text, for_id, attrs)`: a caption for the control whose `id` is `for_id`.
	label_for : Str, Str, List(Attr(ctx)) -> Elem(ctx)
	label_for = |t, for_id, attrs| Engine.element("label", [Engine.attr("for", for_id)].concat(attrs), [Engine.text(t)])

	# ---------------------------------------------------------- attributes

	## The accessible name (`aria-label`), which `label` and `role` locators match.
	aria_label : Str -> Attr(ctx)
	aria_label = |name| Engine.attr("aria-label", name)

	## An accessible name that follows a value.
	aria_label_s : Signal(ctx, Str) -> Attr(ctx)
	aria_label_s = |v| Engine.attr_s("aria-label", v)

	## Points at the `id` of the element that describes this one (such as an error message).
	aria_describedby : Str -> Attr(ctx)
	aria_describedby = |id| Engine.attr("aria-describedby", id)

	## `aria-invalid="true"` while the value is true, absent otherwise.
	aria_invalid : Signal(ctx, Bool) -> Attr(ctx)
	aria_invalid = |v| Html.flag_maybe("aria-invalid", v)

	## Disables the control while the value is true.
	disabled : Signal(ctx, Bool) -> Attr(ctx)
	disabled = |v| Html.flag("disabled", v)

	# --------------------------------------------------------------- events

	## Runs `handler` when the element or a descendant gains focus; the payload
	## is the control's value.
	on_focus : Handler(ctx) -> Attr(ctx)
	on_focus = |h| Engine.on("focus", h)

	## Runs `handler` when the element or a descendant loses focus; the payload
	## is the control's value.
	on_blur : Handler(ctx) -> Attr(ctx)
	on_blur = |h| Engine.on("blur", h)

	## Runs `handler` on every `input` event; the payload is the control's new value.
	on_input : Handler(ctx) -> Attr(ctx)
	on_input = |h| Engine.on("input", h)

	## Runs `handler` on `change`; the payload is `"true"`/`"false"` for a checkbox
	## or radio, otherwise the control's value.
	on_change : Handler(ctx) -> Attr(ctx)
	on_change = |h| Engine.on("change", h)

	## Runs `handler` when the form is submitted. Forms are app-managed: the
	## runtime always prevents the browser's default, so the page never navigates.
	on_submit : Handler(ctx) -> Attr(ctx)
	on_submit = |h| Engine.on("submit", h)

	# ------------------------------------------------------------- controls

	## `form(name, attrs, children)`: a form whose accessible name is `name`;
	## pair it with `on_submit`.
	form : Str, List(Attr(ctx)), List(Elem(ctx)) -> Elem(ctx)
	form = |name, attrs, kids| Engine.element("form", [Engine.attr("aria-label", name)].concat(attrs), kids)

	## A button whose label follows a value.
	button_s : Signal(ctx, Str), List(Attr(ctx)), Handler(ctx) -> Elem(ctx)
	button_s = |label, attrs, h| Engine.element("button", attrs.append(Engine.on_click(h)), [Engine.text_s(label)])

	## `action_button(label, disabled, attrs, handler)`: a button whose label
	## follows a value and that is disabled while `disabled` is true.
	action_button : Signal(ctx, Str), Signal(ctx, Bool), List(Attr(ctx)), Handler(ctx) -> Elem(ctx)
	action_button = |label, off, attrs, h| Engine.element("button", [Html.disabled(off)].concat(attrs).append(Engine.on_click(h)), [Engine.text_s(label)])

	## A button that submits its enclosing form (handle it with `on_submit`).
	submit_button : Str, List(Attr(ctx)) -> Elem(ctx)
	submit_button = |label, attrs| Engine.element("button", [Engine.attr("type", "submit")].concat(attrs), [Engine.text(label)])

	## `textarea(name, value, attrs, handler)`: a multi-line text box; behaves like
	## `text_input`.
	textarea : Signal(ctx, Str), Signal(ctx, Str), List(Attr(ctx)), Handler(ctx) -> Elem(ctx)
	textarea = |name, v, attrs, h| Engine.element("textarea", [Engine.attr_s("aria-label", name), Engine.prop_s(Engine.Prop.value, v), Engine.on("input", h)].concat(attrs), [])

	## `number_input(name, value, attrs, handler)`: a number box. `handler`
	## receives the draft text on every `input`; the app parses it, so a partial
	## entry like `"-"` is kept rather than rejected.
	number_input : Signal(ctx, Str), Signal(ctx, Str), List(Attr(ctx)), Handler(ctx) -> Elem(ctx)
	number_input = |name, v, attrs, h| Html.text_input(name, "number", v, attrs, h)

	## `radio(name, group, value, selected, attrs, handler)`: one radio of `group`,
	## checked while `selected` equals `value`. `handler` runs (payload `"true"`)
	## when the user picks it.
	radio : Str, Str, Str, Signal(ctx, Str), List(Attr(ctx)), Handler(ctx) -> Elem(ctx)
	radio = |name, group, value, selected, attrs, h| Engine.element(
		"input",
		[
			Engine.attr("aria-label", name),
			Engine.attr("type", "radio"),
			Engine.attr("name", group),
			Engine.prop(Engine.Prop.value, value),
			Engine.prop_s(Engine.Prop.checked, selected.map(|cur| cur == value)),
			Engine.on("change", h),
		].concat(attrs),
		[],
	)

	## An option with extra attributes.
	option_attrs : Str, Str, List(Attr(ctx)) -> Elem(ctx)
	option_attrs = |value, label, attrs| Engine.element("option", [Engine.prop(Engine.Prop.value, value)].concat(attrs), [Engine.text(label)])
}

bool_str : Bool -> Str
bool_str = |b| if (b) "true" else "false"
