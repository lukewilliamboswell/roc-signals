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
	glyph = |source, label| Gui.image({ source, label }, [Gui.style({ ..Gui.style_default, width: Px(16), height: Px(16), radius: 3 })])
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
		[
			Gui.test_id("entry:${key}"),
			Gui.selected_s(Signal.select(selected, key)),
			Gui.style({ ..Gui.style_default, padding: 4, gap: 12, width: Fill, radius: 6 }),
		],
		[
			Gui.action_button(
				{ label: row.map(|entry| Explorer.file_name(entry.path)), enabled: ready },
				[Gui.label(key), Gui.style({ ..Gui.style_default, grow: True, padding: 4, radius: 4, background: Rgb(0x1B2A33), overflow_x: Clip })],
				Ui.action(row.signal(), |entry| handles.model.update_cmd(|state| Session.activate(state, entry))),
			),
			Gui.row(
				[Gui.style({ ..Gui.style_default, width: Px(90), padding: 4, gap: 6, font_size: 13, foreground: Rgb(0x93A9B6), overflow_x: Clip })],
				[
					Ui.switch(row.map(|entry| entry.kind), kind_glyph),
					Gui.text_s(row.map(|entry| entry.kind.to_str())),
				],
			),
			Gui.column(
				[Gui.style({ ..Gui.style_default, width: Px(90), padding: 4, font_size: 13, foreground: Rgb(0x93A9B6), overflow_x: Clip })],
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
		# The inspector shares the content row's width with the list rather than
		# claiming a fixed 340 pixels: at the declared 360-pixel minimum a fixed
		# panel is laid out past the right edge, where nothing can reach it. It
		# bounds itself to the row's height and scrolls a long path or error.
		[Gui.test_id("file-details"), Gui.style({ ..Gui.style_default, width: Fill, height: Fill, gap: 12, padding: 16, background: Rgb(0x283A47), radius: 8, overflow_y: Scroll })],
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
				[Gui.style({ ..Gui.style_default, gap: 2, font_size: 13, foreground: Rgb(0xA9BFCC) })],
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
				[Gui.style({ ..Gui.style_default, gap: 8 })],
				[
					Gui.action_button({ label: Signal.const("Preview text"), enabled: can_preview }, [Gui.style({ ..Gui.style_default, padding: 8, radius: 6, background: Rgb(0x2E6FA3) })], Ui.action(Signal.const({}), |_| handles.model.update_cmd(Session.preview_selected))),
					Gui.action_button({ label: Signal.const("Open in app"), enabled: can_open }, [], Ui.action(Signal.const({}), |_| handles.model.update_cmd(Session.open_selected))),
				],
			),
			Gui.column(
				[Gui.style({ ..Gui.style_default, font_size: 13, foreground: Rgb(0x93A9B6) })],
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
				[Gui.style({ ..Gui.style_default, font_size: 13, foreground: Rgb(0xA9BFCC) })],
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
				},
				# The preview is a document to read, not an unavailable control: it
				# stays legible and keyboard reachable, and read-only refuses every
				# edit so the shown text cannot diverge from the loaded preview.
				[Gui.test_id("text-preview"), Gui.placeholder("Preview a file to read it here."), Gui.read_only_s(Signal.const(True)), Gui.style({ ..Gui.style_default, width: Fill, height: Px(220) })],
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
		[
			Gui.test_id("explorer"),
			# The root bounds itself to the window and hands the free height to
			# the content row, so the chrome bands below it stay on screen.
			Gui.style({ ..Gui.style_default, gap: 12, padding: 24, width: Fill, height: Fill }),
			Gui.on_shortcut({ key: "o", control: True, shift: False, alt: False, meta: False }, choose_action),
			Gui.on_shortcut({ key: "F5", control: False, shift: False, alt: False, meta: False }, refresh_action),
			Gui.on_shortcut({ key: "Escape", control: False, shift: False, alt: False, meta: False }, cancel_action),
			Gui.on_shortcut({ key: "ArrowLeft", control: False, shift: False, alt: True, meta: False }, back_action),
			Gui.on_shortcut({ key: "ArrowRight", control: False, shift: False, alt: True, meta: False }, forward_action),
			Gui.on_shortcut({ key: "ArrowUp", control: False, shift: False, alt: True, meta: False }, up_action),
		],
		workflow(handles, tasks).concat([
			# The browsed folder is this window's document, so the switcher names it.
			Ui.on_change_initial(
				source.map(
					|value| {
						location = Session.path(value)
						place = if location.is_empty() { "Sample workspace" } else { location }
						"${place} - Folder Explorer"
					},
				),
				Gui.set_title,
			),
			# Heading and standing invitation share one band: at 800x600 every
			# line of chrome above the list is height the preview does not get.
			Gui.row(
				[Gui.style({ ..Gui.style_default, gap: 16, width: Fill, overflow_x: Clip })],
				[
					Gui.heading("Folder Explorer"),
					Gui.column(
						[Gui.style({ ..Gui.style_default, grow: True, font_size: 13, foreground: Rgb(0xA9BFCC), overflow_x: Clip })],
						[Gui.text("Browse a folder on this computer, or explore the built-in sample workspace.")],
					),
				],
			),
			Gui.row(
				[Gui.style({ ..Gui.style_default, gap: 8 })],
				[
					Gui.action_button({ label: Signal.const("Back"), enabled: model.map(|state| state.phase == Idle and !state.back.is_empty()) }, [], back_action),
					Gui.action_button({ label: Signal.const("Forward"), enabled: model.map(|state| state.phase == Idle and !state.forward.is_empty()) }, [], forward_action),
					Gui.action_button({ label: Signal.const("Up"), enabled: model.map(|state| state.phase == Idle and Session.path(state.source) != Explorer.parent_path(Session.path(state.source))) }, [], up_action),
					Gui.action_button({ label: Signal.const("Refresh"), enabled: ready }, [], refresh_action),
					Gui.action_button({ label: Signal.const("Choose folder"), enabled: ready }, [Gui.style({ ..Gui.style_default, padding: 8, radius: 6, background: Rgb(0x2E6FA3), hover_background: Rgb(0x3A80B8), active_background: Rgb(0x265D89) })], choose_action),
					Gui.action_button({ label: Signal.const("Use sample"), enabled: ready }, [], Ui.action(Signal.const({}), |_| handles.model.update_cmd(Session.load_sample))),
					# Cancel and Retry are rare-phase controls: they render only in
					# the phases where they apply instead of resting disabled.
					Ui.when(
						ready.map(|value| !value),
						|| Gui.action_button({ label: Signal.const("Cancel"), enabled: ready.map(|value| !value) }, [], cancel_action),
						|| Gui.text(""),
					),
					Ui.when(
						model.map(|state| state.phase == Idle and state.retry != NoRetry),
						|| Gui.action_button({ label: Signal.const("Retry"), enabled: model.map(|state| state.phase == Idle and state.retry != NoRetry) }, [], Ui.action(Signal.const({}), |_| handles.model.update_cmd(Session.retry_last))),
						|| Gui.text(""),
					),
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
			# One status band: where the listing came from, what the last
			# operation did, and what the folder and the filter contain.
			Gui.row(
				[Gui.style({ ..Gui.style_default, gap: 16, width: Fill, overflow_x: Clip })],
				[
					Gui.column(
						[Gui.test_id("dataset-source"), Gui.style({ ..Gui.style_default, font_size: 13, foreground: Rgb(0xA9BFCC), overflow_x: Clip })],
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
					Gui.column([Gui.test_id("operation-status"), Gui.style({ ..Gui.style_default, font_size: 13, foreground: Rgb(0xA9BFCC), overflow_x: Clip })], [Gui.text_s(model.map(|state| state.notice))]),
					Gui.column([Gui.test_id("dataset-summary"), Gui.style({ ..Gui.style_default, font_size: 13, foreground: Rgb(0x93A9B6), overflow_x: Clip })], [Gui.text_s(total.map(|summary| "${summary.files.to_str()} files · ${summary.folders.to_str()} folders · ${summary.links.to_str()} links · ${summary.other.to_str()} other · ${summary.bytes.to_str()} B"))]),
					Gui.column([Gui.test_id("results-summary"), Gui.style({ ..Gui.style_default, font_size: 13, foreground: Rgb(0x93A9B6), overflow_x: Clip })], [Gui.text_s(visible.map(|entries| "${Rows.len(entries).to_str()} matching entries"))]),
				],
			),
			# Filtering and ordering are the same decision about what the list
			# shows, so they share one band instead of two.
			Gui.row(
				[Gui.style({ ..Gui.style_default, gap: 8, width: Fill, overflow_x: Clip })],
				[
					Gui.text_input({ label: "Filter this folder", value: model.map(|state| state.query) }, [Gui.placeholder("Filter this folder…"), Gui.disabled_s(ready.map(|value| !value)), Gui.style({ ..Gui.style_default, width: Px(240), gap: 4 })], handles.model.on_str(|state, text| { ..state, query: text })),
					Gui.action_button({ label: Signal.const("Clear filter"), enabled: model.map(|state| state.phase == Idle and !state.query.is_empty()) }, [], handles.model.on_unit(|state| { ..state, query: "" })),
				].concat(Explorer.sorts.map(|order| Gui.action_button({ label: Signal.const(order.to_str()), enabled: ready }, [Gui.selected_s(handles.order.signal().map(|current| current == order))], handles.order.on_unit(|_| order)))),
			),
			# The content row takes the height the bands above and below leave.
			# Each side then scrolls its own overflow rather than growing.
			Gui.row(
				[Gui.style({ ..Gui.style_default, gap: 16, width: Fill, height: Fill, grow: True, overflow_x: Clip, overflow_y: Clip })],
				[
					Gui.column(
						# The list clips; its virtual viewport owns the scrolling, so a
					# second scroller here would nest two independent offsets.
					[Gui.test_id("file-list"), Gui.style({ ..Gui.style_default, width: Fill, height: Fill, gap: 0, padding: 12, radius: 10, background: Rgb(0x1B2A33), overflow_y: Clip })],
						[
							Ui.when(
								visible.map(|entries| Rows.len(entries) == 0),
								|| Gui.column(
									[Gui.style({ ..Gui.style_default, font_size: 13, foreground: Rgb(0x93A9B6) })],
									[Gui.text("No matching entries. Clear the filter or choose another folder.")],
								),
								|| Gui.text(""),
							),
							Gui.virtual_list({ row_height: 44, follow_tail: Signal.const(False) }, [Gui.test_id("file-viewport"), Gui.style({ ..Gui.style_default, height: Fill, width: Fill, grow: True })], [Ui.each(visible, |row| entry_row(row, handles, selected, ready))]),
						],
					),
					inspect_view(handles),
				],
			),
			# One footer band. The trailing problem line is empty on healthy
			# runs, so it pays no gap rhythm above the shortcut hint.
			Gui.column(
				[Gui.style({ ..Gui.style_default, gap: 2, width: Fill, overflow_x: Clip })],
				[
					Gui.column(
						[Gui.test_id("shortcut-hints"), Gui.style({ ..Gui.style_default, font_size: 13, foreground: Rgb(0x93A9B6) })],
						[Gui.text("Alt+Left / Right: history · Alt+Up: parent · F5: refresh · Ctrl+O: choose folder · Esc: cancel")],
					),
					Gui.column(
						[Gui.test_id("asset-status"), Gui.style({ ..Gui.style_default, font_size: 13, foreground: Rgb(0xF09A93) })],
						[Gui.text_s(handles.asset_problem.signal())],
					),
				],
			),
		]),
	)
}

main : () -> Elem
main = || Ui.state(Session.initial, |model| Ui.state(NameAscending, |order| Ui.state("", |asset_problem| explorer_view({ model, order, asset_problem }))))
