app [main] { roc: "nightly-2026-09-04-c125b82", pf: platform "../../platform-gui/main.roc" }

import Board
import Codec
import Manifest
import pf.Files
import "assets/manifest.json" as manifest_json : Str
import pf.Elem exposing [Elem]
import pf.Gui
import pf.Rows
import pf.Signal
import pf.Ui

## Parsing the ingested manifest at the top level runs at compile time, so a
## malformed assets/manifest.json fails the build instead of the running app.
asset_entries : List(Files.AssetEntry)
asset_entries = Manifest.entries(manifest_json)

## A missing avatar file renders the host's neutral placeholder box; an
## assignee without a generated avatar simply shows no picture.
avatar : Str, U32 -> Elem
avatar = |assignee, size| match Board.avatar_source(assignee) {
	Some(source) => Gui.image({ source, label: "${assignee} avatar" }, [Gui.style({ ..Gui.style_default, width: Px(size), height: Px(size), radius: size })])
	None => Gui.text("")
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
		"Problem assets: ${Str.join_with(names, ", ")}. Cards show placeholder boxes until the assets are restored."
	}
}

## The detail panel owns its current editing value independently of card scopes.
## Each edit writes this value and its column row atomically, so filtering a
## card away or moving it between columns cannot discard an unfinished edit.
Editor : { column : Board.Column, task : Board.Task }

TextField : { label : Str, value : Signal.Signal(Str) }, List(Gui.Attr), Gui.Msg -> Elem

BoardSnapshot : {
	planned : Rows.Rows(Board.Task),
	progress : Rows.Rows(Board.Task),
	complete : Rows.Rows(Board.Task),
	editor : Editor,
	editing : Bool,
	bytes : U64,
}

History : { past : List(BoardSnapshot), future : List(BoardSnapshot) }

Save : { text : Str, snapshot : BoardSnapshot }

Phase := [Idle, ConfirmOpen, ChoosingOpen, Reading(Str), ChoosingSave(Save), Writing({ path : Str, save : Save })].{
	is_eq : _
}

Close := [KeepEditing, Confirm, Saving, Closing].{
	is_eq : _
}

DocumentState : { path : [None, Some(Str)], baseline : [None, Some(BoardSnapshot)], phase : Phase, problem : Str }

Tasks : { open : Signal.Task(Files.Choice, Files.Error), save : Signal.Task(Files.Choice, Files.Error), read : Signal.Task(Files.TextFile, Files.Error), write : Signal.Task(Files.Written, Files.Error), verify : Signal.Task(List(Files.AssetCheck), Files.Error) }

Context : { board : BoardSnapshot, history : History, document : DocumentState }

Handles : {
	planned : Ui.State(Rows.Rows(Board.Task)),
	progress : Ui.State(Rows.Rows(Board.Task)),
	complete : Ui.State(Rows.Rows(Board.Task)),
	editor : Ui.State(Editor),
	editing : Ui.State(Bool),
	filter : Ui.State(Str),
	draft : Ui.State(Str),
	next_id : Ui.State(U64),
	confirm_delete : Ui.State(Bool),
	movement : Signal.Signal(BoardSnapshot),
	context : Signal.Signal(Context),
	history : Ui.State(History),
	bytes : Ui.State(U64),
	document : Ui.State(DocumentState),
	asset_problem : Ui.State(Str),
	tasks : Tasks,
	close : Ui.State(Close),
	editable : Signal.Signal(Bool),
	edit_disabled : Signal.Signal(Bool),
}

initial_rows : Board.Column -> Rows.Rows(Board.Task)
initial_rows = |column| Rows.from_list(Board.seed(column), |task| task.key) ?? crash "Seed task keys must be unique"

column_state : Handles, Board.Column -> Ui.State(Rows.Rows(Board.Task))
column_state = |handles, column|
	match column {
		Planned => handles.planned
		InProgress => handles.progress
		Complete => handles.complete
	}

column_rows : BoardSnapshot, Board.Column -> Rows.Rows(Board.Task)
column_rows = |snapshot, column|
	match column {
		Planned => snapshot.planned
		InProgress => snapshot.progress
		Complete => snapshot.complete
	}

find_task : BoardSnapshot, Str -> Try(Editor, [MissingTask])
find_task = |snapshot, key|
	match Rows.get_key(snapshot.planned, key) {
		Ok(task) => Ok({ column: Planned, task })
		Err(_) =>
			match Rows.get_key(snapshot.progress, key) {
				Ok(task) => Ok({ column: InProgress, task })
				Err(_) =>
					match Rows.get_key(snapshot.complete, key) {
						Ok(task) => Ok({ column: Complete, task })
						Err(_) => Err(MissingTask)
					}
				}
		}

