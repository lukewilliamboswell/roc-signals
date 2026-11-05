## The roc-signals web platform. The reactive engine is pure Roc (`Engine.roc`);
## `Html.roc` is the typed vocabulary above it. The Zig host (`host/host.zig`) holds exactly one opaque `Box(Instance)` and the command buffer
## between calls; JavaScript reads the buffer straight from linear memory.
## The app binds `Engine.program` with its concrete site type, so site dispatch
## is resolved in the app and the platform only sees an opaque instance.
platform ""
	requires {
		[Instance : instance] for main : Engine.Program(instance)
	}
	exposes [Engine, Html]
	packages {}
	provides { "roc_engine_drop": drop_for_host, "roc_engine_event": event_for_host, "roc_engine_init": init_for_host, "roc_engine_keys": keys_for_host, "roc_engine_version": version_for_host }
	targets: {
		inputs_dir: "targets/",
		wasm32: {
			inputs: ["host.wasm", app],
			exports: ["protocol_version", "fault", "boot_keys", "init", "event", "drop", "payload_reserve", "cmd_ptr", "cmd_len", "work_ptr", "work_len", "metric", "reset_metrics", "err_ptr", "err_len"],
		},
	}

import Engine
import Html

## One host call's result: the state (owned by the host until the next call),
## this transaction's command bytes and the instance's work record (both owned
## by the host, lent to JS, and passed back into the next call for reuse).
Step : { cmds : List(U8), state : Box(Instance), work : List(U8) }

## The wire protocol version the engine speaks (design.md, Appendix B).
version_for_host : () -> U32
version_for_host = || main.version

## The storage keys the app declares, encoded count:u32 (key:str)*; the host
## reads their values before mount.
keys_for_host : () -> List(U8)
keys_for_host = || (main.keys)()

## Mount with the boot bytes (URL and declared storage values).
init_for_host : List(U8) -> Step
init_for_host = |boot| {
	(state, cmds, work) = (main.init)(boot)
	{ cmds, state: Box.box(state), work }
}

## Route a DOM event (node id, handler number, payload bytes) through one
## transaction, reusing the previous call's command and work buffers.
event_for_host : Box(Instance), List(U8), List(U8), U32, U32, List(U8) -> Step
event_for_host = |boxed, buf, wbuf, node, handler, payload| {
	(next, cmds, work) = (main.event)(Box.unbox(boxed), buf, wbuf, node, handler, payload)
	{ cmds, state: Box.box(next), work }
}

## Teardown: the state and both buffers are released with the call.
drop_for_host : Box(Instance), List(U8), List(U8) -> {}
drop_for_host = |_boxed, _buf, _wbuf| {}
