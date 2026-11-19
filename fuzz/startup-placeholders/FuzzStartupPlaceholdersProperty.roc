import fz.Fuzz
import pf.Core
import pf.Dom
import pf.EntryRoutes
import Reference

Input : { initial : U8, mode : U8, events : List(U8) }

Registration : { armed : [Unarmed, Armed({ epoch : U64, token : U64 })], epoch : U64, largest : U64, arms : U64, cancels : U64 }

Capture : [Empty, Captured({ epoch : U64, token : U64 })]

## Bytes describe valid author writes and browser-task histories, not malformed
## input. A list-based model independently decides waiting lifetimes and FIFO
## replacement. The engine is observed only through commands, the independent
## DOM decoder, work counters and the public test-platform opportunity query.
##
## Repeated readiness, false/true reappend, disposal at a reused construction
## site, nested activation, local state reset and retained stale callbacks all
## occur in arbitrary order. Both ordinary and cold/ack startup run with zero
## or 32 in-flight slots. A placeholder task is never an admitted effect.
run : Input -> {}
run = |input| {
	model = Reference.initial(input.initial)
	maximum = if (input.mode.bitwise_and(1) == 0) 0 else 32
	startup = input.mode.bitwise_and(2) != 0
	entries = EntryRoutes.make({}, [{ path: EntryRoutes.Path.from_str("/") ?? crash "fixed root path", route: {} }])
	driver = Core.driver(Core.program_startup({ max_inflight: maximum }, entries, |_| Core.no_store, |_| view(model.configuration)))
	(initial, commands) = if startup {
		(state, cold, _) = (driver.init)([])
		(state, cold)
	} else Core.take_cmds(Core.mount_store(maximum, Core.no_store, view(model.configuration)), [])
	first = Dom.apply_full(Dom.new({}), commands)
	var $engine = initial
	var $dom = first.dom
	var $model = model
	var $registration = { armed: Unarmed, epoch: 0, largest: 0, arms: 0, cancels: 0 }
	var $capture = Empty
	if startup {
		if Core.startup_opportunity($engine) != None or !opportunities(first.fx).is_empty() {
			crash "cold frame armed a placeholder before acknowledgement"
		}
		match first.fx {
			[Startup(_), StartupAck] => {}
			_ => crash "cold fixture must publish exactly its startup barriers"
		}
		assert_picture({ engine: $engine, dom: $dom, model: $model })
		(acknowledged, ack, _) = (driver.event)($engine, [], [], effect_node, 0, [254])
		applied = Dom.apply_full($dom, ack)
		$engine = acknowledged
		$dom = applied.dom
		if applied.fx.last() != Ok(StartupComplete) or !applied.fx.all(
			|fx| match fx {
				StartupComplete | Opportunity(_) => True
				_ => False
			},
		) {
			crash "acknowledgement did not complete after its task registration"
		}
		$registration = registration_after({ previous: $registration, consumed: False, model: $model, effects: applied.fx, engine: $engine })
	} else {
		assert_task_effects(first.fx)
		$registration = registration_after({ previous: $registration, consumed: False, model: $model, effects: first.fx, engine: $engine })
	}
	assert_state({ engine: $engine, dom: $dom, model: $model, registration: $registration })
	for byte in input.events.take_first(64) {
		code = byte % 13
		if code == 6 {
			$capture = match $registration.armed {
				Unarmed => Empty
				Armed(held) => Captured(held)
			}
		} else if code == 4 or code == 5 {
			captured = if (code == 4) match $registration.armed {
				Unarmed => Empty
				Armed(held) => Captured(held)
			} else $capture
			if captured != Empty {
				# Epochs belong to the model, not the engine's token allocator. Reusing
				# a cancelled engine generation cannot make an old callback valid here.
				valid = match (captured, $registration.armed) {
					(Captured(old), Armed(current)) => old.epoch == current.epoch
					_ => False
				}
				token = match captured {
					Empty => crash "captured task is present in this branch"
					Captured(held) => held.token
				}
				$engine = Core.opportunity($engine, token)
				products = if (valid) Reference.activate($model) else Reference.stale($model)
				(next, emitted) = Core.take_cmds($engine, [])
				$engine = next
				applied = Dom.apply_full($dom, emitted)
				assert_task_effects(applied.fx)
				$dom = applied.dom
				$model = products
				if !valid and !emitted.is_empty() {
					crash "a stale opportunity emitted commands"
				}
				if valid and (applied.ops.keep_if(|op| op == 5).len() != 1 or !applied.ops.keep_if(|op| op == 2 or op == 12).is_empty()) {
					crash "one activation must remove one fallback without patching old readers"
				}
				$registration = registration_after({ previous: $registration, consumed: valid, model: $model, effects: applied.fx, engine: $engine })
			}
		} else {
			action = action_of(code)
			# Bump-if-active is part of this byte decoder's valid-program grammar;
			# it is not an ignored spec step or a missing live event route.
			if Reference.is_active($model, action) {
				button = Dom.find($dom, $dom.root, |node| node.tag == "button" and Dom.attr_of(node, "aria-label") == Reference.label(action)) ?? crash "generated live action has no button"
				listener = Dom.target($dom, button, "click", True) ?? crash "generated live action has no listener"
				(next, emitted) = Core.take_cmds(Core.event($engine, listener.node, listener.handler, "\u(0000)\u(0000)"), [])
				$engine = next
				$model = Reference.change($model, action)
				applied = Dom.apply_full($dom, emitted)
				assert_task_effects(applied.fx)
				$dom = applied.dom
				text_writes = applied.ops.keep_if(|op| op == 2 or op == 12).len()
				expected_texts = match action {
					Pulse => Reference.active_count($model)
					BumpFirst | BumpSecond | BumpNested => 1
					_ => 0
				}
				if text_writes != expected_texts {
					crash "placeholder action refreshed the wrong set of live readers"
				}
				if action != ToggleShown and expected_texts == 0 and !applied.ops.keep_if(|op| op != 31).is_empty() {
					crash "readiness or equality pruning performed DOM work"
				}
				$registration = registration_after({ previous: $registration, consumed: False, model: $model, effects: applied.fx, engine: $engine })
			}
		}
		assert_state({ engine: $engine, dom: $dom, model: $model, registration: $registration })
	}
	{}
}