## Pointer drops and explicit controls share the same domain move. The native
## host authenticates the drag lifetime; the reducer resolves current task data
## by its key and preserves the independently owned detail editor.
move_task : Handles, Context, Str, Board.Column, Rows.Before -> Gui.Cmd
move_task = |handles, context, key, destination_column, before| {
	current = context.board
	match find_task(current, key) {
		Err(_) => Ui.update_states([])
		Ok(found) => {
			source = column_state(handles, found.column)
			destination = column_state(handles, destination_column)
			drop_on_self = match before {
				End => False
				Key(target) => target == key
			}
			if drop_on_self and found.column == destination_column {
				Ui.update_states([])
			} else if found.column == destination_column {
				next = Rows.apply(column_rows(current, found.column), [MoveKeyBefore({ key, before })]) ?? crash "The target card must belong to its column"
				if next == column_rows(current, found.column) {
					Signal.noop
				} else {
					remember(handles, context, [source.write(next)])
				}
			} else {
				remaining = Rows.apply(column_rows(current, found.column), [RemoveKey(key)]) ?? crash "The moved task must exist"
				insertion = match before {
					End => Append([found.task])
					Key(target) => InsertBefore({ before: target, items: [found.task] })
				}
				moved = Rows.apply(column_rows(current, destination_column), [insertion]) ?? crash "Task keys must be unique across columns"
				writes = [source.write(remaining), destination.write(moved)]
				if current.editor.task.key == key {
					remember(handles, context, writes.append(handles.editor.write({ column: destination_column, task: found.task })))
				} else {
					remember(handles, context, writes)
				}
			}
		}
	}
}

drop_message : Handles, Board.Column, Rows.Before -> Gui.Msg
drop_message = |handles, column, before|
	Ui.action_detail(handles.context, |current, key| move_task(handles, current, key, column, before))

## The unfiltered view forwards its Rows generation unchanged, preserving sparse
## updates. An active text search explicitly examines that column's tasks.
visible_rows : Rows.Rows(Board.Task), Str -> Rows.Rows(Board.Task)
visible_rows = |rows, query|
	if query.trim().is_empty() {
		rows
	} else {
		Rows.replace_all(rows, Rows.to_list(rows).keep_if(|task| Board.matches(task, query))) ?? crash "Filtering cannot introduce duplicate task keys"
	}

task_card : Ui.Row(Board.Task), Board.Column, Handles, Signal.Signal(Str) -> Elem
task_card = |row, column, handles, selected| {
	key = row.key()
	Ui.component(
		|| Gui.panel(
			[
				Gui.test_id(key),
				Gui.drag_source(key),
				Gui.disabled_s(handles.edit_disabled),
				Gui.drop_target(drop_message(handles, column, Key(key))),
				Gui.selected_s(Signal.select(selected, key)),
				Gui.style({ ..Gui.style_default, padding: 12, gap: 8, border_width: 1, radius: 8, background: Rgb(0x283A47), border_color: Rgb(0x4A6272) }),
			],
			[
				Gui.column(
					[Gui.test_id("title-${key}"), Gui.style({ ..Gui.style_default, font_size: 15, foreground: Rgb(0xF2F5F6) })],
					[Gui.text_s(row.map(|task| task.title))],
				),
				Gui.row(
					[Gui.style({ ..Gui.style_default, gap: 8 })],
					[
						Ui.switch(row.map(|task| task.assignee), |assignee| avatar(assignee, 24)),
						# The status color belongs to the priority word alone; the
						# assignee stays in the muted secondary grey.
						Gui.row(
							[Gui.test_id("meta-${key}"), Gui.style({ ..Gui.style_default, gap: 0 })],
							[
								Gui.column(
									[
										Gui.style_s(
											row.map(
												|task| {
													..Gui.style_default,
													font_size: 13,
													foreground: match task.priority {
														High => Rgb(0xF09A93)
														Low => Rgb(0x8FD4A8)
														_ => Rgb(0xA9BFCC)
													},
												},
											),
										),
									],
									[Gui.text_s(row.map(|task| "${task.priority.to_str()} priority"))],
								),
								Gui.column(
									[Gui.style({ ..Gui.style_default, font_size: 13, foreground: Rgb(0xA9BFCC) })],
									[Gui.text_s(row.map(|task| " · ${task.assignee}"))],
								),
							],
						),
					],
				),
				Gui.row(
					[],
					[
						Gui.action_button(
							{ label: Signal.const("Edit"), enabled: Signal.const(True) },
							[Gui.test_id("edit-${key}")],
							Ui.action(
								row.signal(),
								|task| Ui.update_states([
									handles.editor.write({ column, task }),
									handles.editing.write(True),
									handles.confirm_delete.write(False),
								]),
							),
						),
					],
				),
			],
		),
	)
}

column_view : Handles, Board.Column, Signal.Signal(Str) -> Elem
column_view = |handles, column, selected| {
	rows = column_state(handles, column).signal()
	visible = Signal.map2(rows, handles.filter.signal(), visible_rows)
	Gui.column(
		[Gui.disabled_s(handles.edit_disabled), Gui.test_id("column-${column.to_str()}"), Gui.drop_target(drop_message(handles, column, End)), Gui.style({ ..Gui.style_default, grow: True, gap: 12, padding: 12, radius: 10, background: Rgb(0x1B2A33) })],
		[
			Gui.heading(column.to_str()),
			Gui.column(
				[Gui.style({ ..Gui.style_default, font_size: 13, foreground: Rgb(0xA9BFCC) })],
				[Gui.text_s(rows.map(|items| "${Rows.len(items).to_str()} tasks"))],
			),
			Ui.each(visible, |row| task_card(row, column, handles, selected)),
			# Trailing so the hidden branch's empty text costs no gap slot
			# between the count line and the first card.
			Ui.when(
				visible.map(|items| Rows.len(items) == 0),
				|| Gui.column(
					[Gui.style({ ..Gui.style_default, font_size: 13, foreground: Rgb(0x93A9B6) })],
					[Gui.text("No matching tasks")],
				),
				|| Gui.text(""),
			),
		],
	)
}

