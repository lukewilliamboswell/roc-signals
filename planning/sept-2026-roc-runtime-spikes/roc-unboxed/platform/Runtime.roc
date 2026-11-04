import Elem exposing [Elem]
import Node
import HostValue exposing [HostValue]
import Capability
import Bridge
import Small exposing [Small]
import Links

## Experimental descriptor interpreter. All graph and scope decisions are Roc.
## Cached values are Roc-owned getter closures; the host has no value registry.
Runtime := {}.{
	Cap : HostValue.CapabilityHandle
	Compute : [Source(Box((() -> HostValue))), Map(U64, Box((HostValue -> HostValue))), Map2(U64, U64, Box((HostValue, HostValue -> HostValue)))]
	Branch : { scope : U64, parent : U64, build : Box((HostValue -> Elem)), cap : Cap }
	Sink : [Text(U64, HostValue.TextReadHandle), Branch(Branch)]
	Record : { key : U64, cap : Cap, value : HostValue, compute : Compute, rank : U64, children : Links.Chain, sinks : Small(Sink), scope : U64 }
	Visual : { parent : U64, text : Str, tag : Str, scope : U64 }
	Binding : { elem : U64, source : U64, read : U64, reducer : HostValue.EventReducerHandle, scope : U64 }
	Scope : { nodes : Links.Chain, elements : Links.Chain, bindings : Links.Chain, children : Links.Chain }
	Model : { links : List(Links.Entry), nodes : List([Dead, Live(Record)]), index : Dict(U64, U64), visuals : List([Dead, Live(Visual)]), bindings : List([Dead, Live(Binding)]), scopes : List([Dead, Live(Scope)]), queue : List(U64), calls : U64, prunes : U64, sets : U64, created : U64, disposed : U64 }

	init : Elem -> Model
	init = |root| {
		model = { links: [], nodes: [], index: Dict.with_capacity(0), visuals: [], bindings: [], scopes: [Live({ nodes: Links.empty, elements: Links.empty, bindings: Links.empty, children: Links.empty })], queue: [], calls: 0, prunes: 0, sets: 0, created: 0, disposed: 0 }
		mount(model, root, 0, 0)
	}

	node : Model, U64 -> Record
	node = |model, id| match model.nodes.get(id) ?? crash "missing node" { Live(record) => record, Dead => crash "retired node" }

	scope_at : Model, U64 -> Scope
	scope_at = |model, id| match model.scopes.get(id) ?? crash "missing scope" { Live(scope) => scope, Dead => crash "retired scope" }

	put_node : Model, U64, Record -> Model
	put_node = |{ links, nodes, index, visuals, bindings, scopes, queue, calls, prunes, sets, created, disposed }, id, record| { links, nodes: nodes.set(id, Live(record)) ?? crash "missing node", index, visuals, bindings, scopes, queue, calls, prunes, sets, created, disposed }

	put_scope : Model, U64, Scope -> Model
	put_scope = |model, id, scope| { ..model, scopes: model.scopes.set(id, Live(scope)) ?? crash "missing scope" }

	new_scope : Model, U64 -> { model : Model, id : U64 }
	new_scope = |model, parent| {
		if model.scopes.len() >= 4096 { crash "experimental scope budget exhausted" }
		id = model.scopes.len()
		next = own(model, parent, ChildScope, id)
		{ model: { ..next, scopes: next.scopes.append(Live({ nodes: Links.empty, elements: Links.empty, bindings: Links.empty, children: Links.empty })), created: next.created + 1 }, id }
	}

	add_node : Model, Record -> { model : Model, id : U64 }
	add_node = |model, record| {
		if model.nodes.len() >= 4096 { crash "experimental node budget exhausted" }
		id = model.nodes.len()
		next = own(model, record.scope, GraphNode, id)
		{ model: { ..next, nodes: next.nodes.append(Live(record)), index: next.index.insert(record.key, id) }, id }
	}

	binder_key : Node.BinderRef -> U64
	binder_key = |Node.BinderRef.BinderRef(initial)| Bridge.identity!(initial)

	OwnerKind : [GraphNode, RenderNode, EventBinding, ChildScope]

	own : Model, U64, OwnerKind, U64 -> Model
	own = |{ links, nodes, index, visuals, bindings, scopes, queue, calls, prunes, sets, created, disposed }, scope, kind, id| {
		owner = match scopes.get(scope) ?? crash "missing owner" { Live(value) => value, Dead => crash "retired owner" }
		chain = match kind { GraphNode => owner.nodes, RenderNode => owner.elements, EventBinding => owner.bindings, ChildScope => owner.children }
		{ entries, chain: extended } = Links.append(links, chain, id)
		updated = match kind { GraphNode => { ..owner, nodes: extended }, RenderNode => { ..owner, elements: extended }, EventBinding => { ..owner, bindings: extended }, ChildScope => { ..owner, children: extended } }
		{ links: entries, nodes, index, visuals, bindings, scopes: scopes.set(scope, Live(updated)) ?? crash "missing owner", queue, calls, prunes, sets, created, disposed }
	}

	link : Model, U64, U64 -> Model
	link = |{ links, nodes, index, visuals, bindings, scopes, queue, calls, prunes, sets, created, disposed }, input, output| {
		old = match nodes.get(input) ?? crash "missing input" { Live(value) => value, Dead => crash "retired input" }
		if Links.contains(links, old.children, output) {
			{ links, nodes, index, visuals, bindings, scopes, queue, calls, prunes, sets, created, disposed }
		} else {
			{ entries, chain } = Links.append(links, old.children, output)
			{ links: entries, nodes: nodes.set(input, Live({ ..old, children: chain })) ?? crash "missing input", index, visuals, bindings, scopes, queue, calls, prunes, sets, created, disposed }
		}
	}

	ingest : Model, Node.SignalExpr, U64 -> { model : Model, id : U64 }
	ingest = |model, expr, scope| match expr {
		Node.SignalExpr.Ref(binder) => { model, id: model.index.get(binder_key(binder)) ?? crash "unbound source" }
		Node.SignalExpr.ConstValue(identity, initial, cap) => {
			key = Bridge.identity!(identity)
			match model.index.get(key) {
				Ok(id) => { model, id }
				Err(_) => add_node(model, { key, cap, value: (Box.unbox(initial))(), compute: Source(initial), rank: 0, children: Links.empty, sinks: Small.Empty, scope })
			}
		}
		Node.SignalExpr.Map(identity, input, transform, cap) => {
			key = Bridge.identity!(identity)
			match model.index.get(key) {
				Ok(id) => { model, id }
				Err(_) => {
					left = ingest(model, Box.unbox(input), scope)
					previous = node(left.model, left.id)
					added = add_node(left.model, { key, cap, value: (Box.unbox(transform))(previous.value), compute: Map(left.id, transform), rank: previous.rank + 1, children: Links.empty, sinks: Small.Empty, scope })
					{ model: link(added.model, left.id, added.id), id: added.id }
				}
			}
		}
		Node.SignalExpr.Map2(identity, a, b, transform, cap) => {
			key = Bridge.identity!(identity)
			match model.index.get(key) {
				Ok(id) => { model, id }
				Err(_) => {
					left = ingest(model, Box.unbox(a), scope)
					right = ingest(left.model, Box.unbox(b), scope)
					l = node(right.model, left.id)
					r = node(right.model, right.id)
					added = add_node(right.model, { key, cap, value: (Box.unbox(transform))(l.value, r.value), compute: Map2(left.id, right.id, transform), rank: (if l.rank > r.rank { l.rank } else { r.rank }) + 1, children: Links.empty, sinks: Small.Empty, scope })
					{ model: link(link(added.model, left.id, added.id), right.id, added.id), id: added.id }
				}
			}
		}
		_ => crash "signal kind not implemented by experimental runtime"
	}

	visual : Model, U64, U64, Str, Str -> { model : Model, id : U64 }
	visual = |model, parent, scope, tag, text| {
		if model.visuals.len() >= 8192 { crash "experimental visual budget exhausted" }
		id = model.visuals.len()
		next = own(model, scope, RenderNode, id)
		{ model: { ..next, visuals: next.visuals.append(Live({ parent, scope, tag, text })) }, id }
	}

	add_sink : Model, U64, Sink -> Model
	add_sink = |model, id, sink| {
		old = node(model, id)
		put_node(model, id, { ..old, sinks: old.sinks.append(sink) })
	}

	mount : Model, Elem, U64, U64 -> Model
	mount = |model, elem, parent, scope| match elem {
		Elem.Text(text) => (visual(model, parent, scope, "", text)).model
		Elem.TextSignal({ signal, read }) => {
			input = ingest(model, Box.unbox(signal), scope)
			text = (read.read)(node(input.model, input.id).value)
			out = visual(input.model, parent, scope, "", text)
			add_sink(out.model, input.id, Text(out.id, read))
		}
		Elem.Component({ child }) => {
			owner = new_scope(model, scope)
			mount(owner.model, Box.unbox(child), parent, owner.id)
		}
		Elem.State({ binder, initial, cap, child }) => {
			key = binder_key(binder)
			if model.index.contains(key) { crash "duplicate state binder" }
			added = add_node(model, { key, cap, value: (Box.unbox(initial))(), compute: Source(initial), rank: 0, children: Links.empty, sinks: Small.Empty, scope })
			mount(added.model, Box.unbox(child), parent, scope)
		}
		Elem.Element({ namespace, tag, attrs, children }) => {
			if namespace != Html { crash "unsupported namespace" }
			out = visual(model, parent, scope, tag, "")
			var $model = out.model
			for attr in attrs {
				match attr {
					Node.Attr.StaticText({ field, name, value }) => {
						if field.id != 1 or name != "" { crash "only static element text supported" }
						v = match $model.visuals.get(out.id) ?? crash "missing visual" { Live(entry) => entry, Dead => crash "retired visual" }
						$model = { ..$model, visuals: $model.visuals.set(out.id, Live({ ..v, text: value })) ?? crash "missing visual" }
					}
					Node.Attr.On(binding) => {
						if binding.kind.id != 1 { crash "only click supported" }
						if binding.msg.event_extraction_plan.bytes != [1] { crash "only unit payload supported" }
						p = binding.policy
						if p.prevent_default or p.stop_propagation or p.stop_immediate or p.capture or p.passive or p.once or p.self or p.trusted or binding.key_chord != None { crash "event policy not implemented" }
						match binding.msg.handler {
							Node.EventHandler.Reduce({ binder, read_binder, payload_reducer }) => {
								id = $model.bindings.len()
								$model = own($model, scope, EventBinding, id)
								$model = { ..$model, bindings: $model.bindings.append(Live({ elem: out.id, source: $model.index.get(binder_key(binder)) ?? crash "missing event source", read: $model.index.get(binder_key(read_binder)) ?? crash "missing event read", reducer: payload_reducer, scope })) }
							}
							_ => crash "only reducer events supported"
						}
					}
					_ => crash "attribute kind not implemented by experimental runtime"
				}
			}
			for child in children { $model = mount($model, child, out.id, scope) }
			$model
		}
		Elem.When({ condition, ops }) => {
			input = ingest(model, Box.unbox(condition), scope)
			owner = new_scope(input.model, scope)
			# Branch builders consume their case argument; retain the cached source.
			child = (Box.unbox(ops.build))(HostValue.clone(node(owner.model, input.id).value))
			next = mount(owner.model, child, parent, owner.id)
			add_sink(next, input.id, Branch({ scope: owner.id, parent, build: ops.build, cap: ops.case_capability }))
		}
		_ => crash "element kind not implemented by experimental runtime"
	}

	enqueue : Model, Links.Chain -> Model
	enqueue = |model, ids| {
		var $queue = model.queue
		var $cursor = ids.first
		while $cursor != 0 {
			entry = Links.entry(model.links, $cursor)
			id = entry.value
			$cursor = entry.next
 if !$queue.contains(id) { $queue = $queue.append(id) } }
		{ ..model, queue: $queue.sort_with(|a, b| {
			ra = node(model, a).rank
			rb = node(model, b).rank
			if ra < rb { Before } else if ra > rb { After } else { Same }
		}) }
	}

	install_value : Model, U64, HostValue -> Model
	install_value = |model, id, value| {
		old = node(model, id)
		if Bridge.equal(old.cap, old.value, value) {
			Bridge.drop(old.cap, value)
			{ ..model, prunes: model.prunes + 1 }
		} else {
			Bridge.drop(old.cap, old.value)
			next = put_node(model, id, { ..old, value })
			var $model = enqueue(next, old.children)
			var $sinks = Small.Empty
			for slot in U64.until(0, old.sinks.len()) {
			sink = old.sinks.get(slot)

				match sink {
					Text(elem_id, read) => {
						v = match $model.visuals.get(elem_id) ?? crash "missing visual" { Live(entry) => entry, Dead => crash "retired sink" }
						text = (read.read)(value)
						$model = { ..$model, visuals: $model.visuals.set(elem_id, Live({ ..v, text })) ?? crash "missing visual", sets: $model.sets + 1 }
						$sinks = $sinks.append(sink)
					}
					Branch(branch) => {
						$model = dispose($model, branch.scope)
						owner = new_scope($model, old.scope)
						$model = mount(owner.model, (Box.unbox(branch.build))(HostValue.clone(value)), branch.parent, owner.id)
						$sinks = $sinks.append(Branch({ ..branch, scope: owner.id }))
					}
				}
			}
			current = node($model, id)
			put_node($model, id, { ..current, sinks: $sinks })
		}
	}

	settle : Model -> Model
	settle = |model| {
		var $model = model
		while !$model.queue.is_empty() {
			id = $model.queue.get(0) ?? crash "missing queued node"
			$model = { ..$model, queue: $model.queue.drop_first(1) }
			current = node($model, id)
			value = match current.compute {
				Source(_) => crash "source scheduled as derived"
				Map(input, transform) => (Box.unbox(transform))(node($model, input).value)
				Map2(a, b, transform) => (Box.unbox(transform))(node($model, a).value, node($model, b).value)
			}
			$model = install_value({ ..$model, calls: $model.calls + 1 }, id, value)
		}
		$model
	}

	event : Model, U64 -> Model
	event = |model, id| {
		binding = match model.bindings.get(id) ?? crash "unknown event" { Live(b) => b, Dead => crash "disposed event" }
		source = node(model, binding.source)
		payload = HostValue.store(Box.box({}), binding.reducer.capability)
		value = (binding.reducer.transform)(source.value, node(model, binding.read).value, payload)
		Bridge.drop(binding.reducer.capability, payload)
		settle(install_value({ ..model, calls: 0, prunes: 0, sets: 0, created: 0, disposed: 0 }, binding.source, value))
	}

	dispose : Model, U64 -> Model
	dispose = |model, scope| {
		owned = scope_at(model, scope)
		var $model = model
		var $cursor = owned.children.first
		while $cursor != 0 {
			entry = Links.entry($model.links, $cursor)
			child = entry.value
			$cursor = entry.next

			match $model.scopes.get(child) ?? crash "missing child scope" { Live(_) => { $model = dispose($model, child) }, Dead => {} }
		}
		retire_owned($model, scope, owned)
	}

	## Consume the columns before retirement so edits do not keep a model alias.
	retire_owned : Model, U64, Scope -> Model
	retire_owned = |{ links, nodes, index, visuals, bindings, scopes, queue, calls, prunes, sets, created, disposed }, scope, owned| {
		var $nodes = nodes
		var $index = index
		var $visuals = visuals
		var $bindings = bindings
		var $queue = queue
		var $node_cursor = owned.nodes.first
		while $node_cursor != 0 {
			entry = Links.entry(links, $node_cursor)
			id = entry.value
			$node_cursor = entry.next

			record = match $nodes.get(id) ?? crash "missing retired node" { Live(value) => value, Dead => crash "already retired" }
			$nodes = $nodes.set(id, Dead) ?? crash "missing retired node"
			$index = $index.remove(record.key)
			$queue = $queue.keep_if(|queued| queued != id)
		}
		var $visual_cursor = owned.elements.first
		while $visual_cursor != 0 {
			entry = Links.entry(links, $visual_cursor)
			id = entry.value
			$visual_cursor = entry.next
 $visuals = $visuals.set(id, Dead) ?? crash "missing retired visual" }
		var $binding_cursor = owned.bindings.first
		while $binding_cursor != 0 {
			entry = Links.entry(links, $binding_cursor)
			id = entry.value
			$binding_cursor = entry.next
 $bindings = $bindings.set(id, Dead) ?? crash "missing retired event" }
		{ links, nodes: $nodes, index: $index, visuals: $visuals, bindings: $bindings, scopes: scopes.set(scope, Dead) ?? crash "missing retired scope", queue: $queue, calls, prunes, sets, created, disposed: disposed + 1 }
	}

	## Semantic harness lookup, deliberately outside the propagation work budget.
	click : Model, Str -> Model
	click = |model, label| event(model, event_id(model, label))

	event_id : Model, Str -> U64
	event_id = |model, label| {
		var $target = None
		var $visual_index = 0.U64
		for entry in model.visuals {
			match entry {
				Live(v) => if v.tag == "button" and v.text == label { $target = Some($visual_index) }
				Dead => {}
			}
			$visual_index = $visual_index + 1
		}
		target = match $target { Some(id) => id, None => crash "button label not found" }
		var $event = None
		var $i = 0.U64
		for entry in model.bindings {
			match entry { Live(b) => if b.elem == target { $event = Some($i) }, Dead => {} }
			$i = $i + 1
		}
		match $event { Some(id) => id, None => crash "button event not found" }
	}

	contains_text : Model, Str -> Bool
	contains_text = |model, text| model.visuals.any(|entry| match entry { Live(v) => v.tag == "" and v.text == text, Dead => False })

	finish : Model -> {}
	finish = |model| {
		_ = dispose(model, 0)
		{}
	}
}