## Appendix B's private effect ingress address, never an application identity.
effect_node : U32
effect_node = 0xffffffff

action_of : U8 -> Reference.Action
action_of = |code| match code {
	0 => ToggleFirst
	1 => ToggleSecond
	2 => ToggleNested
	3 => ToggleShown
	7 => Same
	8 => Pulse
	9 => BumpFirst
	10 => BumpSecond
	11 => BumpNested
	12 => Both
	_ => crash "task and capture actions are decoded separately"
}

## Author writes are implemented independently of Reference.change. Sharing
## only names and record types cannot make a wrong transition its own oracle.
configuration_after : Reference.Configuration, Reference.Action -> Reference.Configuration
configuration_after = |cfg, action| match action {
	ToggleFirst => { ..cfg, first: !cfg.first }
	ToggleSecond => { ..cfg, second: !cfg.second }
	ToggleNested => { ..cfg, nested: !cfg.nested }
	ToggleShown => { ..cfg, shown: !cfg.shown }
	Same => cfg
	Pulse => { ..cfg, version: cfg.version + 1 }
	Both => { ..cfg, first: !cfg.first, second: !cfg.second }
	BumpFirst | BumpSecond | BumpNested => cfg
}

view : Reference.Configuration -> Core.Elem(Core.Root({}))
view = |initial| Core.state(
	initial,
	|state| {
		reading = state.signal()
		version = reading.map(|cfg| cfg.version)
		buttons = Reference.buttons.map(|action| Core.element("button", [Core.attr("aria-label", Reference.label(action)), Core.on("click", state.update(|cfg| configuration_after(cfg, action)))], [Core.text(Reference.label(action))]))
		Core.element(
			"main",
			[],
			buttons.concat([
				Core.when(
					reading.map(|cfg| cfg.shown),
					|| Core.placeholder(
						reading.map(|cfg| cfg.first),
						fallback("first"),
						body_factory({ name: "first", version, seed: initial.payload_seed, child: Child(Core.placeholder(reading.lift().map(|cfg| cfg.nested), fallback("nested"), body_factory({ name: "nested", version: version.lift(), seed: initial.payload_seed, child: Leaf }))) }),
					),
					|| Core.text(""),
				),
				Core.placeholder(reading.map(|cfg| cfg.second), fallback("second"), body_factory({ name: "second", version, seed: initial.payload_seed, child: Leaf })),
			]),
		)
	},
)