## Field reducers share one atomic edit operation. The UI owns the text draft;
## the corresponding keyed task receives the identical value in the same turn.
edit_field : TextField, Handles, Board.Column, Str, List(Gui.Attr), (Board.Task, Str -> Board.Task), (Board.Task -> Str) -> Elem
edit_field = |field, handles, column, label, attrs, update, read| {
	owner = column_state(handles, column)
	reads = handles.context
	field(
		{ label, value: handles.editor.signal().map(|editor| read(editor.task)) },
		attrs.append(Gui.disabled_s(handles.edit_disabled)),
		Ui.action_str(
			reads,
			|context, text| {
				current = context.board
				task = update(current.editor.task, text)
				if task == current.editor.task {
					return Signal.noop
				}
				rows = Rows.apply(column_rows(current, column), [SetKey({ key: task.key, item: task })]) ?? crash "The active editor must name a live task"
				remember(handles, context, [owner.write(rows), handles.editor.write({ column, task }), handles.bytes.write(current.bytes - task_bytes(current.editor.task) + task_bytes(task))])
			},
		),
	)
}

priority_button : Handles, Board.Column, Signal.Signal(Str), Board.Priority -> Elem
priority_button = |handles, column, priority_key, priority| {
	owner = column_state(handles, column)
	reads = handles.context
	Gui.action_button(
		{ label: Signal.const(priority.to_str()), enabled: handles.editable },
		[
			Gui.label("${priority.to_str()} priority"),
			Gui.selected_s(Signal.select(priority_key, priority.to_str())),
		],
		Ui.action(
			reads,
			|context| {
				current = context.board
				task = { ..current.editor.task, priority }
				if task == current.editor.task {
					return Signal.noop
				}
				rows = Rows.apply(column_rows(current, column), [SetKey({ key: task.key, item: task })]) ?? crash "The active editor must name a live task"
				remember(handles, context, [owner.write(rows), handles.editor.write({ column, task })])
			},
		),
	)
}

move_button : Handles, Board.Column -> Elem
move_button = |handles, to|
	Gui.action_button({ label: Signal.const("Move to ${to.to_str()}"), enabled: handles.editable }, [], Ui.action(handles.context, |current| move_task(handles, current, current.board.editor.task.key, to, End)))

reorder_buttons : Handles, Board.Column -> Elem
reorder_buttons = |handles, column|
	Gui.row(
		[Gui.style({ ..Gui.style_default, gap: 8 })],
		[
			Gui.action_button(
				{ label: Signal.const("Move to top"), enabled: handles.editable },
				[],
				Ui.action(
					handles.context,
					|context| {
						current = context.board
						first = Rows.get(column_rows(current, column), 0) ?? crash "The selected task's column cannot be empty"
						move_task(handles, context, current.editor.task.key, column, Key(first.key))
					},
				),
			),
			Gui.action_button({ label: Signal.const("Move to bottom"), enabled: handles.editable }, [], Ui.action(handles.context, |current| move_task(handles, current, current.board.editor.task.key, column, End))),
		],
	)

delete_confirmation : Handles, Board.Column -> Elem
delete_confirmation = |handles, column| {
	owner = column_state(handles, column)
	reads = handles.context
	Ui.when(
		handles.confirm_delete.signal(),
		|| Gui.dialog(
			{ label: "Delete task", on_dismiss: handles.confirm_delete.on_unit(|_| False) },
			[Gui.test_id("delete-confirmation")],
			[
				Gui.text("Delete this task? This removes it from the board."),
				Gui.row(
					[],
					[
						Gui.button("Cancel deletion", handles.confirm_delete.on_unit(|_| False)),
						Gui.button(
							"Confirm delete",
							Ui.action(
								reads,
								|context| {
									current = context.board
									remaining = Rows.apply(column_rows(current, column), [RemoveKey(current.editor.task.key)]) ?? crash "The task selected for deletion must exist"
									remember(handles, context, [owner.write(remaining), handles.editing.write(False), handles.confirm_delete.write(False), handles.bytes.write(current.bytes - task_bytes(current.editor.task))])
								},
							),
						),
					],
				),
			],
		),
		|| Gui.action_button({ label: Signal.const("Delete task"), enabled: handles.editable }, [], handles.confirm_delete.on_unit(|_| True)),
	)
}

