app [main] { pf: platform "../../platform-gui/main.roc" }

import Explorer
import Session
import pf.Files
import pf.Elem exposing [Elem]
import pf.Gui
import pf.Rows
import pf.Signal
import pf.Ui

Handles : { model : Ui.State(Session.State), order : Ui.State(Explorer.Sort) }

Tasks : {
	chooser : Signal.Task(Files.Choice, Files.Error),
	listing : Signal.Task(Files.Directory, Files.Error),
	preview : Signal.Task(Files.Preview, Files.Error),
	open : Signal.Task(Files.Opened, Files.Error),
}

## Filtering and ordering run only when their projected inputs change. Selection
## remains independent of this explicit operation over the current directory.
visible_entries : Rows.Rows(Explorer.Entry), Str, Explorer.Sort -> Rows.Rows(Explorer.Entry)
visible_entries = |entries, query, order| {
	filtered = Explorer.filter(Rows.to_list(entries), query)
	Rows.replace_all(entries, Explorer.sort(filtered, order)) ?? crash "Filtering and sorting must preserve unique paths"
}

entry_row : Ui.Row(Explorer.Entry), Handles, Signal.Signal(Str), Signal.Signal(Bool) -> Elem
entry_row = |row, handles, selected, ready| {
	key = row.key()
	Gui.row(
		[
			Gui.test_id("entry:${key}"),
			Gui.selected_s(Signal.select(selected, key)),
			Gui.style({ ..Gui.style_default, padding: 8, gap: 12, width: Fill, border_width: 1, border_color: Rgb(0x354452) }),
		],
		[
			Gui.action_button(
				{ label: row.map(|entry| Explorer.file_name(entry.path)), enabled: ready },
				[Gui.label(key), Gui.style({ ..Gui.style_default, grow: True, width: Fill, padding: 6, overflow_x: Clip })],
				Ui.action(row.signal(), |entry| handles.model.update_cmd(|state| Session.activate(state, entry))),
			),
			Gui.text_s(row.map(|entry| entry.kind.to_str())),
			Gui.text_s(row.map(Explorer.size_text)),
		],
	)
}

