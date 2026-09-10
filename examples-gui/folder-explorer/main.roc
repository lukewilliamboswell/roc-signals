app [main] { roc: "nightly-2026-09-04-c125b82", pf: platform "../../platform-gui/main.roc" }

import Explorer
import Manifest
import Session
import pf.Files
import "assets/manifest.json" as manifest_json : Str
import pf.Elem exposing [Elem]
import pf.Gui
import pf.Rows
import pf.Signal
import pf.Ui

Handles : { model : Ui.State(Session.State), order : Ui.State(Explorer.Sort), asset_problem : Ui.State(Str) }

## Parsing the ingested manifest at the top level runs at compile time, so a
## malformed assets/manifest.json fails the build instead of the running app.
asset_entries : List(Files.AssetEntry)
asset_entries = Manifest.entries(manifest_json)

## Folder and file rows show a small generated glyph beside their kind text; a
## missing glyph file renders the host's neutral placeholder box instead.
kind_glyph : Explorer.Kind -> Elem
kind_glyph = |kind| {
	glyph = |source, label| Gui.image({ source, label, width: Px(16), height: Px(16), radius: 3 })
	match kind {
		Directory => glyph("glyphs/folder.png", "Folder glyph")
		File => glyph("glyphs/file.png", "File glyph")
		_ => Gui.text("")
	}
}

asset_status_text : Files.AssetStatus -> Str
asset_status_text = |status| match status {
	Files.AssetStatus.Ok => "ok"
	Files.AssetStatus.Missing => "missing"
	Files.AssetStatus.Mismatch => "altered"
}

## All-ok verification reports render as an empty (invisible) status line.
asset_problem_text : List(Files.AssetCheck) -> Str
asset_problem_text = |report| {
	bad = report.keep_if(|check| check.status != Files.AssetStatus.Ok)
	if bad.is_empty() {
		""
	} else {
		names = bad.map(|check| "${check.name} (${asset_status_text(check.status)})")
		"Problem assets: ${Str.join_with(names, ", ")}. Rows show placeholder boxes until the assets are restored."
	}
}

