## The roc-signals platform. The reactive engine is pure Roc: `Core.roc`
## implements it, `Engine.roc` is the authoring API apps see, `Html.roc` is
## the typed vocabulary above that, and `Worker.roc` is the typed layer for
## tasks run in Web Workers, whose payloads `Wire.roc` derives;
## `Port.roc` is the typed layer for services the page's JavaScript supplies,
## whose messages `PortJson.roc` derives. An app
## binds a `program` as `main`, and one entry file builds for two targets:
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
	exposes [Engine, Html, Port, PortJson, Wire, Worker]
	packages {}
	provides {
		"roc_engine_ask": ask_for_host!,
		"roc_engine_drop": drop_for_host,
		"roc_engine_event": event_for_host,
		"roc_engine_files": files_for_host,
		"roc_engine_forget": forget_for_host,
		"roc_engine_init": init_for_host,
		"roc_engine_keys": keys_for_host,
		"roc_engine_prepare": prepare_for_host!,
		"roc_engine_version": version_for_host,
		"roc_engine_work": work_for_host!,
		"roc_spec_main": spec_main_for_host!,
	}
	hosted {
		"roc_task_append": Hosted.append!,
		"roc_task_append_file": Hosted.append_file!,
		"roc_task_finish": Hosted.finish!,
		"roc_task_mint": Hosted.mint!,
		"roc_task_open": Hosted.open!,
		"roc_task_read": Hosted.read!,
		"roc_task_size": Hosted.size!,
		"roc_test_file_exists": Cli.file_exists!,
		"roc_test_live_files": Cli.live_files!,
		"roc_test_mint_files": Cli.mint_files!,
		"roc_test_now_ns": Cli.now_ns!,
		"roc_test_read_file": Cli.read_file!,
		"roc_test_sha256": Cli.sha256!,
		"roc_test_stderr": Cli.stderr!,
		"roc_test_stdout": Cli.stdout!,
		"roc_test_work": Cli.work!,
	}
	targets: {
		inputs_dir: "targets/",
		wasm32: {
			inputs: ["host.wasm", app],
			exports: ["protocol_version", "fault", "boot_keys", "init", "event", "event_files", "files_stage", "files_tokens", "files_released", "drop", "payload_reserve", "work", "prepare", "ask", "forget", "cmd_ptr", "cmd_len", "work_ptr", "work_len", "metric", "reset_metrics", "err_ptr", "err_len"],
		},
		x64musl: { inputs: ["crt1.o", "spec.o", app, "libc.a", "libzigc.a", "libcompiler_rt.a"] },
	}

import Cli
import Core
import Engine
import Hosted
import Html
import Port
import PortJson
import SpecRunner
import Wire
import Worker

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

## A `:files` event: the file record and the handles the host minted for its
## files, which move into the engine with the call.
files_for_host : Box(Core.App), List(U8), List(U8), U32, U32, List(U8), List(Box(U64)) -> Step
files_for_host = |boxed, buf, wbuf, node, handler, record, blobs| {
	(next, cmds, work) = (Core.driver(main).files)(Box.unbox(boxed), buf, wbuf, node, handler, record, blobs)
	{ cmds, state: Box.box(next), work }
}

## A worker instance's job (design.md, "Workers"): run the task named in
## the payload (`name:str input:rest`) with the handles the host minted for
## the job's files, which move into Roc with the call, and return its
## answer, `n:u32 (token:u64)* output:rest`, which the host keeps readable
## until the next call. The task may call the platform's hosted effects;
## nothing else that runs in an instance can. A worker instance never
## mounts.
work_for_host! : List(U8), List(Box(U64)) => List(U8)
work_for_host! = |payload, handles| Core.work!(main, payload, handles)

## A worker instance's preparation (design.md, "Prepared state"): run the
## preparation named in `prep:str init:rest` with the handles of its files
## and return the state the instance keeps, which the host owns until a
## job runs a task on it or the instance forgets it.
prepare_for_host! : List(U8), List(Box(U64)) => Box(Core.Kept)
prepare_for_host! = |payload, handles| Box.box(Core.work_prepare!(main, payload, handles))

## A job of a preparation's task on the held state: the state moves in and
## back out with the job's answer, so the host owns it again after the call.
ask_for_host! : Box(Core.Kept), List(U8), List(Box(U64)) => { held : Box(Core.Kept), out : List(U8) }
ask_for_host! = |boxed, payload, handles| {
	state = Box.unbox(boxed)
	out = Core.work_ask!(state, payload, handles)
	{ held: Box.box(state), out }
}

## Let go of the held state: the instance evicts it or prepares another.
forget_for_host : Box(Core.Kept) -> {}
forget_for_host = |_boxed| {}

## Teardown: the state and both buffers are released with the call.
drop_for_host : Box(Core.App), List(U8), List(U8) -> {}
drop_for_host = |_boxed, _buf, _wbuf| {}

## The native spec runner: `SpecRunner.main!` over this app's `main`, with
## the native host's file and output services.
spec_main_for_host! : List(Str) => I32
spec_main_for_host! = |args| SpecRunner.main!(Core.driver(main), { read_file!: Cli.read_file!, stdout!: Cli.stdout!, stderr!: Cli.stderr!, now_ns!: Cli.now_ns!, work!: Cli.work!, mint_files!: Cli.mint_files!, live_files!: Cli.live_files!, sha256!: Cli.sha256! }, args)
