## Phase 4 (p4apps) platform, from the Phase 1 spike platform: the reactive engine is pure Roc (`Engine.roc`).
## The Zig host holds exactly one opaque `Box(Instance)` and the command buffer
## between calls; JavaScript reads the buffer straight from linear memory.
## The app binds `Engine.program` with its concrete site type, so site dispatch
## is resolved in the app and the platform only sees an opaque instance.
platform ""
	requires {
		[Instance : instance] for main : Engine.Program(instance)
	}
	exposes [Engine]
	packages {}
	provides { "roc_engine_keys": keys_for_host, "roc_engine_init": init_for_host, "roc_engine_event": event_for_host, "roc_engine_drop": drop_for_host }
	targets: {
		inputs_dir: "targets/",
		wasm32: {
			inputs: ["host.wasm", app],
			exports: ["fault", "boot_keys", "init", "event", "drop", "payload_reserve", "cmd_ptr", "cmd_len", "metric", "reset_metrics", "err_ptr", "err_len"],
		},
	}

import Engine

## One host call's result: the state (owned by the host until the next call)
## and this transaction's command bytes (owned by the host, lent to JS, and
## passed back into the next call for reuse).
Step : { cmds : List(U8), state : Box(Instance) }

## The storage keys the app declares, encoded count:u32 (key:str)*; the host
## reads their values before mount.
keys_for_host : () -> List(U8)
keys_for_host = || (main.keys)()

## Mount with the boot bytes (URL and declared storage values).
init_for_host : List(U8) -> Step
init_for_host = |boot| {
	(state, cmds) = (main.init)(boot)
	{ cmds, state: Box.box(state) }
}

## Route a DOM event (node id, handler number, payload bytes) through one
## transaction.
event_for_host : Box(Instance), List(U8), U32, U32, List(U8) -> Step
event_for_host = |boxed, buf, node, handler, payload| {
	(next, cmds) = (main.event)(Box.unbox(boxed), buf, node, handler, payload)
	{ cmds, state: Box.box(next) }
}

drop_for_host : Box(Instance), List(U8) -> {}
drop_for_host = |_boxed, _buf| {}
