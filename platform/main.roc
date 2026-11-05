## The roc-signals platform. The reactive engine is pure Roc: `Core.roc`
## implements it, `Engine.roc` is the authoring API apps see, and `Html.roc` is
## the typed vocabulary above that. An app binds a `program` as `main`, and one
## entry file builds for two targets:
##
## - `roc build --target=wasm32` gives the module the browser runs. The Zig
##   host (`host/host.zig`) holds exactly one opaque `Box(Core.App)` and the
##   command buffer between calls; JavaScript (`runtime.mjs`) reads the buffer
##   straight from linear memory.
## - `roc build --target=x64musl` gives the app's native `.scm` spec runner:
##   `SpecRunner.roc` drives the same `main` and checks it against the
##   `Dom.roc` oracle, and the native host (`host/spec.zig`) supplies `main`,
##   the allocator and the `Cli` file and output services. Run it as
##   `RUNNER FILE.scm...`.
platform ""
	requires {
		main : Engine.Program
	}
	exposes [Engine, Html]
	packages {}
	provides {
		"roc_engine_drop": drop_for_host,
		"roc_engine_event": event_for_host,
		"roc_engine_init": init_for_host,
		"roc_engine_keys": keys_for_host,
		"roc_engine_version": version_for_host,
		"roc_spec_main": spec_main_for_host!,
	}
	hosted {
		"roc_test_file_exists": Cli.file_exists!,
		"roc_test_now_ns": Cli.now_ns!,
		"roc_test_read_file": Cli.read_file!,
		"roc_test_stderr": Cli.stderr!,
		"roc_test_stdout": Cli.stdout!,
	}
	targets: {
		inputs_dir: "targets/",
		wasm32: {
			inputs: ["host.wasm", app],
			exports: ["protocol_version", "fault", "boot_keys", "init", "event", "drop", "payload_reserve", "cmd_ptr", "cmd_len", "work_ptr", "work_len", "metric", "reset_metrics", "err_ptr", "err_len"],
		},
		x64musl: { inputs: ["crt1.o", "spec.o", app, "libc.a", "libzigc.a", "libcompiler_rt.a"] },
	}

import Cli
import Core
import Engine
import Html
import SpecRunner

## One host call's result: the state (owned by the host until the next call),
## this transaction's command bytes and the instance's work record (both owned
## by the host, lent to JS, and passed back into the next call for reuse).
Step : { cmds : List(U8), state : Box(Core.App), work : List(U8) }

## The wire protocol version the engine speaks (design.md, Appendix B).
version_for_host : () -> U32
version_for_host = || Core.driver(main).version

## The storage keys the app declares, encoded count:u32 (key:str)*; the host
## reads their values before mount.
keys_for_host : () -> List(U8)
keys_for_host = || (Core.driver(main).keys)()

## Mount with the boot bytes (URL and declared storage values).
init_for_host : List(U8) -> Step
init_for_host = |boot| {
	(state, cmds, work) = (Core.driver(main).init)(boot)
	{ cmds, state: Box.box(state), work }
}

## Route a DOM event (node id, handler number, payload bytes) through one
## transaction, reusing the previous call's command and work buffers.
event_for_host : Box(Core.App), List(U8), List(U8), U32, U32, List(U8) -> Step
event_for_host = |boxed, buf, wbuf, node, handler, payload| {
	(next, cmds, work) = (Core.driver(main).event)(Box.unbox(boxed), buf, wbuf, node, handler, payload)
	{ cmds, state: Box.box(next), work }
}

## Teardown: the state and both buffers are released with the call.
drop_for_host : Box(Core.App), List(U8), List(U8) -> {}
drop_for_host = |_boxed, _buf, _wbuf| {}

## The native spec runner: `SpecRunner.main!` over this app's `main`, with
## the native host's file and output services.
spec_main_for_host! : List(Str) => I32
spec_main_for_host! = |args| SpecRunner.main!(Core.driver(main), { read_file!: Cli.read_file!, stdout!: Cli.stdout!, stderr!: Cli.stderr!, now_ns!: Cli.now_ns! }, args)
