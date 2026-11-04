import HostValue exposing [HostValue]

## Experimental Roc-interpreted descriptors. State and constant identity reuse
## their capability token; derived identity reuses its evaluator allocation.
## The runtime resolves these aliases to dense graph ids during ingestion.
Node := [].{

	## State references share its capability token, not a second initializer box.
	BinderRef := [BinderRef(Box((() -> {})))]

	## An accepted event's extraction plan and declared handler. Reducers replace
	## a bound source; actions read a settled signal snapshot and produce a
	## command. The host derives the compact payload descriptor at ingestion.
	Handler := { event_extraction_plan : EventExtractionPlan, handler : EventHandler }

	## Reducers replace one state value; actions describe commands for each
	## accepted event. An action's reads are explicit graph data, not a callback
	## that discovers dependencies or runs when a displayed value changes.
	EventHandler := [
		Reduce({ binder : BinderRef, read_binder : BinderRef, payload_reducer : HostValue.EventReducerHandle }),
		Action({ reads : Box(SignalExpr), payload_cap : HostValue.CapabilityHandle, to_cmd : Box((HostValue, HostValue -> Cmd)) }),
	]

	## A scope-owned timer whose ticks update an ordinary source in the graph.
	IntervalSource : {
		token : Box((() -> HostValue)),
		period_ms : U64,
		cap : HostValue.CapabilityHandle,
		initial : Box((() -> HostValue)),
		tick : Box((HostValue -> HostValue)),
	}

	## Map evaluators receive the previous output and decide the typed cutoff before
	## allocating a replacement carrier. Source initial values are already Roc-owned.
	## Other variants retain their legacy shape and are outside this runtime's subset.
	SignalExpr := [
		Ref(BinderRef),
		ConstValue(Box((() -> {})), HostValue, HostValue.CapabilityHandle),
		RowSource(U64, Box((() -> HostValue)), Box((() -> HostValue)), HostValue.CapabilityHandle),
		EntropySeedSource(Box((HostValue -> HostValue)), Box((HostValue -> HostValue)), HostValue.CapabilityHandle, HostValue.CapabilityHandle),
		LocationSource(Box((HostValue -> HostValue)), Box((HostValue -> HostValue)), HostValue.CapabilityHandle, HostValue.CapabilityHandle),
		StorageSource(Box((HostValue -> HostValue)), U64, Str, Box((HostValue -> HostValue)), HostValue.CapabilityHandle, HostValue.CapabilityHandle),
		VisibilitySource(Box((HostValue -> HostValue)), Box((HostValue -> HostValue)), HostValue.CapabilityHandle, HostValue.CapabilityHandle),
		KeyedSelect(U64, Box((() -> HostValue)), Box(SignalExpr), Str, HostValue.TextReadHandle, Box((() -> HostValue)), Box((() -> HostValue)), HostValue.CapabilityHandle),
		Map(Box((HostValue, HostValue.Previous -> HostValue.Change)), Box(SignalExpr), Box((HostValue, HostValue.Previous -> HostValue.Change)), HostValue.CapabilityHandle),
		Map2(Box((HostValue, HostValue, HostValue.Previous -> HostValue.Change)), Box(SignalExpr), Box(SignalExpr), Box((HostValue, HostValue, HostValue.Previous -> HostValue.Change)), HostValue.CapabilityHandle),
		Select(Box((() -> HostValue)), Box(SignalExpr), Str, HostValue.TextReadHandle, Box((() -> HostValue)), Box((() -> HostValue)), HostValue.CapabilityHandle),
		OnlineSource(Box((HostValue -> HostValue)), Box((HostValue -> HostValue)), HostValue.CapabilityHandle, HostValue.CapabilityHandle),
		Combine(Box((List(HostValue) -> HostValue)), List(SignalExpr), Box((List(HostValue) -> HostValue)), HostValue.CapabilityHandle),
		IntervalSource(IntervalSource),
	]

	## One reusable proposed state replacement. Its initializer captures the
	## typed next value; the host creates an owned value only when executing it.
	StateWrite := { binder : BinderRef, update : HostValue.StateValueHandle }

	## A command-local read and replacement of one explicitly named state.
	StateTransform := {
		binder : BinderRef,
		capability : HostValue.CapabilityHandle,
		transform : Box((HostValue -> HostValue)),
	}

	## One state change in an atomic batch: replace the value outright, or
	## reduce whatever the state holds when the batch commits.
	StateChange := [
		Set(StateWrite),
		Transform(StateTransform),
	]

	## Host command emitted by event actions, lifecycle hooks, or signal changes.
	Cmd := [
		Noop,
		PushState({ path : Str, query : Str, hash : Str }),
		ReplaceState({ path : Str, query : Str, hash : Str }),
		SetStorageText({ area : U64, key : Str, value : Str }),
		RemoveStorage({ area : U64, key : Str }),
		SetDocumentTitle({ title : Str }),
		UpdateState(StateWrite),
		UpdateStates(List(StateWrite)),
		UpdateTransform(StateTransform),
		UpdateChanges(List(StateChange)),
		Then(
			{
				changes : List(StateChange),
				effect : Box((HostValue, HostValue.CapabilityHandle => Box((() => Cmd)))),
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
	## `SignalExpr`; event handlers carry a `Handler`.
	Attr := [
		StaticText({ field : TextField, name : Str, value : Str }),
		SignalText({ field : TextField, name : Str, signal : Box(SignalExpr), read : HostValue.TextReadHandle }),
		TextOptionalSignal({ field : TextField, name : Str, signal : Box(SignalExpr), present : HostValue.BoolReadHandle, read : HostValue.TextReadHandle }),
		StaticBool({ field : BoolField, name : Str, value : Bool }),
		SignalBool({ field : BoolField, name : Str, signal : Box(SignalExpr), read : HostValue.BoolReadHandle }),
		On(EventBinding),
	]

	## An exact native keyboard chord. The named key and all four modifiers are
	## explicit descriptor data; a host never derives them from control labels.
	KeyChord : { key : Str, control : Bool, shift : Bool, alt : Bool, meta : Bool }

	## Event binding descriptor attached to an element. A native key filter owns
	## one unit keydown route; its event and callable share the element's scope.
	## Hosts without this capability reject the filter before publication.
	EventBinding := { kind : FixedEventKind, msg : Handler, policy : EventPolicy, delivery : EventDelivery, name : Str, key_chord : [None, Some(KeyChord)] }
}
