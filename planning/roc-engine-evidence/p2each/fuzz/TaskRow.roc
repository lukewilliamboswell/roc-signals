import Engine exposing [Val, Handler, Elem]

## The 0b/1b canary's packaged row on the unified engine. Generic in `ctx`:
## used at the root and in every row of an `each`. The row-local state is
## `Engine.state` (one state site per row instance); every input crossing
## into that state's body is lifted explicitly.
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
		Engine.component(
			|| Engine.state(
				Bool.False,
				|details_open| {
					title = inputs.title.lift()
					done = inputs.done.lift()
					row_class = inputs.selected.lift().map(|selected| if selected "task selected" else "task")
					Engine.element(
						"li",
						[Engine.class_v(row_class), Engine.test_id_v(inputs.test_id.lift())],
						[
							Engine.text("${config.label}: "),
							Engine.text_v(title),
							Engine.checkbox("Done", done, callbacks.on_toggle.lift()),
							Engine.when(
								done,
								|| Engine.element("span", [Engine.class("badge")], [Engine.text(config.done_text)]),
								|| Engine.text(""),
							),
							Engine.button("Details", details_open.update(|open| !open)),
							Engine.when(
								details_open.val(),
								|| Engine.element("p", [], [Engine.text("Title: "), Engine.text_v(title)]),
								|| Engine.text(""),
							),
							Engine.button("Remove", callbacks.on_remove.lift()),
						],
					)
				},
			),
		)
}
