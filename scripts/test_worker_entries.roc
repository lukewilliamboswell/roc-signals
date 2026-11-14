#!/usr/bin/env roc-stable
app [main!] {
	cli: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.1/7brgwR8YUqfeGrkdfF1V4GPPN7DnP7ftqub9KcrTEZtr.tar.zst",
	pf: "../platform/main-fuzz.roc",
	roc: "nightly-2026-11-13-03dce41",
}

import cli.OsStr
import pf.Dom
import pf.SpecRunner

## Exercise the runner's real hosted worker-answer path. Recording wraps the
## Program entries, so the test observes calls rather than restating dispatch.
main! : List(OsStr) => Try({}, _)
main! = |_args| {
	program = SpecRunner.recording(probe({}))
	(inst, _, _) = (program.init)([])
	base = SpecRunner.fresh(inst, SpecRunner.fresh_browser({}))
	output = [42.U8, 0]
	empty = SpecRunner.put_u64(SpecRunner.put_u32([10], 0), output.len()).concat(output)
	metadata = SpecRunner.put_str(SpecRunner.put_str(SpecRunner.put_u64(SpecRunner.put_u32([10], 1), 3), "answer.txt"), "text/plain")
	with_file = SpecRunner.put_u64(metadata, output.len()).concat(output).concat([97, 98, 99])
	mint! = |count| List.repeat(Box.box(41.U64), count)
	plain = SpecRunner.deliver_work!(program, base, 7, empty, mint!)?
	files = SpecRunner.deliver_work!(program, base, 7, with_file, mint!)?
	refused = SpecRunner.deliver_work!(program, base, 7, with_file, |_count| [])?
	actual = {
		plain: describe(plain.inst.calls),
		files: describe(files.inst.calls),
		refused: describe(refused.inst.calls),
		file_bytes: files.browser.files.map(|file| file.bytes),
	}
	expected = {
		plain: [{ entry: "event", node: SpecRunner.fx_node, handler: InFlight(0), payload: SpecRunner.put_u32([10], 0).concat(output), handles: [] }],
		files: [{ entry: "files", node: SpecRunner.fx_node, handler: InFlight(0), payload: metadata.concat(output), handles: [41] }],
		refused: [{ entry: "event", node: SpecRunner.fx_node, handler: InFlight(0), payload: [11, 2], handles: [] }],
		file_bytes: [[97, 98, 99]],
	}
	if actual == expected {
		Ok({})
	} else {
		Err(WorkerAnswerEntryMismatch(actual))
	}
}

## A minimal Program has a live request and no command or worker simulation.
## Its actual entry is observed by SpecRunner.recording's ordinary wrappers.
probe : {} -> SpecRunner.Program({})
probe = |_props| {
	version: Dom.protocol_version,
	tasks: [],
	keys: || [],
	init: |_boot| ({}, [], List.repeat(0, 8)),
	event: |inst, _buf, _work, _node, _handler, _payload| (inst, [], List.repeat(0, 8)),
	files: |inst, _buf, _work, _node, _handler, _payload, _handles| (inst, [], List.repeat(0, 8)),
	settled: |_inst| Ok({}),
	live: |_inst| [7],
}

## Report observable call fields without retaining handles in the assertion.
describe : List(SpecRunner.Call) -> List({ entry : Str, node : U32, handler : [Handler(U32), InFlight(U64)], payload : List(U8), handles : List(U64) })
describe = |calls| calls.map(
	|call| {
		entry: match call.files {
			Event => "event"
			Files(_) => "files"
		},
		node: call.node,
		handler: call.handler,
		payload: call.payload,
		handles: match call.files {
			Event => []
			Files(handles) => handles.map(Box.unbox)
		},
	},
)