fallback : Str -> Core.Elem(ctx)
fallback = |name| Core.element("p", [Core.attr("data-testid", "wait-${name}")], [Core.text("${name} waiting")])

## Captured payloads are constructed from unknown input before the deferred
## factory runs. They are mutable local storage only after activation; disposal
## and remount must reset them while unrelated waiting/active owners survive.
body_factory : { name : Str, version : Core.Signal(ctx, U64), seed : U64, child : [Leaf, Child(Core.Elem(Core.In(ctx, List(U64))))] } -> (() -> Core.Elem(ctx))
body_factory = |{ name, version, seed, child }| {
	initial = List.repeat(seed, 128).update(0, |_| 0) ?? crash "fixed payload has slot zero"
	|| body({ name, version, child, initial })
}

body : { name : Str, version : Core.Signal(ctx, U64), initial : List(U64), child : [Leaf, Child(Core.Elem(Core.In(ctx, List(U64))))] } -> Core.Elem(ctx)
body = |{ name, version, child, initial }| Core.state(
	initial,
	|local| Core.element(
		"section",
		[Core.attr("data-testid", "live-${name}")],
		[
			Core.element("p", [], [Core.text_s(local.signal().map2(version.lift(), |values, revision| "${name}:${(values.first() ?? 0).to_str()}:${revision.to_str()}"))]),
			Core.element("button", [Core.attr("aria-label", "Bump ${name}"), Core.on("click", local.update(|values| values.update(0, |count| count + 1) ?? crash "live payload has slot zero"))], [Core.text("Bump ${name}")]),
		].concat(
			match child {
				Leaf => []
				Child(element) => [element]
			},
		),
	),
)

assert_task_effects : List(Dom.FxCmd) -> {}
assert_task_effects = |effects| {
	if !effects.all(
		|effect| match effect {
			Opportunity(_) => True
			_ => False
		},
	) {
		crash "placeholder fixture emitted an effect outside its task registration"
	}
	{}
}

opportunities : List(Dom.FxCmd) -> List({ action : U8, generation : U64 })
opportunities = |effects| effects.keep_oks(
	|effect| match effect {
		Opportunity(command) => Ok(command)
		_ => Err(NotATask)
	},
)

## Check the command-defined registration lifecycle against the model's queue
## transitions. One external callback is armed regardless of queue length.
registration_after : { previous : Registration, consumed : Bool, model : Reference.Model, effects : List(Dom.FxCmd), engine : Core.App({}) } -> Registration
registration_after = |{ previous, consumed, model, effects, engine }| {
	commands = opportunities(effects)
	armed = if (consumed) Unarmed else previous.armed
	next = match (armed, model.queue.is_empty()) {
		(Unarmed, False) => match commands {
			[{ action: 1, generation }] if generation > previous.largest => { ..previous, armed: Armed({ epoch: previous.epoch + 1, token: generation }), epoch: previous.epoch + 1, largest: generation, arms: previous.arms + 1 }
			_ => crash "nonempty model queue did not arm exactly one fresh task"
		}
		(Armed(held), True) => {
			if commands != [{ action: 0, generation: held.token }] {
				crash "empty model queue did not cancel its exact task"
			}
			{ ..previous, armed: Unarmed, cancels: previous.cancels + 1 }
		}
		_ => {
			if !commands.is_empty() {
				crash "unchanged task registration emitted task commands"
			}
			{ ..previous, armed }
		}
	}
	expected = match next.armed {
		Unarmed => None
		Armed(held) => Some(held.token)
	}
	if Core.startup_opportunity(engine) != expected {
		crash "engine task query disagrees with its commands and model queue"
	}
	next
}

assert_state : { engine : Core.App({}), dom : Dom.Model, model : Reference.Model, registration : Registration } -> {}
assert_state = |{ engine, dom, model, registration }| {
	assert_picture({ engine, dom, model })
	counts = Core.work_counters(engine)
	actual = { created: counts.get(25), disposed: counts.get(26), arms: counts.get(53), cancels: counts.get(54), delivered: counts.get(55), stale: counts.get(56) }
	expected = { created: Ok(model.created), disposed: Ok(model.disposed), arms: Ok(registration.arms), cancels: Ok(registration.cancels), delivered: Ok(model.delivered), stale: Ok(model.stale) }
	if actual != expected or !Core.fx_live(engine).is_empty() {
		crash "task accounting differs from independent history: ${Str.inspect(actual)} expected ${Str.inspect(expected)}"
	}
	{}
}

