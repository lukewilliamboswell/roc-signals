app [main] { pf: platform "../../../platform-gui/main.roc" }

import pf.Action exposing [Action]
import pf.Elem exposing [Elem]
import pf.Env
import pf.Files
import pf.Ui

## Two effects queued by the same mount handshake through a file: the first
## writes a waiting mark and polls for a ready mark, the second polls for the
## waiting mark and then writes the ready mark. The handshake completes only
## while both effects run at the same time, which is what the live host's
## worker pool provides; run the built fixture with `--smoke` and
## `--smoke-expect "Both effects overlapped"` to prove it. The spec host runs
## effects one at a time and answers both sides from stubs.
path = "/tmp/roc-signals-overlap-fixture.txt"

main : () -> Elem
main = || Ui.state(
	"Idle",
	|status| Elem.col(
		{ test_id: "overlap-fixture" },
		[
			Elem.heading("Effect overlap fixture"),
			Elem.text_s(status.signal()),
			Action.on_mount(|| Action.then([status.set("Running")], |_| wait_for_ready!(status))),
			Action.on_mount(|| Action.then([], |_| answer_waiting!(status))),
		],
	),
)

## Marks from an earlier run never match when the launcher sets a fresh nonce.
nonce! : () => Str
nonce! = || match Env.var!("ROC_SIGNALS_OVERLAP_NONCE") {
	Ok(value) => value
	Err(Missing) => "0"
}

wait_for_ready! : Ui.State(Str) => Action({})
wait_for_ready! = |status| {
	token = nonce!()
	match Files.write_text!({ path, text: "waiting-${token}" }) {
		Err(error) => Action.update([status.set(Files.error_text(error))])
		Ok(_) => if poll!("ready-${token}", 20000) {
			Action.update([status.set("Both effects overlapped")])
		} else {
			Action.update([status.set("The second effect never ran while the first waited")])
		}
	}
}

answer_waiting! : Ui.State(Str) => Action({})
answer_waiting! = |status| {
	token = nonce!()
	if poll!("waiting-${token}", 20000) {
		match Files.write_text!({ path, text: "ready-${token}" }) {
			Ok(_) => Action.none
			Err(error) => Action.update([status.set(Files.error_text(error))])
		}
	} else {
		Action.update([status.set("The first effect never ran while the second waited")])
	}
}

## Reads the file until it holds `expected`, giving up after `remaining` reads.
poll! : Str, U64 => Bool
poll! = |expected, remaining| if remaining == 0 {
	False
} else {
	match Files.read_text!(path) {
		Ok(file) if file.text == expected => True
		_ => poll!(expected, remaining - 1)
	}
}