Tasks : {
	chooser : Signal.Task(Files.Choice, Files.Error),
	listing : Signal.Task(Files.Directory, Files.Error),
	preview : Signal.Task(Files.Preview, Files.Error),
	open : Signal.Task(Files.Opened, Files.Error),
	verify : Signal.Task(List(Files.AssetCheck), Files.Error),
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
		{
			test_id: "entry:${key}",
			selected: Signal.select(selected, key),
			padding: 4,
			gap: 12,
			width: Fill,
			radius: 6,
		},
		[
			Gui.action_button(
				{
					caption: row.map(|entry| Explorer.file_name(entry.path)),
					enabled: ready,
					label: key,
					grow: True,
					padding: 4,
					radius: 4,
					background: Rgb(0x1B2A33),
					overflow_x: Clip,
				},
				Ui.action(row.signal(), |entry| handles.model.update_cmd(|state| Session.activate(state, entry))),
			),
			Gui.row(
				{
					width: Px(90),
					padding: 4,
					gap: 6,
					font_size: 13,
					foreground: Rgb(0x93A9B6),
					overflow_x: Clip,
				},
				[
					Ui.switch(row.map(|entry| entry.kind), kind_glyph),
					Gui.text_s(row.map(|entry| entry.kind.to_str())),
				],
			),
			Gui.column(
				{
					width: Px(90),
					padding: 4,
					font_size: 13,
					foreground: Rgb(0x93A9B6),
					overflow_x: Clip,
				},
				[Gui.text_s(row.map(Explorer.size_text))],
			),
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
		{
			test_id: "file-details",
			width: Px(340),
			gap: 12,
			padding: 16,
			background: Rgb(0x283A47),
			radius: 8,
		},
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
			Gui.column(
				{ gap: 2, font_size: 13, foreground: Rgb(0xA9BFCC) },
				[
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
			),
			Gui.row(
				{ gap: 8 },
				[
					Gui.action_button({
						caption: Signal.const("Preview text"),
						enabled: can_preview,
						padding: 8,
						radius: 6,
						background: Rgb(0x2E6FA3),
					}, Ui.action(Signal.const({}), |_| handles.model.update_cmd(Session.preview_selected))),
					Gui.action_button({ caption: Signal.const("Open in app"), enabled: can_open }, Ui.action(Signal.const({}), |_| handles.model.update_cmd(Session.open_selected))),
				],
			),
			Gui.column(
				{ font_size: 13, foreground: Rgb(0x93A9B6) },
				[
					Gui.text_s(
						selection.map(
							|value| match value {
								Selected(entry) if entry.kind == SymbolicLink => "Symbolic links are shown but are not followed."
								Selected(entry) if entry.kind == Other => "Special files are shown as metadata only."
								_ => "Text previews are limited to 64 KiB. Open in app uses this computer's file associations."
							},
						),
					),
				],
			),
			Gui.column(
				{ font_size: 13, foreground: Rgb(0xA9BFCC) },
				[
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
				],
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
					test_id: "text-preview",
					placeholder: "Preview a file to read it here.",
					disabled: Signal.const(True),
					width: Fill,
					height: Fill,
					grow: True,
				},
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
	Ui.on_mount(|| Files.verify_assets(tasks.verify, asset_entries)),
	Ui.on_change(
		Signal.from_task(tasks.verify),
		|status| match status {
			Signal.TaskStatus.Loading => Signal.noop
			Signal.TaskStatus.Failed(error) => handles.asset_problem.set_cmd("Asset verification failed: ${Files.error_text(error)}")
			Signal.TaskStatus.Done(report) => handles.asset_problem.set_cmd(asset_problem_text(report))
		},
	),
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
	tasks = { chooser: Files.choose_directory_task("folder-choice"), listing: Files.list_directory_task("folder-list"), preview: Files.read_preview_task("file-preview"), open: Files.open_path_task("file-open"), verify: Files.verify_assets_task("asset-verify") }
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
		{
			test_id: "explorer",
			gap: 12,
			padding: 24,
			width: Fill,
			height: Fill,
			overflow_y: Clip,
			shortcuts: [{ chord: { key: "o", control: True, shift: False, alt: False, meta: False }, msg: choose_action }, { chord: { key: "F5", control: False, shift: False, alt: False, meta: False }, msg: refresh_action }, { chord: { key: "Escape", control: False, shift: False, alt: False, meta: False }, msg: cancel_action }, { chord: { key: "ArrowLeft", control: False, shift: False, alt: True, meta: False }, msg: back_action }, { chord: { key: "ArrowRight", control: False, shift: False, alt: True, meta: False }, msg: forward_action }, { chord: { key: "ArrowUp", control: False, shift: False, alt: True, meta: False }, msg: up_action }],
		},
		workflow(handles, tasks).concat([
			Gui.heading("Folder Explorer"),
			Gui.column(
				{ foreground: Rgb(0xA9BFCC) },
				["Browse a folder on this computer, or explore the built-in sample workspace."],
			),
			Gui.row(
				{ gap: 8 },
				[
					Gui.action_button({
						caption: Signal.const("Back"),
						enabled: model.map(|state| state.phase == Idle and !state.back.is_empty()),
					}, back_action),
					Gui.action_button({
						caption: Signal.const("Forward"),
						enabled: model.map(|state| state.phase == Idle and !state.forward.is_empty()),
					}, forward_action),
					Gui.action_button({
						caption: Signal.const("Up"),
						enabled: model.map(|state| state.phase == Idle and Session.path(state.source) != Explorer.parent_path(Session.path(state.source))),
					}, up_action),
					Gui.action_button({ caption: Signal.const("Refresh"), enabled: ready }, refresh_action),
					Gui.action_button({
						caption: Signal.const("Choose folder"),
						enabled: ready,
						padding: 8,
						radius: 6,
						background: Rgb(0x2E6FA3),
						hover_background: Rgb(0x3A80B8),
						active_background: Rgb(0x265D89),
					}, choose_action),
					Gui.action_button({ caption: Signal.const("Use sample"), enabled: ready }, Ui.action(Signal.const({}), |_| handles.model.update_cmd(Session.load_sample))),
					# Cancel and Retry are rare-phase controls: they render only in
					# the phases where they apply instead of resting disabled.
					Ui.when(
						ready.map(|value| !value),
						|| Gui.action_button({ caption: Signal.const("Cancel"), enabled: ready.map(|value| !value) }, cancel_action),
						|| Gui.text(""),
					),
					Ui.when(
						model.map(|state| state.phase == Idle and state.retry != NoRetry),
						|| Gui.action_button({
							caption: Signal.const("Retry"),
							enabled: model.map(|state| state.phase == Idle and state.retry != NoRetry),
						}, Ui.action(Signal.const({}), |_| handles.model.update_cmd(Session.retry_last))),
						|| Gui.text(""),
					),
				],
			),
			Gui.row(
				{ test_id: "breadcrumbs", gap: 6, width: Fill, overflow_x: Scroll },
				[
					Ui.each(
						crumbs,
						|row| Gui.action_button(
							{
								caption: row.map(|crumb| crumb.label),
								enabled: ready,
								label: if row.key().is_empty() {
									"Go to sample root"
								} else {
									"Go to ${row.key()}"
								},
							},
							Ui.action(row.signal(), |crumb| handles.model.update_cmd(|state| Session.navigate(state, crumb.path))),
						),
					),
				],
			),
			Gui.row(
				{ gap: 16 },
				[
					Gui.column(
						{ test_id: "dataset-source", font_size: 13, foreground: Rgb(0xA9BFCC) },
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
					Gui.column({ test_id: "operation-status", font_size: 13, foreground: Rgb(0xA9BFCC) }, [Gui.text_s(model.map(|state| state.notice))]),
				],
			),
			Gui.row(
				{ gap: 8 },
				[
					Gui.text_input({
						label: "Filter this folder",
						value: model.map(|state| state.query),
						placeholder: "Filter this folder…",
						disabled: ready.map(|value| !value),
						width: Px(240),
						gap: 4,
					}, handles.model.on_str(|state, text| { ..state, query: text })),
					Gui.action_button({
						caption: Signal.const("Clear filter"),
						enabled: model.map(|state| state.phase == Idle and !state.query.is_empty()),
					}, handles.model.on_unit(|state| { ..state, query: "" })),
				],
			),
			Gui.row({ gap: 8 }, Explorer.sorts.map(|order| Gui.action_button({
				caption: Signal.const(order.to_str()),
				enabled: ready,
				selected: handles.order.signal().map(|current| current == order),
			}, handles.order.on_unit(|_| order)))),
			Gui.row(
				{ gap: 16 },
				[
					Gui.column({ test_id: "dataset-summary", font_size: 13, foreground: Rgb(0x93A9B6) }, [Gui.text_s(total.map(|summary| "${summary.files.to_str()} files · ${summary.folders.to_str()} folders · ${summary.links.to_str()} links · ${summary.other.to_str()} other · ${summary.bytes.to_str()} B"))]),
					Gui.column({ test_id: "results-summary", font_size: 13, foreground: Rgb(0x93A9B6) }, [Gui.text_s(visible.map(|entries| "${Rows.len(entries).to_str()} matching entries"))]),
				],
			),
			Gui.row(
				{ gap: 16, width: Fill, grow: True },
				[
					Gui.column(
						{
							test_id: "file-list",
							grow: True,
							gap: 0,
							padding: 12,
							radius: 10,
							background: Rgb(0x1B2A33),
							overflow_y: Clip,
						},
						[
							Ui.when(
								visible.map(|entries| Rows.len(entries) == 0),
								|| Gui.column(
									{ font_size: 13, foreground: Rgb(0x93A9B6) },
									["No matching entries. Clear the filter or choose another folder."],
								),
								|| Gui.text(""),
							),
							Gui.virtual_list({
								row_height: 44,
								follow_tail: Signal.const(False),
								test_id: "file-viewport",
								height: Fill,
								width: Fill,
								grow: True,
							}, [Ui.each(visible, |row| entry_row(row, handles, selected, ready))]),
						],
					),
					inspect_view(handles),
				],
			),
			Gui.column(
				{ font_size: 13, foreground: Rgb(0x93A9B6) },
				["Alt+Left / Right: history · Alt+Up: parent · F5: refresh · Ctrl+O: choose folder · Esc: cancel"],
			),
			# Trailing problem line: empty on healthy runs, so it pays no gap
			# rhythm between the always-visible bands above.
			Gui.column(
				{ test_id: "asset-status", font_size: 13, foreground: Rgb(0xF09A93) },
				[Gui.text_s(handles.asset_problem.signal())],
			),
		]),
	)
}

main : () -> Elem
main = || Ui.state(Session.initial, |model| Ui.state(NameAscending, |order| Ui.state("", |asset_problem| explorer_view({ model, order, asset_problem }))))
