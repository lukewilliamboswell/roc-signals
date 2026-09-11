app [main] { pf: platform "../../../platform-gui/main.roc" }

import pf.Action exposing [Action]
import pf.Elem exposing [Elem]
import pf.Files
import pf.Signal
import pf.Ui

## Exercises the `Files` primitives and the conveniences built on them from
## inside an action's effect. The spec host answers each primitive from
## declared stubs.
main : () -> Elem
main = || Ui.state(
	"Idle",
	|status| {
		path = "/tmp/roc-signals-files-fixture.txt"
		Elem.col(
			{ test_id: "files-fixture" },
			[
				Elem.heading("Native Files fixture"),
				Elem.text_s(status.signal()),
				Elem.button("Read", Action.run(Signal.const(path), |_| Action.then([status.set("Reading")], |target| read!(status, target)))),
				Elem.button("Write", Action.run(Signal.const(path), |_| Action.then([status.set("Writing")], |target| write!(status, target)))),
				Elem.button("Stat", Action.run(Signal.const(path), |_| Action.then([], |target| stat!(status, target)))),
				Elem.button("Read bytes", Action.run(Signal.const(path), |_| Action.then([], |target| read_bytes!(status, target)))),
				Elem.button("List", Action.run(Signal.const("/tmp/roc-signals-files-depth"), |_| Action.then([], |target| list!(status, target)))),
				Elem.button("Scan", Action.run(Signal.const("/tmp/roc-signals-files-depth"), |_| Action.then([], |target| scan!(status, target)))),
				Elem.button("Preview", Action.run(Signal.const(path), |_| Action.then([], |target| preview!(status, target)))),
				Elem.button("Open associated", Action.run(Signal.const(path), |_| Action.then([], |target| open!(status, target)))),
				Elem.button("Verify assets", Action.run(Signal.const(path), |_| Action.then([], |_| verify!(status)))),
				Action.on_mount(|| Action.then([], |_| read!(status, path))),
			],
		)
	},
)

report : Ui.State(Str), Try(a, Files.Error), (a -> Str) -> Action(reads)
report = |status, result, describe| match result {
	Ok(value) => Action.update([status.set(describe(value))])
	Err(error) => Action.update([status.set(Files.error_text(error))])
}

read! : Ui.State(Str), Str => Action(reads)
read! = |status, path| report(status, Files.read_text!(path), |file| "Loaded ${file.text.to_utf8().len().to_str()} bytes")

write! : Ui.State(Str), Str => Action(reads)
write! = |status, path| report(status, Files.write_text!({ path, text: "hello" }), |written| "Wrote ${written.bytes.to_str()} bytes")

stat! : Ui.State(Str), Str => Action(reads)
stat! = |status, path| report(status, Files.stat!(path), |meta| "Size ${meta.bytes.to_str()} inode ${meta.inode.to_str()}")

read_bytes! : Ui.State(Str), Str => Action(reads)
read_bytes! = |status, path| report(status, Files.read_bytes!({ path, offset: 2, max_bytes: 3 }), |read| "Bytes ${read.bytes.len().to_str()} of ${read.size.to_str()}")

list! : Ui.State(Str), Str => Action(reads)
list! = |status, path| report(status, Files.list_directory!(path), |result| "Listed ${result.entries.len().to_str()} direct entries")

scan! : Ui.State(Str), Str => Action(reads)
scan! = |status, path| report(status, Files.scan!(path), |result| "Scanned ${result.entries.len().to_str()} entries")

preview! : Ui.State(Str), Str => Action(reads)
preview! = |status, path| report(status, Files.read_preview!(path), |result| "Preview: ${result.text}${if result.truncated { " (truncated)" } else { "" }}")

open! : Ui.State(Str), Str => Action(reads)
open! = |status, path| report(status, Files.open_path!(path), |_| "Opened: ${path}")

verify! : Ui.State(Str) => Action(reads)
verify! = |status| report(status, Files.verify_assets!([{ name: "avatars/maya.png", sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" }]), |checks| "Verified ${checks.len().to_str()} assets: ${Str.join_with(checks.map(|check| if check.status == Ok { "ok" } else if check.status == Missing { "missing" } else { "mismatch" }), ",")}")
