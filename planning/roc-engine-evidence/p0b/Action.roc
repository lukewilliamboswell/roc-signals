import Node
import Val

## What an event does, unchanged in spirit. `run` now takes any context value
## as its reads, so a row handler reads the row key (or any row field) when it
## fires instead of capturing it while the template is built.
Action(a) :: [Action(Node.Cmd)].{

	none : () -> Action(a)
	none = || Action(Node.noop)

	## Apply these root-state writes atomically.
	update : List(Node.StateWrite) -> Action(a)
	update = |changes| Action(Node.writes(changes))

	## Bind an action to a unit event; `reads` are read at the firing context.
	run : v, (a -> Action(a)) -> Node.Handler(ctx)
		where [
			v.to_val : v -> Val(ctx, a),
		]
	run = |_reads, _to_action| Node.handler(Unit, |_ctx, _payload| crash "sketch")

	## Bind an action to a text-valued event.
	run_str : v, (a, Str -> Action(a)) -> Node.Handler(ctx)
		where [
			v.to_val : v -> Val(ctx, a),
		]
	run_str = |_reads, _to_action| Node.handler(TargetValue, |_ctx, _payload| crash "sketch")
}
