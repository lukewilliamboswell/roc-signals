app [main] { roc: "nightly-2026-09-04-c125b82", pf: platform "../../platform-gui/main.roc" }

import Explorer
import Manifest
import Session
import pf.Files
import "assets/manifest.json" as manifest_json : Str
import pf.Action exposing [Action]
import pf.Elem exposing [Elem]
import pf.Gui exposing [Px]
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
	glyph = |source, label| Elem.image({ source, label, width: 16.Px, height: 16.Px, radius: 3 })
	match kind {
		Directory => glyph("glyphs/folder.png", "Folder glyph")
		File => glyph("glyphs/file.png", "File glyph")
		_ => Elem.text("")
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

Tasks : { chooser : Signal.Task(Files.Choice, Files.Error) }

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
	Elem.row(
		{
			test_id: "entry:${key}",
			selected: Signal.select(selected, key),
			padding: 4,
			gap: 12,
			width: Fill,
			radius: 6,
		},
		[
			Elem.action_button(
				{
					caption: row.map(|entry| Explorer.file_name(entry.path)),
					enabled: ready,
					label: key,
					grow: True,
					padding: 4,
					radius: 4,
					bg: Rgb(0x1B2A33),
					overflow_x: Clip,
				},
				Action.run(row.signal(), |entry| Action.update([handles.model.write(|state| Session.activate(state, entry))])),
			),
			Elem.row(
				{
					width: 90.Px,
					padding: 4,
					gap: 6,
					font_size: 13,
					fg: Rgb(0x93A9B6),
					overflow_x: Clip,
				},
				[
					Ui.switch(row.map(|entry| entry.kind), kind_glyph),
					Elem.text_s(row.map(|entry| entry.kind.to_str())),
				],
			),
			Elem.col(
				{
					width: 90.Px,
					padding: 4,
					font_size: 13,
					fg: Rgb(0x93A9B6),
					overflow_x: Clip,
				},
				[Elem.text_s(row.map(Explorer.size_text))],
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
	Elem.panel(
		{
			test_id: "file-details",
			width: 340.Px,
			gap: 12,
			padding: 16,
			bg: Rgb(0x283A47),
			radius: 8,
		},
		[
			Elem.heading("File details"),
			Elem.text_s(
				selection.map(
					|value| match value {
						NoSelection => "Select a file to inspect it. Open a folder to browse its contents."
						Selected(entry) => entry.path
					},
				),
			),
			Elem.col(
				{ gap: 2, font_size: 13, fg: Rgb(0xA9BFCC) },
				[
					Elem.text_s(
						selection.map(
							|value| match value {
								NoSelection => ""
								Selected(entry) => "Kind: ${entry.kind.to_str()}"
							},
						),
					),
					Elem.text_s(
						selection.map(
							|value| match value {
								NoSelection => ""
								Selected(entry) => "Size: ${Explorer.size_text(entry)}"
							},
						),
					),
				],
			),
			Elem.row(
				{ gap: 8 },
				[
					Elem.action_button({
						caption: Signal.const("Preview text"),
						enabled: can_preview,
						padding: 8,
						radius: 6,
						bg: Rgb(0x2E6FA3),
					}, Action.run(Signal.const({}), |_| Action.update([handles.model.write(Session.preview_selected)]))),
					Elem.action_button({ caption: Signal.const("Open in app"), enabled: can_open }, Action.run(Signal.const({}), |_| Action.update([handles.model.write(Session.open_selected)]))),
				],
			),
			Elem.col(
				{ font_size: 13, fg: Rgb(0x93A9B6) },
				[
					Elem.text_s(
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
			Elem.col(
				{ font_size: 13, fg: Rgb(0xA9BFCC) },
				[
					Elem.text_s(
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
			Elem.textarea(
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
				handles.model.update_str(|state, _| state),
			),
		],
	)
}

cancel : Tasks, Session.Phase -> Action(a)
cancel = |tasks, phase| match phase {
	Choosing => Files.cancel(tasks.chooser)
	_ => Action.none
}

## The chooser stays a scope-owned task because it needs the window's event
## loop; every other phase runs one synchronous `Files` call in an effect
## against the phase as it is after the change committed.
workflow : Handles, Tasks -> List(Elem)
workflow = |handles, tasks| [
	Action.on_mount(|| Action.then([], |_| verify_assets!(handles.asset_problem))),
	Action.on_change(
		handles.model.read(|state| state.phase),
		|phase| match phase {
			Idle => Action.none
			Choosing => Files.choose_directory(tasks.chooser)
			_ => Action.then([], |current| advance!(handles.model, current))
		},
	),
	Action.on_change(
		Signal.from_task(tasks.chooser),
		|status| match status {
			Signal.TaskStatus.Loading => Action.none
			Signal.TaskStatus.Done(result) => Action.update([handles.model.write(|state| Session.chosen(state, result))])
			Signal.TaskStatus.Failed(error) => Action.update([handles.model.write(|state| Session.failed(state, error))])
		},
	),
]

## Runs the file operation the current phase asks for; a phase that moved on
## runs nothing.
advance! : Ui.State(Session.State), Session.Phase => Action(Session.Phase)
advance! = |model, phase| match phase {
	Listing(visit) => settle(model, Files.list_directory!(Session.path(visit.destination)), Session.loaded)
	Previewing(path) => settle(model, Files.read_preview!(path), Session.previewed)
	Opening(path) => settle(model, Files.open_path!(path), Session.opened)
	_ => Action.none
}

settle : Ui.State(Session.State), Try(a, Files.Error), (Session.State, a -> Session.State) -> Action(reads)
settle = |model, result, accept| match result {
	Ok(value) => Action.update([model.write(|state| accept(state, value))])
	Err(error) => Action.update([model.write(|state| Session.failed(state, error))])
}

verify_assets! : Ui.State(Str) => Action({})
verify_assets! = |asset_problem| match Files.verify_assets!(asset_entries) {
	Ok(report) => Action.update([asset_problem.set(asset_problem_text(report))])
	Err(error) => Action.update([asset_problem.set("Asset verification failed: ${Files.error_text(error)}")])
}

explorer_view : Handles -> Elem
explorer_view = |handles| {
	tasks = { chooser: Files.choose_directory_task("folder-choice") }
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
	choose_action = Action.run(Signal.const({}), |_| Action.update([handles.model.write(Session.begin_choose)]))
	refresh_action = Action.run(Signal.const({}), |_| Action.update([handles.model.write(Session.refresh)]))
	back_action = Action.run(Signal.const({}), |_| Action.update([handles.model.write(Session.backward)]))
	forward_action = Action.run(Signal.const({}), |_| Action.update([handles.model.write(Session.forward)]))
	up_action = Action.run(Signal.const({}), |_| Action.update([handles.model.write(Session.up)]))
	cancel_action = Action.run(phase, |value| cancel(tasks, value))
	crumbs = source.map(|location| Rows.from_list(Session.breadcrumbs(location), |crumb| crumb.path) ?? crash "Breadcrumb paths must be unique")
	Elem.col(
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
			Elem.heading("Folder Explorer"),
			Elem.col(
				{ fg: Rgb(0xA9BFCC) },
				["Browse a folder on this computer, or explore the built-in sample workspace."],
			),
			Elem.row(
				{ gap: 8 },
				[
					Elem.action_button({
						caption: Signal.const("Back"),
						enabled: model.map(|state| state.phase == Idle and !state.back.is_empty()),
					}, back_action),
					Elem.action_button({
						caption: Signal.const("Forward"),
						enabled: model.map(|state| state.phase == Idle and !state.forward.is_empty()),
					}, forward_action),
					Elem.action_button({
						caption: Signal.const("Up"),
						enabled: model.map(|state| state.phase == Idle and Session.path(state.source) != Explorer.parent_path(Session.path(state.source))),
					}, up_action),
					Elem.action_button({ caption: Signal.const("Refresh"), enabled: ready }, refresh_action),
					Elem.action_button({
						caption: Signal.const("Choose folder"),
						enabled: ready,
						padding: 8,
						radius: 6,
						bg: Rgb(0x2E6FA3),
						hover_bg: Rgb(0x3A80B8),
						active_bg: Rgb(0x265D89),
					}, choose_action),
					Elem.action_button({ caption: Signal.const("Use sample"), enabled: ready }, Action.run(Signal.const({}), |_| Action.update([handles.model.write(Session.load_sample)]))),
					# Cancel and Retry are rare-phase controls: they render only in
					# the phases where they apply instead of resting disabled.
					Ui.when(
						ready.map(|value| !value),
						|| Elem.action_button({ caption: Signal.const("Cancel"), enabled: ready.map(|value| !value) }, cancel_action),
						|| Elem.text(""),
					),
					Ui.when(
						model.map(|state| state.phase == Idle and state.retry != NoRetry),
						|| Elem.action_button({
							caption: Signal.const("Retry"),
							enabled: model.map(|state| state.phase == Idle and state.retry != NoRetry),
						}, Action.run(Signal.const({}), |_| Action.update([handles.model.write(Session.retry_last)]))),
						|| Elem.text(""),
					),
				],
			),
			Elem.row(
				{ test_id: "breadcrumbs", gap: 6, width: Fill, overflow_x: Scroll },
				[
					Ui.each(
						crumbs,
						|row| Elem.action_button(
							{
								caption: row.map(|crumb| crumb.label),
								enabled: ready,
								label: if row.key().is_empty() {
									"Go to sample root"
								} else {
									"Go to ${row.key()}"
								},
							},
							Action.run(row.signal(), |crumb| Action.update([handles.model.write(|state| Session.navigate(state, crumb.path))])),
						),
					),
				],
			),
			Elem.row(
				{ gap: 16 },
				[
					Elem.col(
						{ test_id: "dataset-source", font_size: 13, fg: Rgb(0xA9BFCC) },
						[
							Elem.text_s(
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
					Elem.col({ test_id: "operation-status", font_size: 13, fg: Rgb(0xA9BFCC) }, [Elem.text_s(model.map(|state| state.notice))]),
				],
			),
			Elem.row(
				{ gap: 8 },
				[
					Elem.text_input({
						label: "Filter this folder",
						value: model.map(|state| state.query),
						placeholder: "Filter this folder…",
						disabled: ready.map(|value| !value),
						width: 240.Px,
						gap: 4,
					}, handles.model.update_str(|state, text| { ..state, query: text })),
					Elem.action_button({
						caption: Signal.const("Clear filter"),
						enabled: model.map(|state| state.phase == Idle and !state.query.is_empty()),
					}, handles.model.update(|state| { ..state, query: "" })),
				],
			),
			Elem.row({ gap: 8 }, Explorer.sorts.map(|order| Elem.action_button({
				caption: Signal.const(order.to_str()),
				enabled: ready,
				selected: handles.order.read(|current| current == order),
			}, handles.order.update(|_| order)))),
			Elem.row(
				{ gap: 16 },
				[
					Elem.col({ test_id: "dataset-summary", font_size: 13, fg: Rgb(0x93A9B6) }, [Elem.text_s(total.map(|summary| "${summary.files.to_str()} files · ${summary.folders.to_str()} folders · ${summary.links.to_str()} links · ${summary.other.to_str()} other · ${summary.bytes.to_str()} B"))]),
					Elem.col({ test_id: "results-summary", font_size: 13, fg: Rgb(0x93A9B6) }, [Elem.text_s(visible.map(|entries| "${Rows.len(entries).to_str()} matching entries"))]),
				],
			),
			Elem.row(
				{ gap: 16, width: Fill, grow: True },
				[
					Elem.col(
						{
							test_id: "file-list",
							grow: True,
							gap: 0,
							padding: 12,
							radius: 10,
							bg: Rgb(0x1B2A33),
							overflow_y: Clip,
						},
						[
							Ui.when(
								visible.map(|entries| Rows.len(entries) == 0),
								|| Elem.col(
									{ font_size: 13, fg: Rgb(0x93A9B6) },
									["No matching entries. Clear the filter or choose another folder."],
								),
								|| Elem.text(""),
							),
							Elem.virtual_list({
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
			Elem.col(
				{ font_size: 13, fg: Rgb(0x93A9B6) },
				["Alt+Left / Right: history · Alt+Up: parent · F5: refresh · Ctrl+O: choose folder · Esc: cancel"],
			),
			# Trailing problem line: empty on healthy runs, so it pays no gap
			# rhythm between the always-visible bands above.
			Elem.col(
				{ test_id: "asset-status", font_size: 13, fg: Rgb(0xF09A93) },
				[Elem.text_s(handles.asset_problem.signal())],
			),
		]),
	)
}

main : () -> Elem
main = || Ui.state(Session.initial, |model| Ui.state(NameAscending, |order| Ui.state("", |asset_problem| explorer_view({ model, order, asset_problem }))))
