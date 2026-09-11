import Capability
import Elem exposing [Elem]
import HostValue exposing [HostValue]
import Node
import Signal exposing [Signal]
import Ui

## What an event does. An action is data the engine interprets: a batch of
## state changes, or a batch followed by effectful Roc code whose result is the
## next action. `run` binds an action to an event; the declared reads are
## snapshotted when the event fires and again, freshly, before each effect.
##
## Every state change is a reducer applied at its own commit against the value
## the state holds then, so a chain that waited on an effect never writes a
## value it captured before the effect ran. The type parameter is the type of
## the declared reads, which is also what each effect receives.
Action(a) := [Action(Node.Cmd)].{
	## Change nothing.
	none : Action(a)
	none = Action(Node.Cmd.Noop)

	## Apply these changes atomically. Duplicate targets are an error.
	update : List(Ui.StateWrite) -> Action(a)
	update = |changes| Action(Node.Cmd.UpdateChanges(changes))

	## Apply these changes atomically, then run `effect` after that commit with
	## a fresh snapshot of the declared reads, then continue with the action it
	## returns. The effect may call `!` functions and runs on its own worker
	## thread, so it never blocks rendering. Disposing the owning scope does
	## not cancel it: the effect reparents to the nearest live scope, and its
	## result applies to the states that still exist.
	then : List(Ui.StateWrite), (a => Action(a)) -> Action(a)
	then = |changes, effect!| {
		# The engine hands back the snapshot and the capability that validates it,
		# so nothing here has to capture a capability: with a capture-free
		# effect this closure is itself capture-free. Decoding the snapshot
		# touches host-owned values, so it happens on the UI thread; the thunk
		# it returns holds plain Roc values and runs on the effect worker.
		prepare_effect! : HostValue, HostValue.CapabilityHandle => Box((() => Node.Cmd))
		prepare_effect! = |snapshot_hv, capability| {
			snapshot : a
			snapshot = Box.unbox(HostValue.get_with_capability!(snapshot_hv, capability))
			run! : () => Node.Cmd
			run! = || to_cmd(effect!(snapshot))
			Box.box(run!)
		}
		Action(Node.Cmd.Then({ changes, effect: Box.box(prepare_effect!) }))
	}

	to_cmd : Action(a) -> Node.Cmd
	to_cmd = |action| match action {
		Action(cmd) => cmd
	}

	## Bind an action to a unit event such as a click or a shortcut. `reads`
	## are snapshotted when the event fires; equal events remain separate
	## occurrences, and a change in the reads alone never runs the action.
	run : Signal(a), (a -> Action(a)) -> Node.Handler
	run = |reads, to_action| Ui.action(reads, |snapshot| to_cmd(to_action(snapshot)))

	## Bind an action to a text-valued event.
	run_str : Signal(a), (a, Str -> Action(a)) -> Node.Handler
	run_str = |reads, to_action| Ui.action_str(reads, |snapshot, text| to_cmd(to_action(snapshot, text)))

	## Bind an action to a checkbox event.
	run_bool : Signal(a), (a, Bool -> Action(a)) -> Node.Handler
	run_bool = |reads, to_action| Ui.action_bool(reads, |snapshot, checked| to_cmd(to_action(snapshot, checked)))

	## Bind an action to a drop or other string-detail event.
	run_detail : Signal(a), (a, Str -> Action(a)) -> Node.Handler
	run_detail = |reads, to_action| Ui.action_detail(reads, |snapshot, detail| to_cmd(to_action(snapshot, detail)))

	## Bind an action to a key event.
	run_key : Signal(a), (a, Ui.KeyPayload -> Action(a)) -> Node.Handler
	run_key = |reads, to_action| Ui.action_key(reads, |snapshot, key| to_cmd(to_action(snapshot, key)))

	## Run an action whenever the signal's value changes; the value is the
	## action's reads.
	on_change : Signal(a), (a -> Action(a)) -> Elem
	on_change = |signal, to_action| Ui.on_change(signal, |value| to_cmd(to_action(value)))

	## Like `on_change`, and also once for the first mounted value.
	on_change_initial : Signal(a), (a -> Action(a)) -> Elem
	on_change_initial = |signal, to_action| Ui.on_change_initial(signal, |value| to_cmd(to_action(value)))

	## Run an action when the owning scope first mounts. The reads are the
	## unit value, so an effect in the chain receives `{}`.
	on_mount : (() -> Action({})) -> Elem
	on_mount = |to_action| Ui.on_change_initial(Signal.const({}), |_| to_cmd(to_action()))

	## Run an action on every tick of a scoped interval, with `reads` as they
	## are at that tick. A change to the reads between ticks does not run it.
	every : U64, Signal(a), (a -> Action(a)) -> Elem
	every = |period_ms, reads, to_action| Ui.on_change(sampled(Signal.interval(period_ms), reads), |value| to_cmd(to_action(value)))

	## `reads` as they are at each change of `trigger`, published only then:
	## the pair signal compares ticks alone, so a reads change between ticks
	## is pruned, and the projection never compares equal, so every tick
	## publishes even when the reads did not change.
	sampled : Signal(U64), Signal(a) -> Signal(a)
	sampled = |trigger, reads| {
		pair_cap : Capability.Capability({ tick : U64, value : a })
		pair_cap = Capability.new_with_eq(|left, right| left.tick == right.tick)
		pair : HostValue, HostValue -> HostValue
		pair = |tick_hv, reads_hv| {
			tick : U64
			tick = Box.unbox(Capability.get(tick_hv, trigger.cap))
			value : a
			value = Box.unbox(Capability.get(reads_hv, reads.cap))
			Capability.store(Box.box({ tick, value }), pair_cap)
		}
		pair_box = Box.box(pair)
		paired : Signal({ tick : U64, value : a })
		paired = Signal.from_expr(Node.SignalExpr.Map2(pair_box, Signal.to_expr(trigger), Signal.to_expr(reads), pair_box, Capability.handle(pair_cap)), pair_cap)
		value_cap : Capability.Capability(a)
		value_cap = Capability.new_with_eq(|_, _| False)
		project : HostValue -> HostValue
		project = |pair_hv| {
			current : { tick : U64, value : a }
			current = Box.unbox(Capability.get(pair_hv, pair_cap))
			Capability.store(Box.box(current.value), value_cap)
		}
		project_box = Box.box(project)
		Signal.from_expr(Node.SignalExpr.Map(project_box, Signal.to_expr(paired), project_box, Capability.handle(value_cap)), value_cap)
	}
}
