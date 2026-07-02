import HostValue exposing [HostValue]

## Pure UI descriptor tree produced by `build`. This is the explicit data the
## host ingests. Identity is NOT threaded in Roc: the tree is immutable and pure,
## and the host assigns construction-order identity by a deterministic pre-order
## walk. Only identity-bearing nodes (state binders, `when` sites, `each` sites)
## advance the per-scope ordinal in that walk; ordinary markup does not.
##
## A `Signal` is an expression that references state/source binders by a binder
## ref (a path-relative index assigned during the host walk). Declaration of a
## binder (via `Ui.state`) mints identity; a use (`map`, sink) does not.
Node := [].{

	new_token : {} -> Box(U64)
	new_token = |_| Box.box(0)

	## Reference to a state/source binder. The token is minted by `Ui.state` and
	## copied into both the state declaration and all signal/message references to
	## that declaration. The host maps tokens to construction-order node ids during
	## the active descriptor walk; the token is not the state identity.
	BinderRef := [BinderRef(Box(U64))]

	## Reducer message: applies `transform` to the bound source's current value.
	## The host routes a fired event to the referenced binder and applies the
	## transform. The payload fields use typed boundary descriptors in Roc; the
	## host derives compact dispatch descriptors when it ingests the ABI data.
	Msg := {
		binder : BinderRef,
		event_extraction_plan : EventExtractionPlan,
		payload_reducer : HostValue.EventReducerHandle,
	}

	## Signal expression. `Ref` reads a binder's current value. Other variants
	## carry a copied token allocated at the typed signal construction site, so the
	## host can identify shared derived nodes from explicit data. `ConstValue`
	## carries a boxed value initializer plus output equality. `Map`/`Map2`/
	## `Combine` are derived nodes carrying boxed typed transforms (confined
	## erasure) and a boxed `is_eq` thunk for change pruning. `TaskSource` and
	## `IntervalSource` are host-owned effect sources whose results enter the
	## same signal graph.
	TaskSource : {
		token : Box(U64),
		name : Str,
		cap : HostValue.CapabilityHandle,
		payload_cap : HostValue.CapabilityHandle,
		initial : Box(({} -> HostValue)),
		done : Box((HostValue -> HostValue)),
		failed : Box((HostValue -> HostValue)),
		reset_on_start : Bool,
	}

	IntervalSource : {
		token : Box(U64),
		period_ms : U64,
		cap : HostValue.CapabilityHandle,
		initial : Box(({} -> HostValue)),
		tick : Box((HostValue -> HostValue)),
	}

	SignalExpr := [
		Ref(BinderRef),
		ConstValue(Box(U64), Box(({} -> HostValue)), HostValue.CapabilityHandle),
		Map(Box(U64), Box(SignalExpr), Box((HostValue -> HostValue)), HostValue.CapabilityHandle),
		Map2(Box(U64), Box(SignalExpr), Box(SignalExpr), Box((HostValue, HostValue -> HostValue)), HostValue.CapabilityHandle),
		Combine(Box(U64), List(SignalExpr), Box((List(HostValue) -> HostValue)), HostValue.CapabilityHandle),
		TaskSource(TaskSource),
		IntervalSource(IntervalSource),
	]

	## Host command emitted by lifecycle hooks or signal change sinks.
	Cmd := [
		StartTask(
			{
				task_token : Box(U64),
				task_name : Str,
				request_init : Box(({} -> HostValue)),
				request_read : HostValue.TaskRequestReadHandle,
			},
		),
	]

	## Cleanup descriptor run when a scope is disposed.
	Cleanup := [
		Cleanup(Str),
	]

	## Numeric text-field id used by the render wire protocol.
	TextField := { id : U64 }

	## Numeric bool-field id used by the render wire protocol.
	BoolField := { id : U64 }

	## Numeric fixed-event id used by the render wire protocol.
	FixedEventKind := { id : U64 }

	## Requested event delivery mode for the host listener.
	EventDelivery := { native : Bool }

	## Compact host-side event payload extraction descriptor.
	EventExtractionPlan := { bytes : List(U8) }

	## Browser listener options requested by an event binding.
	EventPolicy : {
		prevent_default : Bool,
		stop_propagation : Bool,
		stop_immediate : Bool,
		capture : Bool,
		passive : Bool,
		once : Bool,
		self : Bool,
		trusted : Bool,
	}

	## Static attribute on a markup element. Dynamic (signal-backed) attrs carry a
	## `SignalExpr`; event handlers carry a `Msg`.
	Attr := [
		StaticText({ field : TextField, name : Str, value : Str }),
		SignalText({ field : TextField, name : Str, signal : Box(SignalExpr), read : HostValue.TextReadHandle }),
		StaticBool({ field : BoolField, name : Str, value : Bool }),
		SignalBool({ field : BoolField, name : Str, signal : Box(SignalExpr), read : HostValue.BoolReadHandle }),
		On(EventBinding),
	]

	## Event binding descriptor attached to an element.
	EventBinding := { kind : FixedEventKind, msg : Msg, policy : EventPolicy, delivery : EventDelivery, name : Str }
}