assert_picture : { engine : Core.App({}), dom : Dom.Model, model : Reference.Model } -> {}
assert_picture = |{ engine, dom, model }| {
	main = Dom.find(dom, dom.root, |node| node.tag == "main") ?? crash "fixture main is missing"
	actual = picture(dom, main)
	expected = Reference.picture(model)
	if actual != expected {
		crash "placeholder lifecycle differs from authored tree: ${Str.inspect(actual)} expected ${Str.inspect(expected)}"
	}
	match Core.settled(engine) {
		Ok({}) => {}
		Err(problem) => crash "placeholder turn left stale storage: ${problem.note}"
	}
}

## Empty engine anchors are transport structure; every authored element,
## attribute and nonempty text node still participates in the tree comparison.
picture : Dom.Model, U64 -> Reference.Node
picture = |dom, index| {
	node = Dom.node(dom, index)
	if node.kind == 2 {
		Text(node.text)
	} else {
		if node.kind != 1 or node.namespace != "http://www.w3.org/1999/xhtml" or node.prefix != "" {
			crash "placeholder fixture changed a node's namespace or kind"
		}
		Element({
			tag: node.tag,
			attributes: node.attrs.map(
				|(name, text)| {
					if name.namespace != "" or name.prefix != "" {
						crash "placeholder fixture changed an attribute's expanded name"
					}
					{ name: name.local, value: text }
				},
			),
			children: node.kids.keep_if(
				|child| {
					candidate = Dom.node(dom, child)
					candidate.kind != 2 or !candidate.text.is_empty()
				},
			).map(|child| picture(dom, child)),
		})
	}
}

test! : Input => Fuzz.Outcome
test! = |input| {
	Fuzz.expect_no_leaks!(|| run(input))
	Fuzz.keep
}

fixed : List({ name : Str, input : Input })
fixed = [
	{ name: "captured-payloads-mutate-and-remount-independently", input: { initial: 199, mode: 3, events: [4, 9, 9, 4, 10, 4, 11, 11, 3, 3, 4, 9, 4, 11] } },
	{ name: "false-true-appends-behind-existing-owner", input: { initial: 3, mode: 0, events: [6, 0, 0, 4, 4, 2, 4] } },
	{ name: "cancelled-generation-cannot-name-remounted-site", input: { initial: 1, mode: 2, events: [6, 3, 3, 5, 4, 5, 7] } },
	{ name: "nested-waits-behind-sibling-and-resets-with-parent", input: { initial: 7, mode: 3, events: [4, 4, 4, 8, 9, 10, 11, 3, 3, 4, 4] } },
	{ name: "registration-survives-head-disposal-with-ready-sibling", input: { initial: 3, mode: 2, events: [6, 3, 3, 5, 4, 5] } },
	{ name: "zero-inflight-still-activates-every-owner", input: { initial: 7, mode: 2, events: [6, 4, 5, 4, 4, 5] } },
	{ name: "late-body-reads-current-values", input: { initial: 0, mode: 1, events: [8, 0, 8, 4, 2, 8, 4] } },
	{ name: "same-task-can-observe-new-head-after-one-turn", input: { initial: 1, mode: 3, events: [6, 12, 5, 5, 12, 4] } },
	{ name: "equal-writes-do-not-duplicate-waiting-owners", input: { initial: 7, mode: 0, events: [7, 7, 6, 7, 4, 7, 4, 7, 4, 5] } },
]

## Pure histories make failures easy to localize. This preflight does not
## replace optimized fixed-example replay and its allocation/leak checks.
expect {
	for case in fixed {
		run(case.input)
	}
	True
}

fuzz_target = Fuzz.target_with!({
	name: "startup-placeholders",
	examples: fixed.map(|case| Fuzz.example({ name: case.name, revision: "1", make: || case.input })),
	generator: { initial: Fuzz.u8, mode: Fuzz.u8, events: Fuzz.list(Fuzz.u8, 64) }.Fuzz,
	test!,
	show: Str.inspect,
})

## The same property, model and saved inputs used by the standalone app and suite.
FuzzStartupPlaceholdersProperty := [].{
	target = fuzz_target
}
