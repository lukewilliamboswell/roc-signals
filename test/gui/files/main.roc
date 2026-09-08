app [main] { pf: platform "../../../platform-gui/main.roc" }

import pf.Elem exposing [Elem]
import pf.Files
import pf.Gui
import pf.Signal
import pf.Ui

main : () -> Elem
main = || {
	task = Files.read_text_task("fixture-read")
	path = "/tmp/roc-signals-files-fixture.txt"
	status = Signal.fold_task(task, "Loading", |file| "Loaded ${file.text.to_utf8().len().to_str()} bytes", Files.error_text)
	Gui.column([Gui.test_id("files-fixture")], [
		Gui.heading("Native Files fixture"),
		Gui.text_s(status),
		Gui.action_button({ label: Signal.const("Read"), enabled: Signal.const(True) }, [], Ui.action(Signal.const(path), |value| Files.read_text(task, value))),
		Gui.action_button({ label: Signal.const("Cancel"), enabled: Signal.const(True) }, [], Ui.action(Signal.const({}), |_| Signal.cancel(task))),
		Ui.on_mount(|| Files.read_text(task, path)),
	])
}