detail_view : Handles -> Elem
detail_view = |handles|
	Gui.panel(
		[Gui.test_id("task-detail"), Gui.style({ ..Gui.style_default, width: Px(320), padding: 16, gap: 12, background: Rgb(0x283A47), radius: 8 })],
		[
			Gui.heading("Task details"),
			Ui.when(
				handles.editing.signal(),
				|| {
					Ui.switch(
						handles.editor.signal().map(|editor| editor.column),
						|column| Gui.column(
							[],
							[
								Gui.column(
									[Gui.test_id("task-column"), Gui.style({ ..Gui.style_default, font_size: 13, foreground: Rgb(0xA9BFCC) })],
									[Gui.text_s(handles.editor.signal().map(|editor| editor.column.to_str()))],
								),
								Gui.column(
									[Gui.style({ ..Gui.style_default, gap: 4, font_size: 13, foreground: Rgb(0xA9BFCC) })],
									[Gui.text("Task title"), edit_field(Gui.text_input, handles, column, "Task title", [Gui.style({ ..Gui.style_default, width: Fill })], |task, title| { ..task, title }, |task| task.title)],
								),
								Gui.column(
									[Gui.style({ ..Gui.style_default, gap: 4, font_size: 13, foreground: Rgb(0xA9BFCC) })],
									[
										Gui.text("Assignee"),
										Gui.row(
											[Gui.style({ ..Gui.style_default, gap: 8 })],
											[
												Ui.switch(handles.editor.signal().map(|editor| editor.task.assignee), |assignee| avatar(assignee, 32)),
												edit_field(Gui.text_input, handles, column, "Assignee", [Gui.style({ ..Gui.style_default, width: Fill, grow: True })], |task, assignee| { ..task, assignee }, |task| task.assignee),
											],
										),
									],
								),
								edit_field(Gui.textarea, handles, column, "Task notes", [Gui.style({ ..Gui.style_default, height: Px(150) })], |task, notes| { ..task, notes }, |task| task.notes),
								Gui.text_s(handles.editor.signal().map(|editor| "Priority: ${editor.task.priority.to_str()}")),
								{
									priority_key = handles.editor.signal().map(|editor| editor.task.priority.to_str())
									Gui.row([Gui.style({ ..Gui.style_default, gap: 8 })], Board.priorities.map(|priority| priority_button(handles, column, priority_key, priority)))
								},
								Gui.column(
									[Gui.style({ ..Gui.style_default, font_size: 13, foreground: Rgb(0x93A9B6) })],
									[Gui.text("Changes appear on the board immediately.")],
								),
								reorder_buttons(handles, column),
								Gui.column([], Board.columns.keep_if(|other| other != column).map(|other| move_button(handles, other))),
								delete_confirmation(handles, column),
							],
						),
					)
				},
				|| Gui.text("Select a task to edit its details."),
			),
		],
	)

new_task_form : Handles -> Elem
new_task_form = |handles| {
	reads = { context: handles.context, title: handles.draft.signal(), next_id: handles.next_id.signal() }.Signal
	Gui.row(
		[Gui.style({ ..Gui.style_default, gap: 12 })],
		[
			Gui.text_input({ label: "New task title", value: handles.draft.signal() }, [Gui.placeholder("New task title…"), Gui.disabled_s(handles.edit_disabled), Gui.style({ ..Gui.style_default, width: Px(260), gap: 4 })], handles.draft.on_str(|_, value| value)),
			Gui.action_button(
				{ label: Signal.const("Add task"), enabled: Signal.map2(handles.draft.signal(), handles.editable, |title, editable| editable and !title.trim().is_empty()) },
				[],
				Ui.action(
					reads,
					|current| {
						if current.title.trim().is_empty() {
							return Signal.noop
						}
						if total_tasks(current.context.board) >= 500 {
							return handles.document.set_cmd({ ..current.context.document, problem: "This board already has 500 tasks. Delete a task before adding another; your new task draft is retained." })
						}
						if current.next_id == 18446744073709551615 {
							return handles.document.set_cmd({ ..current.context.document, problem: "This board has exhausted its task identities. Existing tasks can still be edited and saved." })
						}
						task = Board.new_task(current.next_id, current.title)
						rows = Rows.apply(current.context.board.planned, [Append([task])]) ?? crash "The next task ID must be unique"
						remember(
							handles,
							current.context,
							[
								handles.bytes.write(current.context.board.bytes + task_bytes(task)),
								handles.planned.write(rows),
								handles.next_id.write(current.next_id + 1),
								handles.draft.write(""),
								handles.editor.write({ column: Planned, task }),
								handles.editing.write(True),
								handles.confirm_delete.write(False),
							],
						)
					},
				),
			),
		],
	)
}

board_view : Handles -> Elem
board_view = |handles| {
	actions = document_actions(handles)
	chord = { key: "s", control: True, shift: False, alt: False, meta: False }
	selected = Signal.map2(
		handles.editor.signal(),
		handles.editing.signal(),
		|editor, editing| if editing {
			editor.task.key
		} else {
			""
		},
	)
	# The window identity names the open board file and marks unsaved work, so
	# the desktop switcher agrees with the toolbar about what is on screen.
	window_title = handles.context.map(
		|context| {
			mark = if dirty(context) { "* " } else { "" }
			name = match context.document.path {
				None => "Untitled board"
				Some(value) => value
			}
			"${mark}${name} - Launch Board"
		},
	)
	Gui.window_lifecycle(
		{
			on_close_requested: Ui.action(
				handles.context,
				|context| handles.close.set_cmd(
					if dirty(context) or context.document.phase != Phase.Idle {
						Close.Confirm
					} else {
						Close.Closing
					},
				),
			),
			decision: handles.close.signal().map(
				|intent| match intent {
					Close.KeepEditing => KeepOpen
					Close.Confirm | Close.Saving => AwaitDecision
					Close.Closing => Close
				},
			),
		},
		[
			Gui.column(
				[Gui.style({ ..Gui.style_default, padding: 24, gap: 12, width: Fill }), Gui.test_id("launch-board"), Gui.on_shortcut(chord, actions.save), Gui.on_shortcut({ ..chord, shift: True }, actions.save_as), Gui.on_shortcut({ ..chord, key: "o" }, actions.open), Gui.on_shortcut({ ..chord, key: "z" }, history_message(handles, False)), Gui.on_shortcut({ ..chord, key: "z", shift: True }, history_message(handles, True))],
				[
					Ui.on_change_initial(window_title, Gui.set_title),
					Gui.heading("Launch Board"),
					Gui.column(
						[Gui.style({ ..Gui.style_default, foreground: Rgb(0xA9BFCC) })],
						[Gui.text("A small team's workspace for the next release.")],
					),
					document_toolbar(handles, actions),
					Gui.row(
						[Gui.style({ ..Gui.style_default, gap: 16 })],
						[
							new_task_form(handles),
							Gui.text_input({ label: "Filter tasks", value: handles.filter.signal() }, [Gui.placeholder("Filter tasks…"), Gui.style({ ..Gui.style_default, width: Px(240), gap: 4 })], handles.filter.on_str(|_, text| text)),
						],
					),
					Gui.column(
						[Gui.style({ ..Gui.style_default, gap: 2, font_size: 13, foreground: Rgb(0x93A9B6) })],
						[
							Gui.text("Drag onto a card to place a task before it, or into a column to move it to the end."),
							Gui.text("Undo keeps up to 50 changes within 4 MiB; older changes are retired."),
						],
					),
					Gui.row(
						[Gui.style({ ..Gui.style_default, gap: 20, grow: True, overflow_x: Clip, overflow_y: Clip })],
						[
							Gui.row([Gui.style({ ..Gui.style_default, gap: 16, grow: True, overflow_x: Scroll })], Board.columns.map(|column| column_view(handles, column, selected))),
							detail_view(handles),
						],
					),
				].concat(document_bindings(handles)),
			),
		],
	)
}

