import Val

## Platform-private descriptor vocabulary shared by `Html`, `Ui` and `Action`.
## Applications name these through the public aliases `Ui.Handler(ctx)`,
## `Html.Attr(ctx)` and `Ui.StateWrite`, never through this module.
Node := [].{

	## What the host extracts from a DOM event before the handler runs.
	Payload : [Unit, Text(Str), Checked(Bool)]

	## Sketch stand-in for a state destination and its typed reducer. In the
	## Roc-owned engine this is an index into the engine `State` plus an erased
	## reducer created once per construction site.
	StateWrite :: { binder : U64, reduce : Box((U64 -> U64)) }

	## A command the engine applies after an event: a batch of state writes.
	Cmd :: [Noop, Writes(List(StateWrite))]

	## An event handler readable in context `ctx`. When it fires at a row, the
	## engine supplies that row's context (its key and item, and the keys and
	## items of every enclosing row), so nothing about the row is captured.
	Handler(ctx) :: {
		extract : [Unit, TargetValue, TargetChecked],
		run : Box((ctx, Payload -> Cmd)),
	}

	## An attribute in context `ctx`.
	Attr(ctx) :: [
		StaticText({ name : Str, value : Str }),
		DynText({ name : Str, value : Val(ctx, Str) }),
		DynBool({ name : Str, value : Val(ctx, Bool) }),
		On({ event : Str, handler : Handler(ctx) }),
	]

	noop : Cmd
	noop = Noop

	writes : List(StateWrite) -> Cmd
	writes = |list| Writes(list)

	handler : [Unit, TargetValue, TargetChecked], (ctx, Payload -> Cmd) -> Handler(ctx)
	handler = |extract, run| { extract, run: Box.box(run) }

	state_write : U64, (U64 -> U64) -> StateWrite
	state_write = |binder, reduce| { binder, reduce: Box.box(reduce) }

	static_text : Str, Str -> Attr(ctx)
	static_text = |name, value| StaticText({ name, value })

	dyn_text : Str, Val(ctx, Str) -> Attr(ctx)
	dyn_text = |name, value| DynText({ name, value })

	dyn_bool : Str, Val(ctx, Bool) -> Attr(ctx)
	dyn_bool = |name, value| DynBool({ name, value })

	on : Str, Handler(ctx) -> Attr(ctx)
	on = |event, h| On({ event, handler: h })
}
