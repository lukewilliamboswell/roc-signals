app [main] { pf: platform "../../../platform-gui/main.roc" }

import pf.Action exposing [Action]
import pf.Elem exposing [Elem]
import pf.Env
import pf.Files
import pf.Signal
import pf.Ui

Status : [Idle, Running, Done(Str), Failed(Str)]

status_text : Status -> Str
status_text = |status| match status {
	Idle => "Idle"
	Running => "Running"
	Done(text) => "Done: ${text}"
	Failed(text) => "Failed: ${text}"
}

## The effect of a successful chain: a top-level effectful function. It takes
## the state handle it writes and the fresh snapshot of the action's reads, so
## it captures nothing and can never see a stale value.
read_variable! : Ui.State(Status), Str => Action(Str)
read_variable! = |status, name| match Env.var!(name) {
	Ok(value) => if value.is_empty() { Action.update([status.set(Failed("${name} is empty"))]) } else { Action.update([status.set(Done("${name} is set"))]) }
	Err(Missing) => Action.update([status.set(Failed("${name} is missing"))])
}

## Writes a file through the hosted `Files.write_text!`, reads it back, and
## reports what came back.
roundtrip_file! : Ui.State(Status), Str => Action(Str)
roundtrip_file! = |status, _name| {
	path = "/tmp/roc-signals-action-fixture.txt"
	match Files.write_text!({ path, text: "hello file" }) {
		Err(err) => Action.update([status.set(Failed(Files.error_text(err)))])
		Ok(_) => match Files.read_text!(path) {
			Ok(file) => Action.update([status.set(Done("read ${file.text}"))])
			Err(err) => Action.update([status.set(Failed(Files.error_text(err)))])
		}
	}
}

## Exercises `Action.then`: a button commits `Running`, then runs an effect
## that calls the hosted `Env.var!`, then commits the outcome.
main : () -> Elem
main = || Ui.state(
	Idle,
	|status| {
		reads = Signal.const("HOME")
		Elem.col(
			{ test_id: "action-fixture" },
			[
				Elem.heading("Action fixture"),
				Elem.text_s(status.read(status_text)),
				Elem.button("Succeed", Action.run(reads, |_| Action.then([status.set(Running)], |name| read_variable!(status, name)))),
				Elem.button("Fail", Action.run(reads, |_| Action.then([status.set(Running)], |_| Action.update([status.set(Failed("boom"))])))),
				Elem.button("Write", Action.run(reads, |_| Action.then([status.set(Running)], |name| roundtrip_file!(status, name)))),
				Elem.button("Reset", Action.run(reads, |_| Action.update([status.set(Idle)]))),
			],
		)
	},
)