main : () -> Elem
main = || Ui.state(
	initial_rows(Planned),
	|planned| {
		Ui.state(
			initial_rows(InProgress),
			|progress| {
				Ui.state(
					initial_rows(Complete),
					|complete| {
						Ui.state(
							{ column: Planned, task: Board.seed(Planned).first() ?? crash "The seeded board must contain a task" },
							|editor| {
								Ui.state(
									True,
									|editing| {
										Ui.state(
											"",
											|filter| {
												Ui.state(
													"",
													|draft| {
														Ui.state(
															7.U64,
															|next_id| {
																Ui.state(
																	False,
																	|confirm_delete| {
																		Ui.state(
																			initial_bytes(),
																			|bytes| Ui.state(
																				{ past: [], future: [] },
																				|history| {
																					movement = { planned: planned.signal(), progress: progress.signal(), complete: complete.signal(), editor: editor.signal(), editing: editing.signal(), bytes: bytes.signal() }.Signal
																					Ui.state(
																						{ path: None, baseline: None, phase: Phase.Idle, problem: "" },
																						|document| {
																							context = { board: movement, history: history.signal(), document: document.signal() }.Signal
																							tasks = { open: Files.choose_file_task("board-open"), save: Files.choose_save_path_task("board-save-path"), read: Files.read_text_task("board-read"), write: Files.write_text_task("board-write"), verify: Files.verify_assets_task("asset-verify") }
																							Ui.state(
																								Close.KeepEditing,
																								|close| Ui.state(
																									"",
																									|asset_problem| {
																										editable = document.signal().map(|doc| can_edit(doc.phase))
																										edit_disabled = editable.map(|value| !value)
																										board_view({ planned, progress, complete, editor, editing, filter, draft, next_id, confirm_delete, movement, context, history, bytes, document, asset_problem, tasks, close, editable, edit_disabled })
																									},
																								),
																							)
																						},
																					)
																				},
																			),
																		)
																	},
																)
															},
														)
													},
												)
											},
										)
									},
								)
							},
						)
					},
				)
			},
		)
	},
)

## Logical payload accounting is conservative across shared immutable snapshots.
## At most 50 entries and four MiB of task text/keys are retained across undo and redo;
## fixed Rows overhead is separately bounded by 500 tasks per snapshot.
task_bytes : Board.Task -> U64
task_bytes = |task| task.key.to_utf8().len() + task.title.to_utf8().len() + task.notes.to_utf8().len() + task.assignee.to_utf8().len() + 64

initial_bytes : () -> U64
initial_bytes = || Board.columns.fold(0.U64, |sum, column| Board.seed(column).fold(sum, |n, task| n + task_bytes(task)))

total_tasks : BoardSnapshot -> U64
total_tasks = |board| Rows.len(board.planned) + Rows.len(board.progress) + Rows.len(board.complete)

trim_history : List(BoardSnapshot) -> List(BoardSnapshot)
trim_history = |items| {
	var $bytes = 0.U64
	var $kept = []
	for item in items {
		if $kept.len() >= 50 or item.bytes > 4194304 - $bytes {
			break
		}
		$bytes = $bytes + item.bytes
		$kept = $kept.append(item)
	}
	$kept
}

remember : Handles, Context, List(Ui.StateWrite) -> Gui.Cmd
remember = |handles, context, writes| if can_edit(context.document.phase) {
	Ui.update_states(writes.append(handles.history.write({ past: trim_history([context.board].concat(context.history.past)), future: [] })))
} else {
	Signal.noop
}

history_button : Handles, Bool -> Elem
history_button = |handles, redo| Gui.action_button(
	{
		label: Signal.const(
			if redo {
				"Redo"
			} else {
				"Undo"
			},
		),
		enabled: Signal.map2(
			handles.history.signal(),
			handles.editable,
			|h, editable| editable and (
				if redo {
					!h.future.is_empty()
				} else {
					!h.past.is_empty()
				}
			),
		),
	},
	[],
	history_message(handles, redo),
)

