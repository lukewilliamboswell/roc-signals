platform ""
	requires {} { main : () -> U64 }
	exposes []
	packages { roc: "nightly-2026-09-12-220fd47" }
	provides { "engine_create": create, "engine_event": event, "engine_check": check, "engine_drop": drop }
	targets: {
		inputs_dir: "targets/",
		wasm32: { inputs: ["host.wasm", app], exports: ["start", "event", "check", "drop_state", "reset_metrics", "metric"] },
	}

import Fixtures

create : U64 -> Box(Fixtures.Model)
create = |rows| Box.box(Fixtures.init(rows + main()))

event : Box(Fixtures.Model), U64, U64, U64 -> Box(Fixtures.Model)
event = |boxed, op, row, value| Box.box(Fixtures.update(Box.unbox(boxed), op, row, value))

check : Box(Fixtures.Model), U64, U64, U64, U64, U64, U64 -> Box(Fixtures.Model)
check = |boxed, kind, row, value, calls, prunes, emitted| Box.box(Fixtures.check(Box.unbox(boxed), kind, row, value, calls, prunes, emitted))

drop : Box(Fixtures.Model) -> {}
drop = |_| {}
