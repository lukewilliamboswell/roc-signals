app [main] { pf: platform "../../platform-gui/main.roc" }

import Board
import pf.Elem exposing [Elem]
import pf.Gui
import pf.Rows
import pf.Signal
import pf.Ui

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
}

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
move_task : Handles, BoardSnapshot, Str, Board.Column, Rows.Before -> Gui.Cmd
move_task = |handles, current, key, destination_column, before|
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
				source.set_cmd(next)
			} else {
				remaining = Rows.apply(column_rows(current, found.column), [RemoveKey(key)]) ?? crash "The moved task must exist"
				insertion = match before {
					End => Append([found.task])
					Key(target) => InsertBefore({ before: target, items: [found.task] })
				}
				moved = Rows.apply(column_rows(current, destination_column), [insertion]) ?? crash "Task keys must be unique across columns"
				writes = [source.write(remaining), destination.write(moved)]
				if current.editor.task.key == key {
					Ui.update_states(writes.append(handles.editor.write({ column: destination_column, task: found.task })))
				} else {
					Ui.update_states(writes)
				}
			}
		}
	}

drop_message : Handles, Board.Column, Rows.Before -> Gui.Msg
drop_message = |handles, column, before|
	Ui.action_detail(handles.movement, |current, key| move_task(handles, current, key, column, before))

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
				Gui.drop_target(drop_message(handles, column, Key(key))),
				Gui.selected_s(Signal.select(selected, key)),
				Gui.style({ ..Gui.style_default, padding: 12, gap: 8, border_width: 1, radius: 8, background: Rgb(0x24323E), border_color: Rgb(0x465565) }),
			],
			[
				Gui.text_s(row.map(|task| task.title)),
				Gui.text_s(row.map(|task| "${task.priority.to_str()} priority · ${task.assignee}")),
				Gui.button(
					"Edit ${key}",
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
	)
}

column_view : Handles, Board.Column, Signal.Signal(Str) -> Elem
column_view = |handles, column, selected| {
	rows = column_state(handles, column).signal()
	visible = Signal.map2(rows, handles.filter.signal(), visible_rows)
	Gui.column(
		[Gui.test_id("column-${column.to_str()}"), Gui.drop_target(drop_message(handles, column, End)), Gui.style({ ..Gui.style_default, width: Fill, grow: True, gap: 12 })],
		[
			Gui.heading(column.to_str()),
			Gui.text_s(rows.map(|items| "${Rows.len(items).to_str()} tasks")),
			Ui.when(visible.map(|items| Rows.len(items) == 0), || Gui.text("No matching tasks"), || Gui.text("")),
			Ui.each(visible, |row| task_card(row, column, handles, selected)),
		],
	)
}

## Field reducers share one atomic edit operation. The UI owns the text draft;
## the corresponding keyed task receives the identical value in the same turn.
edit_field : TextField, Handles, Board.Column, Str, List(Gui.Attr), (Board.Task, Str -> Board.Task), (Board.Task -> Str) -> Elem
edit_field = |field, handles, column, label, attrs, update, read| {
	owner = column_state(handles, column)
	reads = { rows: owner.signal(), editor: handles.editor.signal() }.Signal
	field(
		{ label, value: handles.editor.signal().map(|editor| read(editor.task)) },
		attrs,
		Ui.action_str(
			reads,
			|current, text| {
				task = update(current.editor.task, text)
				rows = Rows.apply(current.rows, [SetKey({ key: task.key, item: task })]) ?? crash "The active editor must name a live task"
				Ui.update_states([owner.write(rows), handles.editor.write({ column, task })])
			},
		),
	)
}

priority_button : Handles, Board.Column, Board.Priority -> Elem
priority_button = |handles, column, priority| {
	owner = column_state(handles, column)
	reads = { rows: owner.signal(), editor: handles.editor.signal() }.Signal
	Gui.action_button(
		{ label: Signal.const(priority.to_str()), enabled: Signal.const(True) },
		[Gui.label("${priority.to_str()} priority")],
		Ui.action(
			reads,
			|current| {
				task = { ..current.editor.task, priority }
				rows = Rows.apply(current.rows, [SetKey({ key: task.key, item: task })]) ?? crash "The active editor must name a live task"
				Ui.update_states([owner.write(rows), handles.editor.write({ column, task })])
			},
		),
	)
}

move_button : Handles, Board.Column -> Elem
move_button = |handles, to|
	Gui.button("Move to ${to.to_str()}", Ui.action(handles.movement, |current| move_task(handles, current, current.editor.task.key, to, End)))

