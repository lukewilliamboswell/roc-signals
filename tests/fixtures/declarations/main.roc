app [main] { pf: platform "../../../platform/main.roc" }

import pf.Engine
import pf.Port
import pf.Worker

## The negative native-runner fixture must never initialize. It deliberately
## omits Engine.mounts so the real command can prove refusal before this view.
main : Engine.Program(Store)
main = Engine.program_boot(
	{ storage_keys: ["local"], session_keys: ["session"], media: ["screen"] },
	|_boot| crash "declaration fixture unexpectedly initialized",
).with_ports(Port.registrations(ports)).with_workers([task.registration(), owner.registration([])])

## This fixture has no store and its view can never legitimately run.
Store : {}

ports : { command : Port.Command(Str), call : Port.Call(Str, Str), subscription : Port.Subscription(Str, Str) }
ports = {
	command: Port.command({ name: "command" }),
	call: Port.call({ name: "call" }),
	subscription: Port.subscription({ name: "subscription", delivery: Latest }),
}

task : Worker.Task({}, {}, Worker.Never)
task = Worker.task({ name: "task", run!: |_input| Ok({}) })

## Nightly 2026-11-13-03dce41 crashes while building an empty preparation
## catalogue with Never: https://github.com/roc-lang/roc/issues/13056.
## TODO: restore Worker.Never once fixed. Preparation still always succeeds;
## declaration validation must never initialize this fixture.
PreparationError : [PreparationUnavailable]

owner : Worker.Preparation({}, {}, PreparationError)
owner = Worker.preparation({ name: "empty-owner", prepare!: |_input| Ok({}) })
