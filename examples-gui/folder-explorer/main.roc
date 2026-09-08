app [main] { pf: platform "../../platform-gui/main.roc" }

import Explorer
import Session
import pf.Files
import pf.Elem exposing [Elem]
import pf.Gui
import pf.Rows
import pf.Signal
import pf.Ui

Handles : {
	model : Ui.State(Session.State),
	query : Ui.State(Str),
	order : Ui.State(Explorer.Sort),
}

## Filtering and sorting are explicit whole-dataset operations. Selection is a
## separate signal, so choosing one result does not repeat either operation.
visible_entries : Rows.Rows(Explorer.Entry), Str, Explorer.Sort -> Rows.Rows(Explorer.Entry)
visible_entries = |entries, query, order| {
	filtered = Explorer.filter(Rows.to_list(entries), query)
	Rows.replace_all(entries, Explorer.sort(filtered, order)) ?? crash "Filtering and sorting must preserve unique paths"
}

entry_row : Ui.Row(Explorer.Entry), Handles, Signal.Signal(Str) -> Elem
entry_row = |row, handles, selected| {
	key = row.key()
	Gui.row(
		[
			Gui.test_id("entry:${key}"),
			Gui.selected_s(Signal.select(selected, key)),
			Gui.style({ ..Gui.style_default, padding: 8, gap: 12, width: Fill, border_width: 1, border_color: Rgb(0x354452) }),
		],
		[
			Gui.action_button(
				{ label: row.map(|entry| entry.path), enabled: Signal.const(True) },
				[Gui.style({ ..Gui.style_default, grow: True, width: Fill, padding: 6 })],
				Ui.action(row.signal(), |entry| handles.model.update_cmd(|state| { ..state, selection: Selected(entry) })),
			),
			Gui.text_s(row.map(|entry| entry.kind.to_str())),
			Gui.text_s(row.map(Explorer.size_text)),
		],
	)
}

selection_view : Signal.Signal(Explorer.Selection) -> Elem
selection_view = |selection|
	Gui.panel(
		[Gui.test_id("file-details"), Gui.style({ ..Gui.style_default, width: Px(300), gap: 12, padding: 16, background: Rgb(0x24323E), radius: 8 })],
		[
			Gui.heading("File details"),
			Gui.text_s(
				selection.map(
					|value| match value {
						NoSelection => "Select a file or folder to inspect its metadata."
						Selected(entry) => entry.path
					},
				),
			),
			Gui.text_s(
				selection.map(
					|value| match value {
						NoSelection => ""
						Selected(entry) => "Kind: ${entry.kind.to_str()}"
					},
				),
			),
			Gui.text_s(
				selection.map(
					|value| match value {
						NoSelection => ""
						Selected(entry) => "Size: ${Explorer.size_text(entry)}"
					},
				),
			),
		],
	)

