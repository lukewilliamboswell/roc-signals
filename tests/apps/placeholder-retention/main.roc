app [main] { pf: platform "../../../platform/main.roc" }

import pf.Engine
import pf.Html

Kind := [Direct, Deferred, Retained, DeferredRetained]

Options : { count : U64, seed : U64, kind : Kind }

main : Engine.Program
main = Engine.program_boot({}, view)

## A region factory captures only scalar boot configuration. Its payload is
## constructed when that region mounts, so no outer remount recipe retains it.
view : Engine.Boot -> Engine.Elem(Engine.Root)
view = |boot| {
	deferred = boot.url.contains("deferred")
	retained = boot.url.contains("retained")
	cfg = {
		count: if (boot.url.contains("large")) 10000 else 1000,
		seed: boot.seed.to_u64_wrap(),
		kind: if deferred {
			if (retained) DeferredRetained else Deferred
		} else if (retained) Retained else Direct,
	}
	Engine.state(
		True,
		|shown| Engine.element(
			"main",
			[],
			[
				Html.button("Toggle region", [], shown.update(Bool.not)),
				Engine.when(shown.signal(), || region(cfg), || Engine.text("hidden")),
			],
		),
	)
}

region : Options -> Engine.Elem(ctx)
region = |cfg| {
	# The boot seed is unknown to the compiler. This buffer is runtime data,
	# rather than an immutable compiled default that already requires a copy.
	initial = List.repeat(cfg.seed, cfg.count)
	match cfg.kind {
		Direct => body(initial)
		Deferred => Html.placeholder({ ready: Engine.const(True) }, "<p data-testid='waiting'>waiting</p>", || body(initial))
		Retained => retained_body(initial)
		DeferredRetained => Html.placeholder({ ready: Engine.const(True) }, "<p data-testid='waiting'>waiting</p>", || retained_body(initial))
	}
}

## Only the mounted state needs the initial buffer after construction.
body : List(U64) -> Engine.Elem(ctx)
body = |initial| Engine.state(
	initial,
	|state| Engine.element(
		"section",
		[],
		[
			Html.button("Bump", [], state.update(bump)),
			Html.button("Clear", [], state.update(|values| values.map(|_| 0))),
			Html.p_s(state.signal().map(|values| (values.first() ?? 0).to_str()), [Engine.test_id("value")]),
		],
	),
)

## Reset deliberately needs the authored original after later writes. This
## positive control must keep working when the consumed factory is released.
retained_body : List(U64) -> Engine.Elem(ctx)
retained_body = |initial| Engine.state(
	initial,
	|state| Engine.element(
		"section",
		[],
		[
			Html.button("Bump", [], state.update(bump)),
			Html.button("Clear", [], state.update(|values| values.map(|_| 0))),
			Html.button("Reset", [], state.update(|_| initial)),
			Html.p_s(state.signal().map(|values| (values.first() ?? 0).to_str()), [Engine.test_id("value")]),
		],
	),
)

bump : List(U64) -> List(U64)
bump = |values| values.update(0, |value| value + 1) ?? crash "fixture always has slot zero"