history_message : Handles, Bool -> Gui.Msg
history_message = |handles, redo| Ui.action(
	handles.context,
	|context| {
		if !can_edit(context.document.phase) {
			return Signal.noop
		}
		stack = if redo {
			context.history.future
		} else {
			context.history.past
		}
		match stack.first() {
			Err(_) => Signal.noop
			Ok(previous) => {
				history = if redo {
					{ past: trim_history([context.board].concat(context.history.past)), future: stack.drop_first(1) }
				} else {
					{ past: stack.drop_first(1), future: trim_history([context.board].concat(context.history.future)) }
				}
				Ui.update_states([
					handles.planned.write(previous.planned),
					handles.progress.write(previous.progress),
					handles.complete.write(previous.complete),
					handles.editor.write(previous.editor),
					handles.editing.write(previous.editing),
					handles.bytes.write(previous.bytes),
					handles.confirm_delete.write(False),
					handles.history.write(bound_history(history, redo)),
				])
			}
		}
	},
)

can_edit : Phase -> Bool
can_edit = |phase| match phase {
	Phase.Idle | Phase.ChoosingSave(_) | Phase.Writing(_) => True
	_ => False
}

dirty : Context -> Bool
dirty = |context| match context.document.baseline {
	None => True
	Some(saved) => context.board.planned != saved.planned or context.board.progress != saved.progress or context.board.complete != saved.complete
}

DocumentActions : { open : Gui.Msg, save : Gui.Msg, save_as : Gui.Msg, cancel : Gui.Msg }

document_toolbar : Handles, DocumentActions -> Elem
document_toolbar = |handles, actions| {
	ready = handles.document.signal().map(|doc| doc.phase == Phase.Idle)

	# gap 0: everything below the button row is a conditional problem line or
	# dialog, so the toolbar's empty states pay no vertical rhythm.
	Gui.column(
		[Gui.test_id("board-document"), Gui.style({ ..Gui.style_default, gap: 0 })],
		[
			Gui.row(
				[Gui.style({ ..Gui.style_default, gap: 8 })],
				[
					Gui.action_button({ label: Signal.const("Open…"), enabled: ready }, [], actions.open),
					Gui.action_button({ label: Signal.const("Save"), enabled: ready }, [Gui.style({ ..Gui.style_default, padding: 8, radius: 6, background: Rgb(0x2E6FA3), hover_background: Rgb(0x3A80B8), active_background: Rgb(0x265D89) })], actions.save),
					Gui.action_button({ label: Signal.const("Save As…"), enabled: ready }, [], actions.save_as),
					history_button(handles, False),
					history_button(handles, True),
					Gui.column(
						[Gui.test_id("board-path"), Gui.style({ ..Gui.style_default, padding: 8, foreground: Rgb(0xF2F5F6) })],
						[
							Gui.text_s(
								handles.document.signal().map(
									|doc| match doc.path {
										None => "Untitled board"
										Some(path) => path
									},
								),
							),
						],
					),
					Gui.column(
						[
							Gui.test_id("board-status"),
							Gui.style_s(
								handles.context.map(
									|context| {
										..Gui.style_default,
										padding: 8,
										font_size: 13,
										foreground: match context.document.phase {
											Phase.Idle => if dirty(context) {
												Rgb(0xE8C27A)
											} else {
												Rgb(0x8FD4A8)
											}
											_ => Rgb(0xA9BFCC)
										},
									},
								),
							),
						],
						[
							Gui.text_s(
								handles.context.map(
									|context| match context.document.phase {
										Phase.Idle => if dirty(context) {
											"Unsaved changes"
										} else {
											"Saved"
										}
										Phase.ConfirmOpen => "Waiting for confirmation"
										Phase.ChoosingOpen => "Choose a board document"
										Phase.Reading(_) => "Opening board…"
										Phase.ChoosingSave(_) => "Choose a save destination"
										Phase.Writing(_) => "Saving board snapshot…"
									},
								),
							),
						],
					),
				],
			),
			Gui.column(
				[Gui.test_id("board-problem"), Gui.style({ ..Gui.style_default, font_size: 13, foreground: Rgb(0xF09A93) })],
				[Gui.text_s(handles.document.signal().map(|doc| doc.problem))],
			),
			Ui.when(
				handles.document.signal().map(|doc| doc.phase == Phase.ConfirmOpen),
				|| Gui.dialog(
					{ label: "Replace unsaved board?", on_dismiss: actions.cancel },
					[Gui.test_id("board-discard")],
					[
						Gui.heading("Replace unsaved board?"),
						Gui.text("Save your board first to keep these changes. Opening succeeds only after the new file is completely validated."),
						Gui.button("Keep editing", actions.cancel),
						Gui.button("Discard and open", handles.document.on_unit(|doc| { ..doc, phase: Phase.ChoosingOpen })),
					],
				),
				|| Gui.text(""),
			),
			Ui.when(handles.document.signal().map(|doc| doc.phase != Phase.Idle and doc.phase != Phase.ConfirmOpen), || Gui.button("Cancel operation", actions.cancel), || Gui.text("")),
			Gui.column(
				[Gui.test_id("asset-status"), Gui.style({ ..Gui.style_default, font_size: 13, foreground: Rgb(0xF09A93) })],
				[Gui.text_s(handles.asset_problem.signal())],
			),
			close_dialog(handles),
		],
	)
}

failed_file : Handles, Files.Error -> Gui.Cmd
failed_file = |handles, error| handles.document.update_cmd(
	|doc| {
		..doc,
		phase: Phase.Idle,
		problem: match error {
			Files.Error.Canceled => "Operation canceled; the current board is unchanged."
			_ => Files.error_text(error)
		},
	},
)

