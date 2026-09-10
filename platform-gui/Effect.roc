import HostValue exposing [HostValue]
import Node
import Signal exposing [Signal]
import Capability

## Run Roc effectful code from an application. `main` and every handler are
## pure, so `!` functions such as those a third-party package exposes can only
## be called inside the closure given to `run`. The closure runs as a task: a
## handler returns the command, the host runs the closure on the UI thread
## after the event's transaction commits, and the outcome re-enters the graph
## as the task's `Loading`, `Done`, or `Failed` status like every other task.
## Starting a task whose closure is still queued cancels the older request;
## a closure that already began cannot be interrupted, and its result is
## discarded if the request was superseded.
Effect := [].{
	## Declare an effect task. `to_done` and `to_failed` decode the text the
	## closure returns; the task's status signal reads through `Signal.from_task`.
	task : Str, (Str -> a), (Str -> err) -> Signal.Task(a, err)
		where [
			a.is_eq : a, a -> Bool,
			err.is_eq : err, err -> Bool,
		]
	task = |name, to_done, to_failed|
		Signal.host_task_source_with_eq(
			Node.TaskKind.Effect,
			{ name, reset_on_start: True, canceled: || to_failed("canceled"), refused: || to_failed("refused") },
			to_done,
			to_failed,
			|left, right| left.is_eq(right),
			|left, right| left.is_eq(right),
		)

	## Command that runs `closure` for `task`. `Ok(text)` becomes the task's
	## `Done` value through `to_done`; `Err(text)` becomes `Failed` through
	## `to_failed`.
	run : Signal.Task(a, err), (() => Try(Str, Str)) -> Node.Cmd
	run = |effect_task, closure| {
		# Closures have no equality; the capability only validates the value.
		closure_cap = Capability.new_with_eq(|_, _| False)
		request_init : () -> HostValue
		request_init = || Capability.store(Box.box(closure), closure_cap)
		# The engine takes the closure itself for an effect task and never reads
		# request text; the reader only carries the capability that validates it.
		request_read : HostValue -> Str
		request_read = |_| ""
		Node.Cmd.StartTask({
			task_token: effect_task.source.token,
			task_name: effect_task.source.name,
			request_init: Box.box(request_init),
			request_read: { capability: Capability.handle(closure_cap), read: Box.box(request_read) },
		})
	}

	## Run one boxed effect closure and flatten its outcome for the host. The
	## platform provides this to the host as `roc_run_effect`.
	run_boxed! : Box((() => Try(Str, Str))) => { failed : Bool, text : Str }
	run_boxed! = |closure_box| {
		closure! = Box.unbox(closure_box)
		match closure!() {
			Ok(text) => { failed: False, text }
			Err(text) => { failed: True, text }
		}
	}
}
