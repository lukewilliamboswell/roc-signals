platform ""
	requires {
		main : () -> Elem
	}
	exposes [Elem, Event, Action, Signal, Html, Svg, Ui, Http, Browser, Rows]
	packages {
		roc: "nightly-2026-09-12-220fd47",
		http: "https://github.com/roc-lang/http/releases/download/0.1/6LcdNq2r7xTBwj972ecYWUkMWobJr94yL2NyJpHRAXap.tar.zst",
	}
	provides { "spike_init": experiment_init, "spike_step": experiment_step, "spike_finish": experiment_finish, "roc_ui_init": ui_init, "roc_prepare_effect": prepare_effect!, "roc_run_effect": run_effect! }
	hosted {
        "spike_erase": Erased.erase!,
        "spike_restore": Erased.restore!,
        "spike_identity": Bridge.identity!,
		"roc_http_send": Http.send!,
		"roc_each_bool_sink_push": EachSink.push_bool!,
		"roc_rows_delta_clear_sink_push": EachSink.push_delta_clear!,
		"roc_rows_delta_description_sink_push": EachSink.push_delta_description!,
		"roc_rows_delta_insert_sink_push": EachSink.push_delta_insert!,
		"roc_rows_delta_move_range_sink_push": EachSink.push_delta_move_range!,
		"roc_rows_delta_remove_range_sink_push": EachSink.push_delta_remove_range!,
		"roc_rows_delta_update_sink_push": EachSink.push_delta_update!,
		"roc_rows_snapshot_description_sink_push": EachSink.push_snapshot_description!,
		"roc_rows_snapshot_sink_push": EachSink.push_snapshot!,
		"roc_rows_same_generation_callable": Rows.same_generation_callable!,
	}
	targets: {
		inputs_dir: "targets/",
		wasm32: {
			inputs: ["host.wasm", app],
			output: Shared,
			exports: ["start", "step", "finish", "metric", "reset_metrics", "error_ptr", "error_len"],
		},
		x64mac: { inputs: ["libhost.a", app] },
		x64musl: { inputs: ["crt1.o", "libhost.a", app, "libc.a"] },
		arm64mac: { inputs: ["libhost.a", app] },
		arm64musl: { inputs: ["crt1.o", "libhost.a", app, "libc.a"] },
	}

import Elem exposing [Elem]
import EachSink
import HostValue exposing [HostValue]
import Node
import Event
import Action
import Signal
import Html
import Svg
import Ui
import Http
import Browser
import Rows

ui_init : () -> Box(Elem)
ui_init = || {
	Box.box(main())
}

## Decodes a committed action's reads on the engine thread and consumes its
## effect closure, producing an independently owned thunk for the executor.
prepare_effect! : Box((HostValue, HostValue.CapabilityHandle => Box((() => Node.Cmd)))), HostValue, HostValue.CapabilityHandle => Box((() => Node.Cmd))
prepare_effect! = |effect_box, snapshot, capability| {
	effect! = Box.unbox(effect_box)
	effect!(snapshot, capability)
}

## Consumes a prepared effect thunk and returns its next action to the host.
## Only the executor calls this, after the producing state batch commits.
run_effect! : Box((() => Node.Cmd)) => Node.Cmd
run_effect! = |thunk_box| {
	thunk! = Box.unbox(thunk_box)
	thunk!()
}

import Erased
import Bridge
import Runtime

experiment_init : () -> Box(Runtime.Model)
experiment_init = || {
	model = Runtime.init(main())
	if !Runtime.contains_text(model, "0") { crash "missing initial count" }
	Box.box(model)
}

experiment_step : Box(Runtime.Model), U64 -> Box(Runtime.Model)
experiment_step = |boxed, action| {
	model = Box.unbox(boxed)
	next = Runtime.click(model, if action == 0 { "Same" } else { "Increment" })
	if next.calls != 1 { crash "custom non-reflexive equality was ignored" }
	if action == 0 {
		if next.prunes != 1 or next.sets != 0 { crash "derived cutoff did not prune unchanged text" }
		if !Runtime.contains_text(next, "0") { crash "same update changed text" }
	} else {
		if next.prunes != 0 or next.sets != 1 { crash "increment cutoff work mismatch" }
		if !Runtime.contains_text(next, "1") { crash "increment did not update text" }
	}
	Box.box(next)
}

experiment_finish : Box(Runtime.Model) -> {}
experiment_finish = |boxed| Runtime.finish(Box.unbox(boxed))
