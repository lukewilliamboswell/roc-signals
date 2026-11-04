platform ""
	requires {
		[Model : model] for main : {
			init : U64 -> model,
			update : model, U64, U64, U64 -> model,
			check : model, U64, U64, U64, U64, U64, U64 -> model,
		}
	}
	exposes [Engine]
	packages { roc: "nightly-2026-09-12-220fd47" }
	provides { "engine_create": create, "engine_event": event, "engine_check": check, "engine_drop": drop }
	targets: {
		inputs_dir: "targets/",
		wasm32: { inputs: ["host.wasm", app], exports: ["start", "event", "check", "drop_state", "reset_metrics", "metric"] },
	}

import Engine

create : U64 -> Box(Model)
create = |rows| Box.box((main.init)(rows))

event : Box(Model), U64, U64, U64 -> Box(Model)
event = |boxed, op, row, value| Box.box((main.update)(Box.unbox(boxed), op, row, value))

check : Box(Model), U64, U64, U64, U64, U64, U64 -> Box(Model)
check = |boxed, kind, row, value, calls, prunes, emitted| Box.box((main.check)(Box.unbox(boxed), kind, row, value, calls, prunes, emitted))

drop : Box(Model) -> {}
drop = |_| {}
