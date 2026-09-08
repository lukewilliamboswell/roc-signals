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

	## An accepted event's extraction plan and declared handler. Reducers replace
	## a bound source; actions read a settled signal snapshot and produce a
	## command. The host derives the compact payload descriptor at ingestion.
	Msg := { event_extraction_plan : EventExtractionPlan, handler : EventHandler }

	## Reducers replace one state value; actions describe commands for each
	## accepted event. An action's reads are explicit graph data, not a callback
	## that discovers dependencies or runs when a displayed value changes.
	EventHandler := [
		Reduce({ binder : BinderRef, read_binder : BinderRef, payload_reducer : HostValue.EventReducerHandle }),
		Action({ reads : Box(SignalExpr), payload_cap : HostValue.CapabilityHandle, to_cmd : Box((HostValue, HostValue -> Cmd)) }),
	]

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
		RowSource(U64, Box((() -> HostValue)), Box((() -> HostValue)), HostValue.CapabilityHandle),
		EntropySeedSource(Box((HostValue -> HostValue)), Box((HostValue -> HostValue)), HostValue.CapabilityHandle, HostValue.CapabilityHandle),
		LocationSource(Box((HostValue -> HostValue)), Box((HostValue -> HostValue)), HostValue.CapabilityHandle, HostValue.CapabilityHandle),
		StorageSource(Box((HostValue -> HostValue)), U64, Str, Box((HostValue -> HostValue)), HostValue.CapabilityHandle, HostValue.CapabilityHandle),
		VisibilitySource(Box((HostValue -> HostValue)), Box((HostValue -> HostValue)), HostValue.CapabilityHandle, HostValue.CapabilityHandle),
		KeyedSelect(U64, Box((() -> HostValue)), Box(SignalExpr), Str, HostValue.TextReadHandle, Box((() -> HostValue)), Box((() -> HostValue)), HostValue.CapabilityHandle),
		Map(Box((HostValue -> HostValue)), Box(SignalExpr), Box((HostValue -> HostValue)), HostValue.CapabilityHandle),
		Map2(Box((HostValue, HostValue -> HostValue)), Box(SignalExpr), Box(SignalExpr), Box((HostValue, HostValue -> HostValue)), HostValue.CapabilityHandle),
		Select(Box((() -> HostValue)), Box(SignalExpr), Str, HostValue.TextReadHandle, Box((() -> HostValue)), Box((() -> HostValue)), HostValue.CapabilityHandle),
		OnlineSource(Box((HostValue -> HostValue)), Box((HostValue -> HostValue)), HostValue.CapabilityHandle, HostValue.CapabilityHandle),
		Combine(Box((List(HostValue) -> HostValue)), List(SignalExpr), Box((List(HostValue) -> HostValue)), HostValue.CapabilityHandle),
		TaskSource(TaskSource),
		IntervalSource(IntervalSource),
	]

	## One reusable proposed state replacement. Its initializer captures the
	## typed next value; the host creates an owned value only when executing it.
	StateWrite := { binder : BinderRef, update : HostValue.StateValueHandle }

	## Host command emitted by event actions, lifecycle hooks, or signal changes.
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
		UpdateState(StateWrite),
		UpdateStates(List(StateWrite)),
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