explorer_view : Handles -> Elem
explorer_view = |handles| {
	chooser = Files.choose_directory_task("folder-choice")
	scan = Files.scan_task("folder-scan")
	model = handles.model.signal()
	dataset_rows = model.map(|state| state.rows)
	selection = model.map(|state| state.selection)
	phase = model.map(|state| state.phase)
	busy = phase.map(|value| value != Idle)
	can_rescan = model.map(|state| state.phase == Idle and state.source != Sample)
	views = { entries: dataset_rows, query: handles.query.signal(), order: handles.order.signal() }.Signal
	visible = views.map(|current| visible_entries(current.entries, current.query, current.order))
	selected = selection.map(
		|value| match value {
			NoSelection => ""
			Selected(entry) => entry.path
		},
	)
	total = dataset_rows.map(|entries| Explorer.summary(Rows.to_list(entries)))
	choose_action = Ui.action(Signal.const({}), |_| handles.model.update_cmd(Session.begin_choose))
	rescan_action = Ui.action(Signal.const({}), |_| handles.model.update_cmd(Session.rescan))
	cancel_action = Ui.action(
		phase,
		|value| match value {
			Choosing => Signal.cancel(chooser)
			Scanning(_) => Signal.cancel(scan)
			Idle => Signal.noop
		},
	)
	Gui.column(
		[
			Gui.test_id("explorer"),
			Gui.style({ ..Gui.style_default, gap: 16, padding: 20, width: Fill, height: Fill }),
			Gui.on_shortcut({ key: "o", control: True, shift: False, alt: False, meta: False }, choose_action),
			Gui.on_shortcut({ key: "F5", control: False, shift: False, alt: False, meta: False }, rescan_action),
			Gui.on_shortcut({ key: "Escape", control: False, shift: False, alt: False, meta: False }, cancel_action),
		],
		[
			Ui.on_change(
				phase,
				|value| match value {
					Idle => Signal.noop
					Choosing => Files.choose_directory(chooser)
					Scanning(path) => Files.scan(scan, path)
				},
			),
			Ui.on_change(
				Signal.from_task(chooser),
				|value| match value {
					Signal.TaskStatus.Loading => Signal.noop
					Signal.TaskStatus.Done(choice) => handles.model.update_cmd(|state| Session.chosen(state, choice))
					Signal.TaskStatus.Failed(error) => handles.model.update_cmd(|state| Session.failed(state, error))
				},
			),
			Ui.on_change(
				Signal.from_task(scan),
				|value| match value {
					Signal.TaskStatus.Loading => Signal.noop
					Signal.TaskStatus.Done(result) => handles.model.update_cmd(|state| Session.loaded(state, result))
					Signal.TaskStatus.Failed(error) => handles.model.update_cmd(|state| Session.failed(state, error))
				},
			),
			Gui.heading("Folder Explorer"),
			Gui.panel(
				[Gui.test_id("dataset-source")],
				[
					Gui.text_s(
						model.map(
							|state| match state.source {
								Sample => "Sample workspace"
								Folder(path) => "Folder: ${path}"
							},
						),
					),
				],
			),
			Gui.row(
				[],
				[
					Gui.action_button({ label: Signal.const("Choose folder"), enabled: busy.map(|value| !value) }, [Gui.test_id("choose-folder")], Ui.action(Signal.const({}), |_| handles.model.update_cmd(Session.begin_choose))),
					Gui.action_button({ label: Signal.const("Rescan"), enabled: can_rescan }, [Gui.test_id("rescan")], Ui.action(Signal.const({}), |_| handles.model.update_cmd(Session.rescan))),
					Gui.action_button(
						{ label: Signal.const("Cancel"), enabled: busy },
						[Gui.test_id("cancel-operation")],
						Ui.action(
							phase,
							|value| match value {
								Choosing => Signal.cancel(chooser)
								Scanning(_) => Signal.cancel(scan)
								Idle => Signal.noop
							},
						),
					),
					Gui.action_button({ label: Signal.const("Load sample"), enabled: busy.map(|value| !value) }, [], Ui.action(Signal.const({}), |_| handles.model.update_cmd(Session.load_sample))),
				],
			),
			Gui.panel([Gui.test_id("operation-status")], [Gui.text_s(model.map(|state| state.notice))]),
			Gui.text("Inspect file sizes and find the files that matter. Ctrl+O chooses a folder; F5 rescans; Esc cancels."),
			Gui.text_input({ label: "Filter paths", value: handles.query.signal() }, [], handles.query.on_str(|_, text| text)),
			Gui.row(
				[Gui.style({ ..Gui.style_default, gap: 8 })],
				Explorer.sorts.map(|order| Gui.action_button({ label: Signal.const(order.to_str()), enabled: Signal.const(True) }, [Gui.selected_s(handles.order.signal().map(|current| current == order))], handles.order.on_unit(|_| order))),
			),
			Gui.panel(
				[Gui.test_id("dataset-summary")],
				[Gui.text_s(total.map(|summary| "${summary.files.to_str()} files · ${summary.folders.to_str()} folders · ${summary.links.to_str()} links · ${summary.other.to_str()} other · ${summary.bytes.to_str()} B"))],
			),
			Gui.panel(
				[Gui.test_id("results-summary")],
				[Gui.text_s(visible.map(|entries| "${Rows.len(entries).to_str()} matching entries"))],
			),
			Gui.row(
				[Gui.style({ ..Gui.style_default, gap: 20, width: Fill, grow: True })],
				[
					Gui.column(
						[Gui.test_id("file-list"), Gui.style({ ..Gui.style_default, grow: True, width: Fill, gap: 4 })],
						[
							Ui.when(visible.map(|entries| Rows.len(entries) == 0), || Gui.text("No matching paths. Try a different filter."), || Gui.text("")),
							Gui.virtual_list({ row_height: 52, follow_tail: Signal.const(False) }, [Gui.test_id("file-viewport"), Gui.style({ ..Gui.style_default, height: Fill, width: Fill, grow: True })], [Ui.each(visible, |row| entry_row(row, handles, selected))]),
						],
					),
					selection_view(selection),
				],
			),
		],
	)
}

main : () -> Elem
main = || Ui.state(Session.initial, |model| Ui.state("", |query| Ui.state(NameAscending, |order| explorer_view({ model, query, order }))))
