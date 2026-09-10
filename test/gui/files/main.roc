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
	listing = Files.list_directory_task("fixture-list")
	preview = Files.read_preview_task("fixture-preview")
	log = Files.read_log_task("fixture-log")
	opened = Files.open_path_task("fixture-open")
	status = Signal.fold_task(task, "Loading", |file| "Loaded ${file.text.to_utf8().len().to_str()} bytes", Files.error_text)
	Gui.column(
		{ test_id: "files-fixture" },
		[
			Gui.heading("Native Files fixture"),
			Gui.text_s(status),
			Gui.text_s(Signal.fold_task(listing, "Listing pending", |result| "Listed ${result.entries.len().to_str()} direct entries", Files.error_text)),
			Gui.text_s(Signal.fold_task(preview, "Preview pending", |result| "Preview: ${result.text}", Files.error_text)),
			Gui.text_s(Signal.fold_task(log, "Log pending", |result| "Log: ${result.text}", Files.error_text)),
			Gui.text_s(Signal.fold_task(opened, "Open pending", |result| "Opened: ${result.path}", Files.error_text)),
			Gui.button("List", Ui.action(Signal.const({}), |_| Files.list_directory(listing, "/tmp/roc-signals-files-depth"))),
			Gui.button("Preview", Ui.action(Signal.const(path), |value| Files.read_preview(preview, value))),
			Gui.button("Log", Ui.action(Signal.const(path), |value| Files.read_log(log, { path: value, position: Files.LogPosition.Start }))),
			Gui.button("Open associated", Ui.action(Signal.const(path), |value| Files.open_path(opened, value))),
			Gui.button("Cancel log", Ui.action(Signal.const({}), |_| Signal.cancel(log))),
			Gui.action_button({ caption: Signal.const("Read") }, Ui.action(Signal.const(path), |value| Files.read_text(task, value))),
			Gui.action_button({ caption: Signal.const("Cancel") }, Ui.action(Signal.const({}), |_| Signal.cancel(task))),
			Ui.on_mount(|| Files.read_text(task, path)),
		],
	)
}
