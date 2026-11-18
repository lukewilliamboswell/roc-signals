## A small declarative lifecycle model, independent of engine ids, routes and
## linked queues. Three semantic owners are enough to distinguish FIFO order,
## nesting and a new lifetime at an old construction site.
Reference := [].{
	Owner := [First, Second, Nested].{
		is_eq : _
	}
	Phase := [Absent, Waiting, Active(U64)].{
		is_eq : _
	}
	Configuration : { first : Bool, second : Bool, nested : Bool, shown : Bool, version : U64, payload_seed : U64 }
	Action := [ToggleFirst, ToggleSecond, ToggleNested, ToggleShown, Same, Pulse, Both, BumpFirst, BumpSecond, BumpNested].{
		is_eq : _
	}
	Model : { configuration : Configuration, first : Phase, second : Phase, nested : Phase, queue : List(Owner), delivered : U64, stale : U64, created : U64, disposed : U64 }
	Attribute : { name : Str, value : Str }
	Node := [Text(Str), Element({ tag : Str, attributes : List(Attribute), children : List(Node) })].{
		is_eq : _
	}

	initial : U8 -> Model
	initial = |bits| {
		configuration = { first: bits.bitwise_and(1) != 0, second: bits.bitwise_and(2) != 0, nested: bits.bitwise_and(4) != 0, shown: True, version: 0, payload_seed: bits.to_u64() }
		{ configuration, first: Waiting, second: Waiting, nested: Absent, queue: eligible(eligible([], { owner: First, ready: configuration.first }), { owner: Second, ready: configuration.second }), delivered: 0, stale: 0, created: 3, disposed: 0 }
	}

	## Apply an author's write, then update waiting owners in authored nesting
	## order. An active owner never returns to its fallback when readiness falls.
	change : Model, Action -> Model
	change = |model, action| {
		cfg = model.configuration
		match action {
			ToggleFirst => waiting({ ..model, configuration: { ..cfg, first: !cfg.first } })
			ToggleSecond => waiting({ ..model, configuration: { ..cfg, second: !cfg.second } })
			ToggleNested => waiting({ ..model, configuration: { ..cfg, nested: !cfg.nested } })
			Both => waiting({ ..model, configuration: { ..cfg, first: !cfg.first, second: !cfg.second } })
			ToggleShown => {
				without = { ..model, configuration: { ..cfg, shown: !cfg.shown }, first: if (cfg.shown) Absent else Waiting, nested: Absent, queue: model.queue.keep_if(|owner| owner == Second), created: model.created + (if (cfg.shown) 1 else 2), disposed: model.disposed + (if (cfg.shown) 2 + (if (model.nested == Absent) 0 else 1) else 1) }
				waiting(without)
			}
			Same => model
			Pulse => { ..model, configuration: { ..cfg, version: cfg.version + 1 } }
			BumpFirst => { ..model, first: bump(model.first) }
			BumpSecond => { ..model, second: bump(model.second) }
			BumpNested => { ..model, nested: bump(model.nested) }
		}
	}

	## A delivered opportunity replaces exactly the oldest eligible lifetime.
	## A newly mounted nested owner joins behind every owner already waiting.
	activate : Model -> Model
	activate = |model| match model.queue {
		[] => crash "reference: activation requires a waiting owner"
		[first, .. as rest] => {
			advanced = { ..model, queue: rest, delivered: model.delivered + 1, created: model.created + (if (first == First) 2 else 1), disposed: model.disposed + 1 }
			match first {
				First => { ..advanced, first: Active(0), nested: Waiting, queue: eligible(rest, { owner: Nested, ready: model.configuration.nested }) }
				Second => { ..advanced, second: Active(0) }
				Nested => { ..advanced, nested: Active(0) }
			}
		}
	}

	## Scope work follows authored lifetimes: one branch scope, one scope for
	## each fallback or body, and the nested fallback only after First activates.
	## Branch removal releases its own scope and every owned placeholder scope.

	## A stale browser occurrence has no author-visible effect.
	stale : Model -> Model
	stale = |model| { ..model, stale: model.stale + 1 }

	label : Action -> Str
	label = |action| match action {
		ToggleFirst => "First ready"
		ToggleSecond => "Second ready"
		ToggleNested => "Nested ready"
		ToggleShown => "Show first"
		Same => "Same"
		Pulse => "Pulse"
		Both => "Both ready"
		BumpFirst => "Bump first"
		BumpSecond => "Bump second"
		BumpNested => "Bump nested"
	}

	buttons : List(Action)
	buttons = [ToggleFirst, ToggleSecond, ToggleNested, ToggleShown, Same, Pulse, Both]

	## Construct the authored tree directly. This oracle neither parses source
	## nor consumes engine commands to decide what the application should draw.
	picture : Model -> Node
	picture = |model| Element({
		tag: "main",
		attributes: [],
		children: Reference.buttons.map(|action| button(Reference.label(action)))
			.concat(phase_picture(model.first, { owner: First, version: model.configuration.version, nested: model.nested }))
			.concat(phase_picture(model.second, { owner: Second, version: model.configuration.version, nested: Absent })),
	})

	## The visible body count determines exact text work on a version write.
	active_count : Model -> U64
	active_count = |model| [model.first, model.second, model.nested].fold(
		0,
		|count, phase| match phase {
			Active(_) => count + 1
			_ => count
		},
	)

	is_active : Model, Action -> Bool
	is_active = |model, action| match action {
		BumpFirst => is_active_phase(model.first)
		BumpSecond => is_active_phase(model.second)
		BumpNested => is_active_phase(model.nested)
		_ => True
	}
}

