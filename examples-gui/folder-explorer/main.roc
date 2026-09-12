app [main] { roc: "nightly-2026-09-11-793f9d8", pf: platform "../../platform-gui/main.roc" }

import Explorer
import Manifest
import Session
import pf.Files
import "assets/manifest.json" as manifest_json : Str
import pf.Action exposing [Action]
import pf.Elem exposing [Elem]
import pf.Event
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
## glyph file the host cannot resolve or decode renders the host's neutral
## placeholder box instead. Nothing here consults asset verification: a glyph
## that is still a valid image renders whatever it now contains, whether or not
## its bytes match the manifest digest.
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

## The status line starts with this while the startup check is still running.
## It is never empty at mount on purpose: a status column that is laid out with
## no area keeps that area when its text arrives, so a warning written into an
## initially empty line is in the semantic tree but never visible to a person.
asset_checking : Str
asset_checking = "Checking assets…"

## Verification is advisory. It reports the integrity of the shipped files at
## startup and decides nothing about what a row draws: the host resolves and
## decodes each glyph independently, so an altered file that is still a valid
## image keeps rendering its new contents, and only a file the host cannot
## resolve or decode becomes a placeholder box. The check also runs once, so a
## file restored afterwards is reported by the next run, not by this line.
##
## An all-ok report empties the status line, collapsing it out of the layout.
asset_problem_text : List(Files.AssetCheck) -> Str
asset_problem_text = |report| {
	bad = report.keep_if(|check| check.status != Files.AssetStatus.Ok)
	if bad.is_empty() {
		""
	} else {
		names = bad.map(|check| "${check.name} (${asset_status_text(check.status)})")
		"Problem assets: ${Str.join_with(names, ", ")}. Startup check only: glyphs the host cannot load show placeholder boxes. Restart to re-check after restoring them."
	}
}

## An advisory report names every problem file and says nothing once every
## asset verifies, including on the run after a restored file is verified.
expect {
	problems = asset_problem_text([
		{ name: "glyphs/folder.png", status: Files.AssetStatus.Ok },
		{ name: "glyphs/file.png", status: Files.AssetStatus.Mismatch },
	])
	restored = asset_problem_text([
		{ name: "glyphs/folder.png", status: Files.AssetStatus.Ok },
		{ name: "glyphs/file.png", status: Files.AssetStatus.Ok },
	])
	{ problems, restored } == {
		problems: "Problem assets: glyphs/file.png (altered). Startup check only: glyphs the host cannot load show placeholder boxes. Restart to re-check after restoring them.",
		restored: "",
	}
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
				Action.run(
					{ entry: row.signal(), state: handles.model.signal() }.Signal,
					|reads| Action.then([handles.model.write(|state| Session.activate(state, reads.entry))], |current| advance!(handles.model, |snapshot| snapshot.state, current)),
				),
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
			# The inspector shares the height left by the header and footer bands;
			# it bounds itself to the row's height and scrolls a long path or error.
			test_id: "file-details",
			width: Fill,
			height: Fill,
			gap: 12,
			padding: 16,
			bg: Rgb(0x283A47),
			radius: 8,
			overflow_y: Scroll,
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
					}, step(handles, Session.preview_selected)),
					Elem.action_button({ caption: Signal.const("Open in app"), enabled: can_open }, step(handles, Session.open_selected)),
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
					read_only: Signal.const(True),
					width: Fill,
					height: 220.Px,
				},
				handles.model.update_str(|state, _| state),
			),
		],
	)
}

workflow : Handles -> List(Elem)
workflow = |handles| [
	Action.on_mount(|| Action.then([], |_| verify_assets!(handles.asset_problem))),
]

## A handler that commits one session transition and then runs whatever
## operation the state it reached asks for.
step : Handles, (Session.State -> Session.State) -> Event.Handler
step = |handles, change| Action.run(handles.model.signal(), |_| Action.then([handles.model.write(change)], |current| advance!(handles.model, |state| state, current)))

