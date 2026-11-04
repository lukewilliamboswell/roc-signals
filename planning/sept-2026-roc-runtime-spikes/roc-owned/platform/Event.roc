import Node

## Events never reach Roc as objects. A control binds an `Event.Handler`, which
## names the payload the host must extract from the event and the reducer or
## action that consumes it; the host serializes only that payload and the
## engine runs the handler through ordinary propagation. `State.update` and
## `Ui.action` build handlers; controls such as `Elem.button` accept them.
Event := [].{
	## What an event does when it fires: extract the declared payload shape,
	## then either reduce one state or run an action that returns commands.
	## Application code builds handlers and hands them to controls; it never
	## inspects one.
	Handler : Node.Handler

	## An exact key plus every modifier, matched as a whole by `shortcuts`.
	KeyChord : Node.KeyChord
}
