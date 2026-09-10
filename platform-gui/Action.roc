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
	## returns. The effect runs on the UI thread and may call `!` functions;
	## keep it short or it blocks rendering until it returns. Effects whose
	## owning scope is disposed before they run are dropped.
	then : List(Ui.StateWrite), (a => Action(a)) -> Action(a)
	then = |changes, effect!| {
		# The engine hands back the snapshot and the capability that validates it,
		# so nothing here has to capture a capability: with a capture-free
		# effect this closure is itself capture-free.
		run_effect! : HostValue, HostValue.CapabilityHandle => Node.Cmd
		run_effect! = |snapshot_hv, capability| {
			snapshot : a
			snapshot = Box.unbox(HostValue.get_with_capability!(snapshot_hv, capability))
			to_cmd(effect!(snapshot))
		}
		Action(Node.Cmd.Then({ changes, effect: Box.box(run_effect!) }))
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

	## Run an action on every tick of a scoped interval; the reads are the
	## tick count.
	every : U64, (U64 -> Action(U64)) -> Elem
	every = |period_ms, to_action| Ui.on_change(Signal.interval(period_ms), |tick| to_cmd(to_action(tick)))
}