## Runs the `Files` call the session's phase asks for, as the effect of the
## handler that entered it. The folder chooser blocks until the user answers,
## and the folder it names is listed by a second effect after the choice
## commits. `state_of` finds the session in the handler's reads, which each
## commit snapshots again.
advance! : Ui.State(Session.State), (reads -> Session.State), reads => Action(reads)
advance! = |model, state_of, reads| match state_of(reads).phase {
	Idle => Action.none
	Choosing => match Files.choose_directory!() {
		Ok(choice) => Action.then([model.write(|state| Session.chosen(state, choice))], |next| advance!(model, state_of, next))
		Err(error) => Action.update([model.write(|state| Session.failed(state, error))])
	}
	Listing(visit) => settle(model, Files.list_directory!(Session.path(visit.destination)), Session.loaded)
	Previewing(path) => settle(model, Files.read_preview!(path), Session.previewed)
	Opening(path) => settle(model, Files.open_path!(path), |state, _| Session.opened(state, path))
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
	choose_action = step(handles, Session.begin_choose)
	refresh_action = step(handles, Session.refresh)
	back_action = step(handles, Session.backward)
	forward_action = step(handles, Session.forward)
	up_action = step(handles, Session.up)
	crumbs = source.map(|location| Rows.from_list(Session.breadcrumbs(location), |crumb| crumb.path) ?? crash "Breadcrumb paths must be unique")
	Elem.col(
		{
			# The root bounds itself to the window and hands the free height to
			# the content row; every band of chrome above the list is height the
			# preview does not get.
			test_id: "explorer",
			gap: 12,
			padding: 24,
			width: Fill,
			height: Fill,
			shortcuts: [{ chord: { key: "o", control: True, shift: False, alt: False, meta: False }, msg: choose_action }, { chord: { key: "F5", control: False, shift: False, alt: False, meta: False }, msg: refresh_action }, { chord: { key: "ArrowLeft", control: False, shift: False, alt: True, meta: False }, msg: back_action }, { chord: { key: "ArrowRight", control: False, shift: False, alt: True, meta: False }, msg: forward_action }, { chord: { key: "ArrowUp", control: False, shift: False, alt: True, meta: False }, msg: up_action }],
		},
		workflow(handles).concat([
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
					Elem.action_button({ caption: Signal.const("Use sample"), enabled: ready }, step(handles, Session.load_sample)),
					# Retry is a rare-phase control: it renders only in the phase
					# where it applies instead of resting disabled.
					Ui.when(
						model.map(|state| state.phase == Idle and state.retry != NoRetry),
						|| Elem.action_button({
							caption: Signal.const("Retry"),
							enabled: model.map(|state| state.phase == Idle and state.retry != NoRetry),
						}, step(handles, Session.retry_last)),
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
							Action.run(
								{ crumb: row.signal(), state: handles.model.signal() }.Signal,
								|reads| Action.then([handles.model.write(|state| Session.navigate(state, reads.crumb.path))], |current| advance!(handles.model, |snapshot| snapshot.state, current)),
							),
						),
					),
				],
			),
			Elem.row(
				{ gap: 16 },
				[
					Elem.col(
						{ test_id: "dataset-source", font_size: 13, fg: Rgb(0xA9BFCC), overflow_x: Clip },
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
					Elem.col({ test_id: "operation-status", font_size: 13, fg: Rgb(0xA9BFCC), overflow_x: Clip }, [Elem.text_s(model.map(|state| state.notice))]),
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
					Elem.col({ test_id: "dataset-summary", font_size: 13, fg: Rgb(0x93A9B6), overflow_x: Clip }, [Elem.text_s(total.map(|summary| "${summary.files.to_str()} files · ${summary.folders.to_str()} folders · ${summary.links.to_str()} links · ${summary.other.to_str()} other · ${summary.bytes.to_str()} B"))]),
					Elem.col({ test_id: "results-summary", font_size: 13, fg: Rgb(0x93A9B6), overflow_x: Clip }, [Elem.text_s(visible.map(|entries| "${Rows.len(entries).to_str()} matching entries"))]),
				],
			),
			Elem.row(
				# The content row takes the free height and clips: the list's
				# viewport and the inspector each own their own scrolling.
				{ gap: 16, width: Fill, height: Fill, grow: True, overflow_x: Clip, overflow_y: Clip },
				[
					Elem.col(
						{
							test_id: "file-list",
							width: Fill,
							height: Fill,
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
				{ test_id: "shortcut-hints", font_size: 13, fg: Rgb(0x93A9B6) },
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
main = || Ui.state(Session.initial, |model| Ui.state(NameAscending, |order| Ui.state(asset_checking, |asset_problem| explorer_view({ model, order, asset_problem }))))
