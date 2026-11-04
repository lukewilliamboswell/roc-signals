import DUi exposing [Val, Handler, Elem, In]

## The 0b canary's packaged row, on representation D's API. Generic in `ctx`:
## used at the root and in every row of an `each`. Differences from 0b: the
## row-local state is `DUi.state` (one column per site inside a row), and every
## input crossing into that state's body is lifted explicitly.
TaskRow := [].{
	Inputs(ctx) : {
		title : Val(ctx, Str),
		done : Val(ctx, Bool),
		selected : Val(ctx, Bool),
		test_id : Val(ctx, Str),
	}

	Config : { label : Str, done_text : Str }

	Callbacks(ctx) : { on_remove : Handler(ctx), on_toggle : Handler(ctx) }

	view : Inputs(ctx), Config, Callbacks(ctx) -> Elem(ctx)
	view = |inputs, config, callbacks|
		DUi.component(
			|| DUi.state(
				Bool.False,
				|details_open| {
					title = inputs.title.lift()
					done = inputs.done.lift()
					row_class = inputs.selected.lift().map(|selected| if selected "task selected" else "task")
					DUi.element(
						"li",
						[DUi.class_v(row_class), DUi.test_id_v(inputs.test_id.lift())],
						[
							DUi.text("${config.label}: "),
							DUi.text_v(title),
							DUi.checkbox("Done", done, callbacks.on_toggle.lift()),
							DUi.when(
								done,
								|| DUi.element("span", [DUi.class_attr("badge")], [DUi.text(config.done_text)]),
								|| DUi.text(""),
							),
							DUi.button("Details", details_open.update(|open| !open)),
							DUi.when(
								details_open.val(),
								|| DUi.element("p", [], [DUi.text("Title: "), DUi.text_v(title)]),
								|| DUi.text(""),
							),
							DUi.button("Remove", callbacks.on_remove.lift()),
						],
					)
				},
			),
		)
}