inspect_view : Handles -> Elem
inspect_view = |handles| {
	model = handles.model.signal()
	selection = model.map(|state| state.selection)
	can_preview = model.map(
		|state| state.phase == Idle and match state.selection {
			Selected(entry) => entry.kind == File
			NoSelection => False
		},
	)
	can_open = Signal.map2(
		can_preview,
		model.map(|state| state.source),
		|ready, source| ready and match source {
			Folder(_) => True
			Sample(_) => False
		},
	)
	Gui.panel(
		[Gui.test_id("file-details"), Gui.style({ ..Gui.style_default, width: Px(380), height: Fill, gap: 12, padding: 16, background: Rgb(0x24323E), radius: 8 })],
		[
			Gui.heading("File details"),
			Gui.text_s(
				selection.map(
					|value| match value {
						NoSelection => "Select a file to inspect it. Open a folder to browse its contents."
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
			Gui.row(
				[Gui.style({ ..Gui.style_default, gap: 8 })],
				[
					Gui.action_button({ label: Signal.const("Preview text"), enabled: can_preview }, [], Ui.action(Signal.const({}), |_| handles.model.update_cmd(Session.preview_selected))),
					Gui.action_button({ label: Signal.const("Open in app"), enabled: can_open }, [], Ui.action(Signal.const({}), |_| handles.model.update_cmd(Session.open_selected))),
				],
			),
			Gui.text_s(
				selection.map(
					|value| match value {
						Selected(entry) if entry.kind == SymbolicLink => "Symbolic links are shown but are not followed."
						Selected(entry) if entry.kind == Other => "Special files are shown as metadata only."
						_ => "Text previews are limited to 64 KiB. Open in app uses this computer's file associations."
					},
				),
			),
			Gui.text_s(
				model.map(
					|state| match state.preview {
						NoPreview => "No preview loaded."
						Ready(preview) => if preview.truncated {
							"Preview: ${preview.path} · truncated"
						} else {
							"Preview: ${preview.path}"
						}
					},
				),
			),
			Gui.textarea(
				{
					label: "Text preview",
					value: model.map(
						|state| match state.preview {
							NoPreview => ""
							Ready(preview) => preview.text
						},
					),
				},
				[Gui.test_id("text-preview"), Gui.disabled_s(Signal.const(True)), Gui.style({ ..Gui.style_default, width: Fill, height: Fill, grow: True })],
				handles.model.on_str(|state, _| state),
			),
		],
	)
}

cancel : Tasks, Session.Phase -> Gui.Cmd
cancel = |tasks, phase| match phase {
	Choosing => Signal.cancel(tasks.chooser)
	Listing(_) => Signal.cancel(tasks.listing)
	Previewing(_) => Signal.cancel(tasks.preview)
	Opening(_) => Signal.cancel(tasks.open)
	Idle => Signal.noop
}

workflow : Handles, Tasks -> List(Elem)
workflow = |handles, tasks| [
	Ui.on_change(
		handles.model.signal().map(|state| state.phase),
		|phase| match phase {
			Idle => Signal.noop
			Choosing => Files.choose_directory(tasks.chooser)
			Listing(visit) => Files.list_directory(tasks.listing, Session.path(visit.destination))
			Previewing(path) => Files.read_preview(tasks.preview, path)
			Opening(path) => Files.open_path(tasks.open, path)
		},
	),
	Ui.on_change(
		Signal.from_task(tasks.chooser),
		|status| match status {
			Signal.TaskStatus.Loading => Signal.noop
			Signal.TaskStatus.Done(result) => handles.model.update_cmd(|state| Session.chosen(state, result))
			Signal.TaskStatus.Failed(error) => handles.model.update_cmd(|state| Session.failed(state, error))
		},
	),
	Ui.on_change(
		Signal.from_task(tasks.listing),
		|status| match status {
			Signal.TaskStatus.Loading => Signal.noop
			Signal.TaskStatus.Done(result) => handles.model.update_cmd(|state| Session.loaded(state, result))
			Signal.TaskStatus.Failed(error) => handles.model.update_cmd(|state| Session.failed(state, error))
		},
	),
	Ui.on_change(
		Signal.from_task(tasks.preview),
		|status| match status {
			Signal.TaskStatus.Loading => Signal.noop
			Signal.TaskStatus.Done(result) => handles.model.update_cmd(|state| Session.previewed(state, result))
			Signal.TaskStatus.Failed(error) => handles.model.update_cmd(|state| Session.failed(state, error))
		},
	),
	Ui.on_change(
		Signal.from_task(tasks.open),
		|status| match status {
			Signal.TaskStatus.Loading => Signal.noop
			Signal.TaskStatus.Done(result) => handles.model.update_cmd(|state| Session.opened(state, result))
			Signal.TaskStatus.Failed(error) => handles.model.update_cmd(|state| Session.failed(state, error))
		},
	),
]

explorer_view : Handles -> Elem
explorer_view = |handles| {
	tasks = { chooser: Files.choose_directory_task("folder-choice"), listing: Files.list_directory_task("folder-list"), preview: Files.read_preview_task("file-preview"), open: Files.open_path_task("file-open") }
	model = handles.model.signal()
	dataset = model.map(|state| state.rows)
	source = model.map(|state| state.source)
	phase = model.map(|state| state.phase)
	ready = phase.map(|value| value == Idle)
	views = { entries: dataset, query: model.map(|state| state.query), order: handles.order.signal() }.Signal
	visible = views.map(|current| visible_entries(current.entries, current.query, current.order))
	selected = model.map(
		|state| match state.selection {
			NoSelection => ""
			Selected(entry) => entry.path
		},
	)
	total = dataset.map(|entries| Explorer.summary(Rows.to_list(entries)))
	choose_action = Ui.action(Signal.const({}), |_| handles.model.update_cmd(Session.begin_choose))
	refresh_action = Ui.action(Signal.const({}), |_| handles.model.update_cmd(Session.refresh))
	back_action = Ui.action(Signal.const({}), |_| handles.model.update_cmd(Session.backward))
	forward_action = Ui.action(Signal.const({}), |_| handles.model.update_cmd(Session.forward))
	up_action = Ui.action(Signal.const({}), |_| handles.model.update_cmd(Session.up))
	cancel_action = Ui.action(phase, |value| cancel(tasks, value))
	crumbs = source.map(|location| Rows.from_list(Session.breadcrumbs(location), |crumb| crumb.path) ?? crash "Breadcrumb paths must be unique")
	Gui.column(
		[
			Gui.test_id("explorer"),
			Gui.style({ ..Gui.style_default, gap: 12, padding: 20, width: Fill, height: Fill }),
			Gui.on_shortcut({ key: "o", control: True, shift: False, alt: False, meta: False }, choose_action),
			Gui.on_shortcut({ key: "F5", control: False, shift: False, alt: False, meta: False }, refresh_action),
			Gui.on_shortcut({ key: "Escape", control: False, shift: False, alt: False, meta: False }, cancel_action),
			Gui.on_shortcut({ key: "ArrowLeft", control: False, shift: False, alt: True, meta: False }, back_action),
			Gui.on_shortcut({ key: "ArrowRight", control: False, shift: False, alt: True, meta: False }, forward_action),
			Gui.on_shortcut({ key: "ArrowUp", control: False, shift: False, alt: True, meta: False }, up_action),
		],
		workflow(handles, tasks).concat([
			Gui.heading("Folder Explorer"),
			Gui.row(
				[Gui.style({ ..Gui.style_default, gap: 8 })],
				[
					Gui.action_button({ label: Signal.const("Back"), enabled: model.map(|state| state.phase == Idle and !state.back.is_empty()) }, [], back_action),
					Gui.action_button({ label: Signal.const("Forward"), enabled: model.map(|state| state.phase == Idle and !state.forward.is_empty()) }, [], forward_action),
					Gui.action_button({ label: Signal.const("Up"), enabled: model.map(|state| state.phase == Idle and Session.path(state.source) != Explorer.parent_path(Session.path(state.source))) }, [], up_action),
					Gui.action_button({ label: Signal.const("Refresh"), enabled: ready }, [], refresh_action),
					Gui.action_button({ label: Signal.const("Choose folder"), enabled: ready }, [], choose_action),
					Gui.action_button({ label: Signal.const("Use sample"), enabled: ready }, [], Ui.action(Signal.const({}), |_| handles.model.update_cmd(Session.load_sample))),
					Gui.action_button({ label: Signal.const("Cancel"), enabled: ready.map(|value| !value) }, [], cancel_action),
					Gui.action_button({ label: Signal.const("Retry"), enabled: model.map(|state| state.phase == Idle and state.retry != NoRetry) }, [], Ui.action(Signal.const({}), |_| handles.model.update_cmd(Session.retry_last))),
				],
			),
			Gui.row(
				[Gui.test_id("breadcrumbs"), Gui.style({ ..Gui.style_default, gap: 6, width: Fill, overflow_x: Scroll })],
				[
					Ui.each(
						crumbs,
						|row| Gui.action_button(
							{ label: row.map(|crumb| crumb.label), enabled: ready },
							[
								Gui.label(
									if row.key().is_empty() {
										"Go to sample root"
									} else {
										"Go to ${row.key()}"
									},
								),
							],
							Ui.action(row.signal(), |crumb| handles.model.update_cmd(|state| Session.navigate(state, crumb.path))),
						),
					),
				],
			),
			Gui.panel(
				[Gui.test_id("dataset-source")],
				[
					Gui.text_s(
						model.map(
							|state| match state.source {
								Sample(path) => if path.is_empty() {
									"Sample workspace"
								} else {
									"Sample workspace / ${path}"
								}
								Folder(path) => "Folder: ${path}"
							},
						),
					),
				],
			),
			Gui.panel([Gui.test_id("operation-status")], [Gui.text_s(model.map(|state| state.notice))]),
			Gui.row(
				[Gui.style({ ..Gui.style_default, gap: 8, width: Fill })],
				[
					Gui.text_input({ label: "Filter this folder", value: model.map(|state| state.query) }, [Gui.disabled_s(ready.map(|value| !value)), Gui.style({ ..Gui.style_default, width: Fill, grow: True })], handles.model.on_str(|state, text| { ..state, query: text })),
					Gui.action_button({ label: Signal.const("Clear filter"), enabled: model.map(|state| state.phase == Idle and !state.query.is_empty()) }, [], handles.model.on_unit(|state| { ..state, query: "" })),
				],
			),
			Gui.row([Gui.style({ ..Gui.style_default, gap: 8 })], Explorer.sorts.map(|order| Gui.action_button({ label: Signal.const(order.to_str()), enabled: ready }, [Gui.selected_s(handles.order.signal().map(|current| current == order))], handles.order.on_unit(|_| order)))),
			Gui.row(
				[Gui.style({ ..Gui.style_default, gap: 16 })],
				[
					Gui.panel([Gui.test_id("dataset-summary")], [Gui.text_s(total.map(|summary| "${summary.files.to_str()} files · ${summary.folders.to_str()} folders · ${summary.links.to_str()} links · ${summary.other.to_str()} other · ${summary.bytes.to_str()} B"))]),
					Gui.panel([Gui.test_id("results-summary")], [Gui.text_s(visible.map(|entries| "${Rows.len(entries).to_str()} matching entries"))]),
				],
			),
			Gui.row(
				[Gui.style({ ..Gui.style_default, gap: 20, width: Fill, grow: True, height: Fill })],
				[
					Gui.column(
						[Gui.test_id("file-list"), Gui.style({ ..Gui.style_default, grow: True, width: Fill, height: Fill, gap: 4 })],
						[
							Ui.when(visible.map(|entries| Rows.len(entries) == 0), || Gui.text("No matching entries. Clear the filter or choose another folder."), || Gui.text("")),
							Gui.virtual_list({ row_height: 64, follow_tail: Signal.const(False) }, [Gui.test_id("file-viewport"), Gui.style({ ..Gui.style_default, height: Fill, width: Fill, grow: True })], [Ui.each(visible, |row| entry_row(row, handles, selected, ready))]),
						],
					),
					inspect_view(handles),
				],
			),
			Gui.text("Alt+Left / Right: history · Alt+Up: parent · F5: refresh · Ctrl+O: choose folder · Esc: cancel"),
		]),
	)
}

main : () -> Elem
main = || Ui.state(Session.initial, |model| Ui.state(NameAscending, |order| explorer_view({ model, order })))