choice_result : Handles, Signal.TaskStatus(Files.Choice, Files.Error) -> Gui.Cmd
choice_result = |handles, status| match status {
	Signal.TaskStatus.Loading => Signal.noop
	Signal.TaskStatus.Failed(error) => failed_file(handles, error)
	Signal.TaskStatus.Done(Files.Choice.Canceled) => failed_file(handles, Files.Error.Canceled)
	Signal.TaskStatus.Done(Files.Choice.Chosen(path)) => handles.document.update_cmd(
		|doc| {
			..doc,
			phase: match doc.phase {
				Phase.ChoosingOpen => Phase.Reading(path)
				Phase.ChoosingSave(save) => Phase.Writing({ path, save })
				_ => doc.phase
			},
		},
	)
}

load_document : Handles, Files.TextFile -> Gui.Cmd
load_document = |handles, file| match Codec.decode(file.text) {
	Err(Codec.Error.Invalid(problem)) => handles.document.update_cmd(|doc| { ..doc, phase: Phase.Idle, problem })
	Ok(decoded) => {
		planned = Rows.from_list(decoded.planned, |task| task.key) ?? crash "Validated board keys must be unique"
		progress = Rows.from_list(decoded.progress, |task| task.key) ?? crash "Validated board keys must be unique"
		complete = Rows.from_list(decoded.complete, |task| task.key) ?? crash "Validated board keys must be unique"
		editor = match decoded.planned.first() {
			Ok(task) => { column: Planned, task }
			Err(_) => match decoded.progress.first() {
				Ok(task) => { column: InProgress, task }
				Err(_) => match decoded.complete.first() {
					Ok(task) => { column: Complete, task }
					Err(_) => { column: Planned, task: Board.new_task(0, "") }
				}
			}
		}
		bytes = decoded.planned.concat(decoded.progress).concat(decoded.complete).fold(0.U64, |sum, task| sum + task_bytes(task))
		editing = Rows.len(planned) + Rows.len(progress) + Rows.len(complete) > 0
		snapshot = { planned, progress, complete, editor, editing, bytes }
		Ui.update_states([
			handles.planned.write(planned),
			handles.progress.write(progress),
			handles.complete.write(complete),
			handles.editor.write(editor),
			handles.editing.write(editing),
			handles.bytes.write(bytes),
			handles.next_id.write(decoded.next),
			handles.history.write({ past: [], future: [] }),
			handles.filter.write(""),
			handles.draft.write(""),
			handles.confirm_delete.write(False),
			handles.document.write({ path: Some(file.path), baseline: Some(snapshot), phase: Phase.Idle, problem: "" }),
		])
	}
}

document_bindings : Handles -> List(Elem)
document_bindings = |handles| [
	Ui.on_mount(|| Files.verify_assets(handles.tasks.verify, asset_entries)),
	Ui.on_change(
		Signal.from_task(handles.tasks.verify),
		|status| match status {
			Signal.TaskStatus.Loading => Signal.noop
			Signal.TaskStatus.Failed(error) => handles.asset_problem.set_cmd("Asset verification failed: ${Files.error_text(error)}")
			Signal.TaskStatus.Done(report) => handles.asset_problem.set_cmd(asset_problem_text(report))
		},
	),
	Ui.on_change(
		handles.document.signal().map(|doc| doc.phase),
		|phase| match phase {
			Phase.ChoosingOpen => Files.choose_file(handles.tasks.open)
			Phase.Reading(path) => Files.read_text(handles.tasks.read, path)
			Phase.ChoosingSave(_) => Files.choose_save_path(handles.tasks.save, { directory: Home, suggested_name: "My project.board.json" })
			Phase.Writing(write) => Files.write_text(handles.tasks.write, { path: write.path, text: write.save.text })
			_ => Signal.noop
		},
	),
	Ui.on_change(Signal.from_task(handles.tasks.open), |status| choice_result(handles, status)),
	Ui.on_change(Signal.from_task(handles.tasks.save), |status| choice_result(handles, status)),
	Ui.on_change(
		Signal.from_task(handles.tasks.read),
		|status| match status {
			Signal.TaskStatus.Loading => Signal.noop
			Signal.TaskStatus.Failed(error) => failed_file(handles, error)
			Signal.TaskStatus.Done(file) => load_document(handles, file)
		},
	),
	Ui.on_change(
		Signal.from_task(handles.tasks.write),
		|status| match status {
			Signal.TaskStatus.Loading => Signal.noop
			Signal.TaskStatus.Failed(error) => failed_file(handles, error)
			Signal.TaskStatus.Done(result) => handles.document.update_cmd(
				|doc| match doc.phase {
					Phase.Writing(write) if write.path == result.path => { ..doc, path: Some(result.path), baseline: Some(write.save.snapshot), phase: Phase.Idle, problem: "" }
					_ => doc
				},
			)
		},
	),
]

## Evict the oldest opposite-direction entries when a large current draft enters
## history. The live edit always succeeds; an oversized snapshot has no undo entry.
bound_history : History, Bool -> History
bound_history = |history, redo| {
	primary = trim_history(
		if redo {
			history.past
		} else {
			history.future
		},
	)
	used = primary.fold(0.U64, |sum, item| sum + item.bytes)
	var $bytes = used
	var $count = primary.len()
	var $secondary = []
	for item in (
		if redo {
			history.future
		} else {
			history.past
		}
	) {
		if $count >= 50 or item.bytes > 4194304 - $bytes {
			break
		}
		$bytes = $bytes + item.bytes
		$count = $count + 1
		$secondary = $secondary.append(item)
	}
	if redo {
		{ past: primary, future: $secondary }
	} else {
		{ past: $secondary, future: primary }
	}
}

