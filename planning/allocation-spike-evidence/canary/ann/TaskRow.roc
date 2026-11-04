import pf.Elem
import pf.Html
import pf.Signal
import pf.Ui

## A packaged task row. Written first as an ordinary component, then as the
## nearest template shapes.
TaskRow := [].{
	## Independent inputs: separate signals, per design.md Component boundaries.
	Inputs : { title : Signal(Str), done : Signal(Bool) }

	## Static configuration.
	Config : { label : Str }

	## Ordinary row. The handler type cannot be named, see report: annotation omitted.
	view : Str, Inputs, Config, (Str -> Node.Handler) -> Elem
	view = |key, inputs, config, on_remove|
		Ui.component(
			|| li(
				[Html.test_id("row-${key}")],
				[
					Html.text("${config.label}: "),
					Html.text_s(inputs.title),
					Ui.when(inputs.done, || Html.text(" (done)"), || Html.text(" (open)")),
					Html.button_attrs("Remove ${key}", [], on_remove(key)),
				],
			),
		)

	## Same requirements at a template site: the row has no item and no key value,
	## so inputs can only come from the site and the callback cannot receive a key.
	full_template = |row, inputs, config, on_remove|
		li(
			[row.keyed_attr(Html.test_id("row-"))],
			[
				Html.text("${config.label}: "),
				Html.text_s(inputs.title),
				Ui.when(inputs.done, || Html.text(" (done)"), || Html.text(" (open)")),
				Html.button_attrs("Remove", [], on_remove),
			],
		)

	## One forbidden feature at a time.
	signal_only : Ui.TemplateRow, Signal(Str) -> Elem
	signal_only = |row, title| li([row.keyed_attr(Html.test_id("row-"))], [Html.text_s(title)])

	event_only = |row, handler| li([row.keyed_attr(Html.test_id("row-"))], [Html.button_attrs("Remove", [], handler)])

	when_only : Ui.TemplateRow, Signal(Bool) -> Elem
	when_only = |row, done| li([row.keyed_attr(Html.test_id("row-"))], [Ui.when(done, || Html.text("yes"), || Html.text("no"))])

	component_only : Ui.TemplateRow -> Elem
	component_only = |row| Ui.component(|| li([row.keyed_attr(Html.test_id("row-"))], [Html.text("x")]))

	## What survives: label, key text, and a plain link as the only "action".
	static_template : Ui.TemplateRow, Config -> Elem
	static_template = |row, config|
		li(
			[row.keyed_attr(Html.test_id("row-"))],
			[
				Html.text("${config.label}: "),
				row.key_text(),
				element("a", [row.keyed_attr(Html.attr("href", "#/remove/")), row.keyed_attr_with(Html.aria_label("Remove "), " task")], [Html.text("Remove")]),
			],
		)

	## Precomputed conditional: two lists of keys, each with its own static row.
	done_template : Ui.TemplateRow, Config, Bool -> Elem
	done_template = |row, config, done|
		li(
			[row.keyed_attr(Html.test_id("row-"))],
			[Html.text("${config.label}: "), row.key_text(), Html.text(if done { " (done)" } else { " (open)" })],
		)

	li : List(Html.Attr), List(Elem) -> Elem
	li = |attrs, children| element("li", attrs, children)

	element : Str, List(Html.Attr), List(Elem) -> Elem
	element = |tag, attrs, children| Elem.Element({ namespace: Html, tag, attrs, children })
}