reorder_buttons : Handles, Board.Column -> Elem
reorder_buttons = |handles, column|
	Gui.row(
		[Gui.style({ ..Gui.style_default, gap: 8 })],
		[
			Gui.button(
				"Move to top",
				Ui.action(
					handles.movement,
					|current| {
						first = Rows.get(column_rows(current, column), 0) ?? crash "The selected task's column cannot be empty"
						move_task(handles, current, current.editor.task.key, column, Key(first.key))
					},
				),
			),
			Gui.button("Move to bottom", Ui.action(handles.movement, |current| move_task(handles, current, current.editor.task.key, column, End))),
		],
	)

delete_confirmation : Handles, Board.Column -> Elem
delete_confirmation = |handles, column| {
	owner = column_state(handles, column)
	reads = { rows: owner.signal(), editor: handles.editor.signal() }.Signal
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
								|current| {
									remaining = Rows.apply(current.rows, [RemoveKey(current.editor.task.key)]) ?? crash "The task selected for deletion must exist"
									Ui.update_states([owner.write(remaining), handles.editing.write(False), handles.confirm_delete.write(False)])
								},
							),
						),
					],
				),
			],
		),
		|| Gui.button("Delete task", handles.confirm_delete.on_unit(|_| True)),
	)
}

detail_view : Handles -> Elem
detail_view = |handles|
	Gui.panel(
		[Gui.test_id("task-detail"), Gui.style({ ..Gui.style_default, width: Px(320), padding: 16, gap: 12, background: Rgb(0x24323E), radius: 8 })],
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
								Gui.text_s(handles.editor.signal().map(|editor| "${editor.task.key} · ${editor.column.to_str()}")),
								edit_field(Gui.text_input, handles, column, "Task title", [], |task, title| { ..task, title }, |task| task.title),
								edit_field(Gui.text_input, handles, column, "Assignee", [], |task, assignee| { ..task, assignee }, |task| task.assignee),
								edit_field(Gui.textarea, handles, column, "Task notes", [Gui.style({ ..Gui.style_default, height: Px(150) })], |task, notes| { ..task, notes }, |task| task.notes),
								Gui.text_s(handles.editor.signal().map(|editor| "Priority: ${editor.task.priority.to_str()}")),
								Gui.row([Gui.style({ ..Gui.style_default, gap: 8 })], Board.priorities.map(|priority| priority_button(handles, column, priority))),
								Gui.text("Changes appear on the board immediately."),
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
	reads = { rows: handles.planned.signal(), title: handles.draft.signal(), next_id: handles.next_id.signal() }.Signal
	Gui.row(
		[Gui.style({ ..Gui.style_default, gap: 12 })],
		[
			Gui.text_input({ label: "New task title", value: handles.draft.signal() }, [], handles.draft.on_str(|_, value| value)),
			Gui.action_button(
				{ label: Signal.const("Add task"), enabled: handles.draft.signal().map(|title| !title.trim().is_empty()) },
				[],
				Ui.action(
					reads,
					|current| {
						task = Board.new_task(current.next_id, current.title)
						rows = Rows.apply(current.rows, [Append([task])]) ?? crash "The next task ID must be unique"
						Ui.update_states([
							handles.planned.write(rows),
							handles.next_id.write(current.next_id + 1),
							handles.draft.write(""),
							handles.editor.write({ column: Planned, task }),
							handles.editing.write(True),
							handles.confirm_delete.write(False),
						])
					},
				),
			),
		],
	)
}

board_view : Handles -> Elem
board_view = |handles| {
	selected = Signal.map2(
		handles.editor.signal(),
		handles.editing.signal(),
		|editor, editing| if editing {
			editor.task.key
		} else {
			""
		},
	)
	Gui.column(
		[Gui.style({ ..Gui.style_default, padding: 20, gap: 20, width: Fill })],
		[
			Gui.heading("Launch Board"),
			Gui.text("A small team's workspace for the next release."),
			Gui.text("Drag onto a card to place a task before it, or into a column to move it to the end."),
			new_task_form(handles),
			Gui.text_input({ label: "Filter tasks", value: handles.filter.signal() }, [], handles.filter.on_str(|_, text| text)),
			Gui.row(
				[Gui.style({ ..Gui.style_default, gap: 20, width: Fill })],
				[
					Gui.row([Gui.style({ ..Gui.style_default, gap: 16, grow: True, width: Fill })], Board.columns.map(|column| column_view(handles, column, selected))),
					detail_view(handles),
				],
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
																		movement = { planned: planned.signal(), progress: progress.signal(), complete: complete.signal(), editor: editor.signal() }.Signal
																		board_view({ planned, progress, complete, editor, editing, filter, draft, next_id, confirm_delete, movement })
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
