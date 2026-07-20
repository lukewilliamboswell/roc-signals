import HostValue exposing [HostValue]

## Pure UI descriptor tree produced by `build`. This is the explicit data the
## host ingests. Structural UI identity comes from a deterministic pre-order host
## walk. Signal graph identity comes from boxed initializer/transform thunks that
## already exist to evaluate signal records, so signal construction does not need
## a separate token allocation.
##
## A `Signal` is an expression that references state/source binders through the
## binder's boxed initializer. The host resolves that alias identity to a dense
## id during its walk. Binder references reuse the initializer allocation;
## derived signal constructors allocate their own evaluator identity.
Node := [].{

	## Reference to a state/source binder. The boxed initializer thunk is shared by
	## the state declaration and all signal/message references to that declaration.
	## The host maps this pointer to the construction-order node id during the
	## active descriptor walk. The pointer carries binder alias identity while the
	## dense state/node identity remains host-owned.
	BinderRef := [BinderRef(Box((() -> HostValue)))]

	## Reducer message: applies `transform` to the bound source's current value.
	## The host routes a fired event to the referenced binder and applies the
	## transform. The payload fields use typed boundary descriptors in Roc; the
	## host derives compact dispatch descriptors when it ingests the ABI data.
	Msg := {
		binder : BinderRef,
		event_extraction_plan : EventExtractionPlan,
		payload_reducer : HostValue.EventReducerHandle,
	}

	## Signal expression. `Ref` reads a binder's current value. Other variants are
	## identified by their existing boxed initializer or transform thunk, so no
	## separate identity allocation is required. The explicit identity field is
	## retained in the ABI for now and contains the same allocation as the evaluator
	## field. `TaskSource` and `IntervalSource` are host-owned effect sources whose
	## results enter the same signal graph.
	TaskSource : {
		token : Box((() -> HostValue)),
		name : Str,
		cap : HostValue.CapabilityHandle,
		payload_cap : HostValue.CapabilityHandle,
		initial : Box((() -> HostValue)),
		done : Box((HostValue -> HostValue)),
		failed : Box((HostValue -> HostValue)),
		reset_on_start : Bool,
	}

	IntervalSource : {
		token : Box((() -> HostValue)),
		period_ms : U64,
		cap : HostValue.CapabilityHandle,
		initial : Box((() -> HostValue)),
		tick : Box((HostValue -> HostValue)),
	}

	SignalExpr := [
		Ref(BinderRef),
		ConstValue(Box((() -> HostValue)), Box((() -> HostValue)), HostValue.CapabilityHandle),
		LocationSource(Box((HostValue -> HostValue)), Box((HostValue -> HostValue)), HostValue.CapabilityHandle, HostValue.CapabilityHandle),
		StorageSource(Box((HostValue -> HostValue)), U64, Str, Box((HostValue -> HostValue)), HostValue.CapabilityHandle, HostValue.CapabilityHandle),
		VisibilitySource(Box((HostValue -> HostValue)), Box((HostValue -> HostValue)), HostValue.CapabilityHandle, HostValue.CapabilityHandle),
		Map(Box((HostValue -> HostValue)), Box(SignalExpr), Box((HostValue -> HostValue)), HostValue.CapabilityHandle),
		Map2(Box((HostValue, HostValue -> HostValue)), Box(SignalExpr), Box(SignalExpr), Box((HostValue, HostValue -> HostValue)), HostValue.CapabilityHandle),
		OnlineSource(Box((HostValue -> HostValue)), Box((HostValue -> HostValue)), HostValue.CapabilityHandle, HostValue.CapabilityHandle),
		Combine(Box((List(HostValue) -> HostValue)), List(SignalExpr), Box((List(HostValue) -> HostValue)), HostValue.CapabilityHandle),
		TaskSource(TaskSource),
		IntervalSource(IntervalSource),
	]

	## Host command emitted by lifecycle hooks or signal change sinks.
	Cmd := [
		Noop,
		PushState({ path : Str, query : Str, hash : Str }),
		ReplaceState({ path : Str, query : Str, hash : Str }),
		SetStorageText({ area : U64, key : Str, value : Str }),
		RemoveStorage({ area : U64, key : Str }),
		StartTask(
			{
				task_token : Box((() -> HostValue)),
				task_name : Str,
				request_init : Box((() -> HostValue)),
				request_read : HostValue.TaskRequestReadHandle,
			},
		),
		SetDocumentTitle({ title : Str }),
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
		TextOptionalSignal({ field : TextField, name : Str, signal : Box(SignalExpr), present : HostValue.BoolReadHandle, read : HostValue.TextReadHandle }),
		StaticBool({ field : BoolField, name : Str, value : Bool }),
		SignalBool({ field : BoolField, name : Str, signal : Box(SignalExpr), read : HostValue.BoolReadHandle }),
		On(EventBinding),
	]

	## Event binding descriptor attached to an element.
	EventBinding := { kind : FixedEventKind, msg : Msg, policy : EventPolicy, delivery : EventDelivery, name : Str }
}
