import pf.Elem
import pf.Html
import pf.Ui
import pf.Val

## A packaged task row, as a package would export it. It is generic in its
## context `ctx`: the same function renders one task at the root, or every row
## of a `Ui.each` site. It never sees a key, a row handle or a host id.
TaskRow := [].{

	## Independent inputs: each field changes on its own, so a title edit never
	## re-evaluates `done`, and selection never re-evaluates the title.
	Inputs(ctx) : {
		title : Val(ctx, Str),
		done : Val(ctx, Bool),
		selected : Val(ctx, Bool),
		test_id : Val(ctx, Str),
	}

	## Static configuration, shared by every instance at a site.
	Config : { label : Str, done_text : Str }

	## Actions supplied by the caller. The caller decides what "remove" means
	## and how it learns which row fired; the component just binds them.
	Callbacks(ctx) : { on_remove : Ui.Handler(ctx), on_toggle : Ui.Handler(ctx) }

	view : Inputs(ctx), Config, Callbacks(ctx) -> Elem(ctx)
	view = |inputs, config, callbacks|
		Ui.component(
			|| Ui.local(
				False,
				|details_open| {
					row_class = inputs.selected.map(|selected| if selected { "task selected" } else { "task" })
					Html.element(
						"li",
						[Html.class_attr_s(row_class), Html.test_id_s(inputs.test_id)],
						[
							Html.text("${config.label}: "),
							Html.text_s(inputs.title),
							Html.checkbox("Done", inputs.done, callbacks.on_toggle),
							## Conditional child: a per-instance branch over a context value.
							Ui.when(
								inputs.done,
								|| Html.element("span", [Html.class_attr("badge")], [Html.text(config.done_text)]),
								|| Html.text(""),
							),
							## Conditional child driven by row-local state, containing a
							## row value.
							Html.button("Details", details_open.update(|open| !open)),
							Ui.when(
								details_open,
								|| Html.element("p", [], [Html.text("Title: "), Html.text_s(inputs.title)]),
								|| Html.text(""),
							),
							Html.button("Remove", callbacks.on_remove),
						],
					)
				},
			),
		)
}