## History bounds count and aggregate task payload across undo and redo together.
expect {
	item : BoardSnapshot
	item = { planned: initial_rows(Planned), progress: initial_rows(InProgress), complete: initial_rows(Complete), editor: { column: Planned, task: Board.new_task(1, "Example") }, editing: True, bytes: 100000 }
	bounded = bound_history({ past: List.repeat(item, 30), future: List.repeat(item, 30) }, True)
	{ past: bounded.past.len(), future: bounded.future.len() } == { past: 30, future: 11 }
}

## Oversized snapshots are not retained and ordinary tiny histories cap at 50.
expect {
	item : BoardSnapshot
	item = { planned: initial_rows(Planned), progress: initial_rows(InProgress), complete: initial_rows(Complete), editor: { column: Planned, task: Board.new_task(1, "Example") }, editing: True, bytes: 1 }
	{ small: trim_history(List.repeat(item, 70)).len(), oversized: trim_history([{ ..item, bytes: 4194305 }]).len() } == { small: 50, oversized: 0 }
}

## Save and Save-and-close share exact immutable snapshot ownership.
save_document : Handles, Context, U64, { save_as : Bool, close_after : Bool } -> Gui.Cmd
save_document = |handles, context, next, options| {
	if context.document.phase != Phase.Idle {
		return Signal.noop
	}
	text = Codec.encode({ next, planned: Rows.to_list(context.board.planned), progress: Rows.to_list(context.board.progress), complete: Rows.to_list(context.board.complete) })
	if text.to_utf8().len() > 1048576 {
		return handles.document.set_cmd({ ..context.document, problem: "The encoded board exceeds one MiB. Shorten task notes before saving." })
	}
	match Codec.decode(text) {
		Err(Codec.Error.Invalid(problem)) => return handles.document.set_cmd({ ..context.document, problem: "Cannot save: ${problem}. Your draft is retained." })
		Ok(_) => {}
	}
	save = { text, snapshot: context.board }
	phase = match context.document.path {
		Some(path) if !options.save_as => Phase.Writing({ path, save })
		_ => Phase.ChoosingSave(save)
	}
	writes = [handles.document.write({ ..context.document, phase, problem: "" })]
	Ui.update_states(
		if options.close_after {
			writes.append(handles.close.write(Close.Saving))
		} else {
			writes
		},
	)
}

close_dialog : Handles -> Elem
close_dialog = |handles| {
	keep = handles.close.on_unit(|_| Close.KeepEditing)
	Ui.when(
		handles.close.signal().map(|intent| intent == Close.Confirm),
		|| Gui.dialog(
			{ label: "Close this board?", on_dismiss: keep },
			[Gui.test_id("board-close")],
			[
				Gui.heading("Save your board before closing?"),
				Gui.text("Keep editing to return to your project, or save a board document before closing."),
				Gui.text_s(handles.document.signal().map(|doc| doc.problem)),
				Gui.row(
					[],
					[
						Gui.button("Keep editing", keep),
						Gui.button("Close without saving", handles.close.on_unit(|_| Close.Closing)),
						Gui.action_button({ label: Signal.const("Save and close"), enabled: handles.document.signal().map(|doc| doc.phase == Phase.Idle) }, [], Ui.action({ context: handles.context, next: handles.next_id.signal() }.Signal, |{ context, next }| save_document(handles, context, next, { save_as: False, close_after: True }))),
					],
				),
			],
		),
		|| Ui.when(
			handles.close.signal().map(|intent| intent == Close.Saving),
			|| Gui.dialog(
				{ label: "Saving before closing", on_dismiss: keep },
				[Gui.test_id("board-close-saving")],
				[
					Gui.heading("Saving your board…"),
					Gui.text("The window stays open until the submitted board is saved."),
					Gui.button("Keep window open", keep),
					Ui.on_change(
						handles.context,
						|context| if context.document.phase == Phase.Idle {
							handles.close.set_cmd(
								if dirty(context) {
									Close.Confirm
								} else {
									Close.Closing
								},
							)
						} else {
							Signal.noop
						},
					),
				],
			),
			|| Gui.text(""),
		),
	)
}

document_actions : Handles -> DocumentActions
document_actions = |handles| {
	save_reads = { context: handles.context, next: handles.next_id.signal() }.Signal
	save_message = |save_as| Ui.action(save_reads, |{ context, next }| save_document(handles, context, next, { save_as, close_after: False }))
	open = Ui.action(
		handles.context,
		|context| if context.document.phase != Phase.Idle {
			Signal.noop
		} else {
			handles.document.set_cmd({
				..context.document,
				phase: if dirty(context) {
					Phase.ConfirmOpen
				} else {
					Phase.ChoosingOpen
				},
				problem: "",
			})
		},
	)
	cancel = Ui.action(
		handles.document.signal(),
		|doc| match doc.phase {
			Phase.ChoosingOpen => Signal.cancel(handles.tasks.open)
			Phase.ChoosingSave(_) => Signal.cancel(handles.tasks.save)
			Phase.Reading(_) => Signal.cancel(handles.tasks.read)
			Phase.Writing(_) => Signal.cancel(handles.tasks.write)
			_ => handles.document.set_cmd({ ..doc, phase: Phase.Idle })
		},
	)
	{ open, save: save_message(False), save_as: save_message(True), cancel }
}