## A list, deliberately unlike the engine's indexed links: the model states
## ordering, and makes no claim about the cost of implementing it.
eligible : List(Reference.Owner), { owner : Reference.Owner, ready : Bool } -> List(Reference.Owner)
eligible = |queue, { owner, ready }| if ready {
	if (queue.contains(owner)) queue else queue.append(owner)
} else queue.keep_if(|candidate| candidate != owner)

waiting : Reference.Model -> Reference.Model
waiting = |model| {
	cfg = model.configuration
	a = if (model.first == Waiting) eligible(model.queue, { owner: First, ready: cfg.first }) else model.queue
	nested = if (model.nested == Waiting) eligible(a, { owner: Nested, ready: cfg.nested }) else a
	b = if (model.second == Waiting) eligible(nested, { owner: Second, ready: cfg.second }) else nested
	{ ..model, queue: b }
}

bump : Reference.Phase -> Reference.Phase
bump = |phase| match phase {
	Active(count) => Active(count + 1)
	_ => phase
}

is_active_phase : Reference.Phase -> Bool
is_active_phase = |phase| match phase {
	Active(_) => True
	_ => False
}

button : Str -> Reference.Node
button = |label| Element({ tag: "button", attributes: [{ name: "aria-label", value: label }], children: [Text(label)] })

phase_picture : Reference.Phase, { owner : Reference.Owner, version : U64, nested : Reference.Phase } -> List(Reference.Node)
phase_picture = |phase, { owner, version, nested }| {
	name = match owner {
		First => "first"
		Second => "second"
		Nested => "nested"
	}
	match phase {
		Absent => []
		Waiting => [Element({ tag: "p", attributes: [{ name: "data-testid", value: "wait-${name}" }], children: [Text("${name} waiting")] })]
		Active(count) => [
			Element({
				tag: "section",
				attributes: [{ name: "data-testid", value: "live-${name}" }],
				children: [Element({ tag: "p", attributes: [], children: [Text("${name}:${count.to_str()}:${version.to_str()}")] }), button("Bump ${name}")]
					.concat(if (owner == First) phase_picture(nested, { owner: Nested, version, nested: Absent }) else []),
			}),
		]
	}
}

## Falling and rising readiness puts a waiting lifetime at the back, while
## activation creates its nested lifetime only after it has been selected.
expect {
	a = Reference.initial(7)
	b = Reference.change(Reference.change(a, ToggleFirst), ToggleFirst)
	c = Reference.activate(b)
	d = Reference.activate(c)
	{ before: b.queue, first_active: c.second, after: d.queue } == { before: [Second, First], first_active: Active(0), after: [Nested] }
}

## Removing a live parent also removes its queued nested lifetime, and showing
## it again creates a waiting parent with fresh local state.
expect {
	active = Reference.activate(Reference.initial(7))
	counted = Reference.change(active, BumpFirst)
	removed = Reference.change(counted, ToggleShown)
	again = Reference.change(removed, ToggleShown)
	{ first: again.first, nested: again.nested, queue: again.queue } == { first: Waiting, nested: Absent, queue: [Second, First] }
}
