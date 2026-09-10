app [main] { roc: "nightly-2026-09-04-c125b82", pf: platform "../../platform-gui/main.roc" }

import Board
import Codec
import Manifest
import pf.Files
import "assets/manifest.json" as manifest_json : Str
import pf.Action exposing [Action]
import pf.Elem exposing [Elem]
import pf.Event
import pf.Gui exposing [Px]
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
	Some(source) => Elem.image({
		source,
		label: "${assignee} avatar",
		width: Px(size),
		height: Px(size),
		radius: size,
	})
	None => Elem.text("")
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

## Builds one text control from its label, controlled value, disabled signal, and reducer.
TextField : Str, Signal.Signal(Str), Signal.Signal(Bool), Event.Handler -> Elem

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
move_task : Handles, Context, Str, Board.Column, Rows.Before -> Action(a)
move_task = |handles, context, key, destination_column, before| {
	current = context.board
	match find_task(current, key) {
		Err(_) => Action.update([])
		Ok(found) => {
			source = column_state(handles, found.column)
			destination = column_state(handles, destination_column)
			drop_on_self = match before {
				End => False
				Key(target) => target == key
			}
			if drop_on_self and found.column == destination_column {
				Action.update([])
			} else if found.column == destination_column {
				next = Rows.apply(column_rows(current, found.column), [MoveKeyBefore({ key, before })]) ?? crash "The target card must belong to its column"
				if next == column_rows(current, found.column) {
					Action.none
				} else {
					remember(handles, context, [source.set(next)])
				}
			} else {
				remaining = Rows.apply(column_rows(current, found.column), [RemoveKey(key)]) ?? crash "The moved task must exist"
				insertion = match before {
					End => Append([found.task])
					Key(target) => InsertBefore({ before: target, items: [found.task] })
				}
				moved = Rows.apply(column_rows(current, destination_column), [insertion]) ?? crash "Task keys must be unique across columns"
				writes = [source.set(remaining), destination.set(moved)]
				if current.editor.task.key == key {
					remember(handles, context, writes.append(handles.editor.set({ column: destination_column, task: found.task })))
				} else {
					remember(handles, context, writes)
				}
			}
		}
	}
}

drop_message : Handles, Board.Column, Rows.Before -> Event.Handler
drop_message = |handles, column, before|
	Action.run_detail(handles.context, |current, key| move_task(handles, current, key, column, before))

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
		|| Elem.panel(
			{
				test_id: key,
				drag_source: key,
				disabled: handles.edit_disabled,
				on_drop: drop_message(handles, column, Key(key)),
				selected: Signal.select(selected, key),
				padding: 12,
				gap: 8,
				border_width: 1,
				radius: 8,
				bg: Rgb(0x283A47),
				border_color: Rgb(0x4A6272),
			},
			[
				Elem.col(
					{ test_id: "title-${key}", font_size: 15, fg: Rgb(0xF2F5F6) },
					[Elem.text_s(row.map(|task| task.title))],
				),
				Elem.row(
					{ gap: 8 },
					[
						Ui.switch(row.map(|task| task.assignee), |assignee| avatar(assignee, 24)),
						# The status color belongs to the priority word alone; the
						# assignee stays in the muted secondary grey.
						Elem.row(
							{ test_id: "meta-${key}", gap: 0 },
							[
								Elem.col(
									{
										changes: row.map(
											|task| Gui.Style.{
												font_size: 13,
												fg: match task.priority {
													High => Rgb(0xF09A93)
													Low => Rgb(0x8FD4A8)
													_ => Rgb(0xA9BFCC)
												},
											},
										),
									},
									[Elem.text_s(row.map(|task| "${task.priority.to_str()} priority"))],
								),
								Elem.col(
									{ font_size: 13, fg: Rgb(0xA9BFCC) },
									[Elem.text_s(row.map(|task| " · ${task.assignee}"))],
								),
							],
						),
					],
				),
				Elem.row(
					Elem.RowProps.{},
					[
						Elem.action_button(
							{
								caption: Signal.const("Edit"),
								test_id: "edit-${key}",
							},
							Action.run(
								row.signal(),
								|task| Action.update([
									handles.editor.set({ column, task }),
									handles.editing.set(True),
									handles.confirm_delete.set(False),
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
	Elem.col(
		{
			disabled: handles.edit_disabled,
			test_id: "column-${column.to_str()}",
			on_drop: drop_message(handles, column, End),
			grow: True,
			gap: 12,
			padding: 12,
			radius: 10,
			bg: Rgb(0x1B2A33),
		},
		[
			Elem.heading(column.to_str()),
			Elem.col(
				{ font_size: 13, fg: Rgb(0xA9BFCC) },
				[Elem.text_s(rows.map(|items| "${Rows.len(items).to_str()} tasks"))],
			),
			Ui.each(visible, |row| task_card(row, column, handles, selected)),
			# Trailing so the hidden branch's empty text costs no gap slot
			# between the count line and the first card.
			Ui.when(
				visible.map(|items| Rows.len(items) == 0),
				|| Elem.col(
					{ font_size: 13, fg: Rgb(0x93A9B6) },
					["No matching tasks"],
				),
				|| Elem.text(""),
			),
		],
	)
}

## Field reducers share one atomic edit operation. The UI owns the text draft;
## the corresponding keyed task receives the identical value in the same turn.
edit_field : TextField, Handles, Board.Column, Str, (Board.Task, Str -> Board.Task), (Board.Task -> Str) -> Elem
edit_field = |field, handles, column, label, update, read| {
	owner = column_state(handles, column)
	reads = handles.context
	field(
		label,
		handles.editor.read(|editor| read(editor.task)),
		handles.edit_disabled,
		Action.run_str(
			reads,
			|context, text| {
				current = context.board
				task = update(current.editor.task, text)
				if task == current.editor.task {
					return Action.none
				}
				rows = Rows.apply(column_rows(current, column), [SetKey({ key: task.key, item: task })]) ?? crash "The active editor must name a live task"
				remember(handles, context, [owner.set(rows), handles.editor.set({ column, task }), handles.bytes.set(current.bytes - task_bytes(current.editor.task) + task_bytes(task))])
			},
		),
	)
}

priority_button : Handles, Board.Column, Signal.Signal(Str), Board.Priority -> Elem
priority_button = |handles, column, priority_key, priority| {
	owner = column_state(handles, column)
	reads = handles.context
	Elem.action_button(
		{
			caption: Signal.const(priority.to_str()),
			enabled: handles.editable,
			label: "${priority.to_str()} priority",
			selected: Signal.select(priority_key, priority.to_str()),
		},
		Action.run(
			reads,
			|context| {
				current = context.board
				task = { ..current.editor.task, priority }
				if task == current.editor.task {
					return Action.none
				}
				rows = Rows.apply(column_rows(current, column), [SetKey({ key: task.key, item: task })]) ?? crash "The active editor must name a live task"
				remember(handles, context, [owner.set(rows), handles.editor.set({ column, task })])
			},
		),
	)
}

move_button : Handles, Board.Column -> Elem
move_button = |handles, to|
	Elem.action_button({ caption: Signal.const("Move to ${to.to_str()}"), enabled: handles.editable }, Action.run(handles.context, |current| move_task(handles, current, current.board.editor.task.key, to, End)))

reorder_buttons : Handles, Board.Column -> Elem
reorder_buttons = |handles, column|
	Elem.row(
		{ gap: 8 },
		[
			Elem.action_button(
				{
					caption: Signal.const("Move to top"),
					enabled: handles.editable,
				},
				Action.run(
					handles.context,
					|context| {
						current = context.board
						first = Rows.get(column_rows(current, column), 0) ?? crash "The selected task's column cannot be empty"
						move_task(handles, context, current.editor.task.key, column, Key(first.key))
					},
				),
			),
			Elem.action_button({ caption: Signal.const("Move to bottom"), enabled: handles.editable }, Action.run(handles.context, |current| move_task(handles, current, current.board.editor.task.key, column, End))),
		],
	)

delete_confirmation : Handles, Board.Column -> Elem
delete_confirmation = |handles, column| {
	owner = column_state(handles, column)
	reads = handles.context
	Ui.when(
		handles.confirm_delete.signal(),
		|| Elem.dialog(
			{
				label: "Delete task",
				on_dismiss: handles.confirm_delete.update(|_| False),
				test_id: "delete-confirmation",
			},
			[
				"Delete this task? This removes it from the board.",
				Elem.row(
					Elem.RowProps.{},
					[
						Elem.button("Cancel deletion", handles.confirm_delete.update(|_| False)),
						Elem.button(
							"Confirm delete",
							Action.run(
								reads,
								|context| {
									current = context.board
									remaining = Rows.apply(column_rows(current, column), [RemoveKey(current.editor.task.key)]) ?? crash "The task selected for deletion must exist"
									remember(handles, context, [owner.set(remaining), handles.editing.set(False), handles.confirm_delete.set(False), handles.bytes.set(current.bytes - task_bytes(current.editor.task))])
								},
							),
						),
					],
				),
			],
		),
		|| Elem.action_button({ caption: Signal.const("Delete task"), enabled: handles.editable }, handles.confirm_delete.update(|_| True)),
	)
}

detail_view : Handles -> Elem
detail_view = |handles|
	Elem.panel(
		{
			test_id: "task-detail",
			width: 320.Px,
			padding: 16,
			gap: 12,
			bg: Rgb(0x283A47),
			radius: 8,
		},
		[
			Elem.heading("Task details"),
			Ui.when(
				handles.editing.signal(),
				|| {
					Ui.switch(
						handles.editor.read(|editor| editor.column),
						|column| Elem.col(
							Elem.ColProps.{},
							[
								Elem.col(
									{ test_id: "task-column", font_size: 13, fg: Rgb(0xA9BFCC) },
									[Elem.text_s(handles.editor.read(|editor| editor.column.to_str()))],
								),
								Elem.col(
									{ gap: 4, font_size: 13, fg: Rgb(0xA9BFCC) },
									["Task title", edit_field(|label, value, disabled, msg| Elem.text_input({ label, value, disabled, width: Fill }, msg), handles, column, "Task title", |task, title| { ..task, title }, |task| task.title)],
								),
								Elem.col(
									{ gap: 4, font_size: 13, fg: Rgb(0xA9BFCC) },
									[
										"Assignee",
										Elem.row(
											{ gap: 8 },
											[
												Ui.switch(handles.editor.read(|editor| editor.task.assignee), |assignee| avatar(assignee, 32)),
												edit_field(|label, value, disabled, msg| Elem.text_input({ label, value, disabled, width: Fill, grow: True }, msg), handles, column, "Assignee", |task, assignee| { ..task, assignee }, |task| task.assignee),
											],
										),
									],
								),
								edit_field(|label, value, disabled, msg| Elem.textarea({ label, value, disabled, height: 150.Px }, msg), handles, column, "Task notes", |task, notes| { ..task, notes }, |task| task.notes),
								Elem.text_s(handles.editor.read(|editor| "Priority: ${editor.task.priority.to_str()}")),
								{
									priority_key = handles.editor.read(|editor| editor.task.priority.to_str())
									Elem.row({ gap: 8 }, Board.priorities.map(|priority| priority_button(handles, column, priority_key, priority)))
								},
								Elem.col(
									{ font_size: 13, fg: Rgb(0x93A9B6) },
									["Changes appear on the board immediately."],
								),
								reorder_buttons(handles, column),
								Elem.col(Elem.ColProps.{}, Board.columns.keep_if(|other| other != column).map(|other| move_button(handles, other))),
								delete_confirmation(handles, column),
							],
						),
					)
				},
				|| Elem.text("Select a task to edit its details."),
			),
		],
	)

new_task_form : Handles -> Elem
new_task_form = |handles| {
	reads = { context: handles.context, title: handles.draft.signal(), next_id: handles.next_id.signal() }.Signal
	Elem.row(
		{ gap: 12 },
		[
			Elem.text_input({
				label: "New task title",
				value: handles.draft.signal(),
				placeholder: "New task title…",
				disabled: handles.edit_disabled,
				width: 260.Px,
				gap: 4,
			}, handles.draft.update_str(|_, value| value)),
			Elem.action_button(
				{
					caption: Signal.const("Add task"),
					enabled: Signal.map2(handles.draft.signal(), handles.editable, |title, editable| editable and !title.trim().is_empty()),
				},
				Action.run(
					reads,
					|current| {
						if current.title.trim().is_empty() {
							return Action.none
						}
						if total_tasks(current.context.board) >= 500 {
							return Action.update([handles.document.set({ ..current.context.document, problem: "This board already has 500 tasks. Delete a task before adding another; your new task draft is retained." })])
						}
						if current.next_id == 18446744073709551615 {
							return Action.update([handles.document.set({ ..current.context.document, problem: "This board has exhausted its task identities. Existing tasks can still be edited and saved." })])
						}
						task = Board.new_task(current.next_id, current.title)
						rows = Rows.apply(current.context.board.planned, [Append([task])]) ?? crash "The next task ID must be unique"
						remember(
							handles,
							current.context,
							[
								handles.bytes.set(current.context.board.bytes + task_bytes(task)),
								handles.planned.set(rows),
								handles.next_id.set(current.next_id + 1),
								handles.draft.set(""),
								handles.editor.set({ column: Planned, task }),
								handles.editing.set(True),
								handles.confirm_delete.set(False),
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
	Elem.window_lifecycle(
		{
			on_close_requested: Action.run(
				handles.context,
				|context| Action.update([handles.close.set(
					if dirty(context) or context.document.phase != Phase.Idle {
						Close.Confirm
					} else {
						Close.Closing
					},
				)]),
			),
			decision: handles.close.read(
				|intent| match intent {
					Close.KeepEditing => KeepOpen
					Close.Confirm | Close.Saving => AwaitDecision
					Close.Closing => Close
				},
			),
		},
		[
			Elem.col(
				{
					test_id: "launch-board",
					padding: 24,
					gap: 12,
					width: Fill,
					shortcuts: [{ chord: chord, msg: actions.save }, { chord: { ..chord, shift: True }, msg: actions.save_as }, { chord: { ..chord, key: "o" }, msg: actions.open }, { chord: { ..chord, key: "z" }, msg: history_message(handles, False) }, { chord: { ..chord, key: "z", shift: True }, msg: history_message(handles, True) }],
				},
				[
					Elem.heading("Launch Board"),
					Elem.col(
						{ fg: Rgb(0xA9BFCC) },
						["A small team's workspace for the next release."],
					),
					document_toolbar(handles, actions),
					Elem.row(
						{ gap: 16 },
						[
							new_task_form(handles),
							Elem.text_input({
								label: "Filter tasks",
								value: handles.filter.signal(),
								placeholder: "Filter tasks…",
								width: 240.Px,
								gap: 4,
							}, handles.filter.update_str(|_, text| text)),
						],
					),
					Elem.col(
						{ gap: 2, font_size: 13, fg: Rgb(0x93A9B6) },
						[
							"Drag onto a card to place a task before it, or into a column to move it to the end.",
							"Undo keeps up to 50 changes within 4 MiB; older changes are retired.",
						],
					),
					Elem.row(
						{ gap: 20, grow: True, overflow_x: Clip, overflow_y: Clip },
						[
							Elem.row({ gap: 16, grow: True, overflow_x: Scroll }, Board.columns.map(|column| column_view(handles, column, selected))),
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
																							Ui.state(
																								Close.KeepEditing,
																								|close| Ui.state(
																									"",
																									|asset_problem| {
																										editable = document.read(|doc| can_edit(doc.phase))
																										edit_disabled = editable.map(|value| !value)
																										board_view({ planned, progress, complete, editor, editing, filter, draft, next_id, confirm_delete, movement, context, history, bytes, document, asset_problem, close, editable, edit_disabled })
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

remember : Handles, Context, List(Ui.StateWrite) -> Action(a)
remember = |handles, context, writes| if can_edit(context.document.phase) {
	Action.update(writes.append(handles.history.set({ past: trim_history([context.board].concat(context.history.past)), future: [] })))
} else {
	Action.none
}

history_button : Handles, Bool -> Elem
history_button = |handles, redo| Elem.action_button(
	{
		caption: Signal.const(
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
	history_message(handles, redo),
)

history_message : Handles, Bool -> Event.Handler
history_message = |handles, redo| Action.run(
	handles.context,
	|context| {
		if !can_edit(context.document.phase) {
			return Action.none
		}
		stack = if redo {
			context.history.future
		} else {
			context.history.past
		}
		match stack.first() {
			Err(_) => Action.none
			Ok(previous) => {
				history = if redo {
					{ past: trim_history([context.board].concat(context.history.past)), future: stack.drop_first(1) }
				} else {
					{ past: stack.drop_first(1), future: trim_history([context.board].concat(context.history.future)) }
				}
				Action.update([
					handles.planned.set(previous.planned),
					handles.progress.set(previous.progress),
					handles.complete.set(previous.complete),
					handles.editor.set(previous.editor),
					handles.editing.set(previous.editing),
					handles.bytes.set(previous.bytes),
					handles.confirm_delete.set(False),
					handles.history.set(bound_history(history, redo)),
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

DocumentActions : { open : Event.Handler, save : Event.Handler, save_as : Event.Handler, cancel : Event.Handler }

document_toolbar : Handles, DocumentActions -> Elem
document_toolbar = |handles, actions| {
	ready = handles.document.read(|doc| doc.phase == Phase.Idle)

	# gap 0: everything below the button row is a conditional problem line or
	# dialog, so the toolbar's empty states pay no vertical rhythm.
	Elem.col(
		{ test_id: "board-document", gap: 0 },
		[
			Elem.row(
				{ gap: 8 },
				[
					Elem.action_button({ caption: Signal.const("Open…"), enabled: ready }, actions.open),
					Elem.action_button({
						caption: Signal.const("Save"),
						enabled: ready,
						padding: 8,
						radius: 6,
						bg: Rgb(0x2E6FA3),
						hover_bg: Rgb(0x3A80B8),
						active_bg: Rgb(0x265D89),
					}, actions.save),
					Elem.action_button({ caption: Signal.const("Save As…"), enabled: ready }, actions.save_as),
					history_button(handles, False),
					history_button(handles, True),
					Elem.col(
						{ test_id: "board-path", padding: 8, fg: Rgb(0xF2F5F6) },
						[
							Elem.text_s(
								handles.document.read(
									|doc| match doc.path {
										None => "Untitled board"
										Some(path) => path
									},
								),
							),
						],
					),
					Elem.col(
						{
							test_id: "board-status",
							changes: handles.context.map(
								|context| Gui.Style.{
									padding: 8,
									font_size: 13,
									fg: match context.document.phase {
										Phase.Idle => if dirty(context) {
											Rgb(0xE8C27A)
										} else {
											Rgb(0x8FD4A8)
										}
										_ => Rgb(0xA9BFCC)
									},
								},
							),
						},
						[
							Elem.text_s(
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
			Elem.col(
				{ test_id: "board-problem", font_size: 13, fg: Rgb(0xF09A93) },
				[Elem.text_s(handles.document.read(|doc| doc.problem))],
			),
			Ui.when(
				handles.document.read(|doc| doc.phase == Phase.ConfirmOpen),
				|| Elem.dialog(
					{
						label: "Replace unsaved board?",
						on_dismiss: actions.cancel,
						test_id: "board-discard",
					},
					[
						Elem.heading("Replace unsaved board?"),
						"Save your board first to keep these changes. Opening succeeds only after the new file is completely validated.",
						Elem.button("Keep editing", actions.cancel),
						Elem.button("Discard and open", handles.document.update(|doc| { ..doc, phase: Phase.ChoosingOpen })),
					],
				),
				|| Elem.text(""),
			),
			Ui.when(handles.document.read(|doc| doc.phase != Phase.Idle and doc.phase != Phase.ConfirmOpen), || Elem.button("Cancel operation", actions.cancel), || Elem.text("")),
			Elem.col(
				{ test_id: "asset-status", font_size: 13, fg: Rgb(0xF09A93) },
				[Elem.text_s(handles.asset_problem.signal())],
			),
			close_dialog(handles),
		],
	)
}

failed_file : Handles, Files.Error -> Action(a)
failed_file = |handles, error| Action.update([handles.document.write(
	|doc| {
		..doc,
		phase: Phase.Idle,
		problem: match error {
			Files.Error.Canceled => "Operation canceled; the current board is unchanged."
			_ => Files.error_text(error)
		},
	},
)])

chosen : Handles, Try(Files.Choice, Files.Error) -> Action(a)
chosen = |handles, result| match result {
	Err(error) => failed_file(handles, error)
	Ok(Files.Choice.Canceled) => failed_file(handles, Files.Error.Canceled)
	Ok(Files.Choice.Chosen(path)) => Action.update([handles.document.write(
		|doc| {
			..doc,
			phase: match doc.phase {
				Phase.ChoosingOpen => Phase.Reading(path)
				Phase.ChoosingSave(save) => Phase.Writing({ path, save })
				_ => doc.phase
			},
		},
	)])
}

load_document : Handles, Files.TextFile -> Action(a)
load_document = |handles, file| match Codec.decode(file.text) {
	Err(Codec.Error.Invalid(problem)) => Action.update([handles.document.write(|doc| { ..doc, phase: Phase.Idle, problem })])
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
		Action.update([
			handles.planned.set(planned),
			handles.progress.set(progress),
			handles.complete.set(complete),
			handles.editor.set(editor),
			handles.editing.set(editing),
			handles.bytes.set(bytes),
			handles.next_id.set(decoded.next),
			handles.history.set({ past: [], future: [] }),
			handles.filter.set(""),
			handles.draft.set(""),
			handles.confirm_delete.set(False),
			handles.document.set({ path: Some(file.path), baseline: Some(snapshot), phase: Phase.Idle, problem: "" }),
		])
	}
}

## Choosing, reading, writing, and asset verification each run as one `Files`
## call inside an effect, against the phase as it is after the change
## committed. A chooser blocks that effect until the user answers.
document_bindings : Handles -> List(Elem)
document_bindings = |handles| [
	Action.on_mount(|| Action.then([], |_| verify_assets!(handles))),
	Action.on_change(
		handles.document.read(|doc| doc.phase),
		|phase| match phase {
			Phase.ChoosingOpen | Phase.ChoosingSave(_) | Phase.Reading(_) | Phase.Writing(_) => Action.then([], |current| transfer!(handles, current))
			_ => Action.none
		},
	),
]

## Runs the chooser, read, or write the current phase asks for; a phase that
## moved on runs nothing.
transfer! : Handles, Phase => Action(Phase)
transfer! = |handles, phase| match phase {
	Phase.ChoosingOpen => chosen(handles, Files.choose_file!())
	Phase.ChoosingSave(_) => chosen(handles, Files.choose_save_path!({ directory: Home, suggested_name: "My project.board.json" }))
	Phase.Reading(path) => match Files.read_text!(path) {
		Ok(file) => load_document(handles, file)
		Err(error) => failed_file(handles, error)
	}
	Phase.Writing(write) => match Files.write_text!({ path: write.path, text: write.save.text }) {
		Ok(result) => Action.update([handles.document.write(
			|doc| match doc.phase {
				Phase.Writing(pending) if pending.path == result.path => { ..doc, path: Some(result.path), baseline: Some(pending.save.snapshot), phase: Phase.Idle, problem: "" }
				_ => doc
			},
		)])
		Err(error) => failed_file(handles, error)
	}
	_ => Action.none
}

verify_assets! : Handles => Action({})
verify_assets! = |handles| match Files.verify_assets!(asset_entries) {
	Ok(report) => Action.update([handles.asset_problem.set(asset_problem_text(report))])
	Err(error) => Action.update([handles.asset_problem.set("Asset verification failed: ${Files.error_text(error)}")])
}

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
save_document : Handles, Context, U64, { save_as : Bool, close_after : Bool } -> Action(a)
save_document = |handles, context, next, options| {
	if context.document.phase != Phase.Idle {
		return Action.none
	}
	text = Codec.encode({ next, planned: Rows.to_list(context.board.planned), progress: Rows.to_list(context.board.progress), complete: Rows.to_list(context.board.complete) })
	if text.to_utf8().len() > 1048576 {
		return Action.update([handles.document.set({ ..context.document, problem: "The encoded board exceeds one MiB. Shorten task notes before saving." })])
	}
	match Codec.decode(text) {
		Err(Codec.Error.Invalid(problem)) => return Action.update([handles.document.set({ ..context.document, problem: "Cannot save: ${problem}. Your draft is retained." })])
		Ok(_) => {}
	}
	save = { text, snapshot: context.board }
	phase = match context.document.path {
		Some(path) if !options.save_as => Phase.Writing({ path, save })
		_ => Phase.ChoosingSave(save)
	}
	writes = [handles.document.set({ ..context.document, phase, problem: "" })]
	Action.update(
		if options.close_after {
			writes.append(handles.close.set(Close.Saving))
		} else {
			writes
		},
	)
}

close_dialog : Handles -> Elem
close_dialog = |handles| {
	keep = handles.close.update(|_| Close.KeepEditing)
	Ui.when(
		handles.close.read(|intent| intent == Close.Confirm),
		|| Elem.dialog(
			{
				label: "Close this board?",
				on_dismiss: keep,
				test_id: "board-close",
			},
			[
				Elem.heading("Save your board before closing?"),
				"Keep editing to return to your project, or save a board document before closing.",
				Elem.text_s(handles.document.read(|doc| doc.problem)),
				Elem.row(
					Elem.RowProps.{},
					[
						Elem.button("Keep editing", keep),
						Elem.button("Close without saving", handles.close.update(|_| Close.Closing)),
						Elem.action_button({
							caption: Signal.const("Save and close"),
							enabled: handles.document.read(|doc| doc.phase == Phase.Idle),
						}, Action.run({ context: handles.context, next: handles.next_id.signal() }.Signal, |{ context, next }| save_document(handles, context, next, { save_as: False, close_after: True }))),
					],
				),
			],
		),
		|| Ui.when(
			handles.close.read(|intent| intent == Close.Saving),
			|| Elem.dialog(
				{
					label: "Saving before closing",
					on_dismiss: keep,
					test_id: "board-close-saving",
				},
				[
					Elem.heading("Saving your board…"),
					"The window stays open until the submitted board is saved.",
					Elem.button("Keep window open", keep),
					Action.on_change(
						handles.context,
						|context| if context.document.phase == Phase.Idle {
							Action.update([handles.close.set(
								if dirty(context) {
									Close.Confirm
								} else {
									Close.Closing
								},
							)])
						} else {
							Action.none
						},
					),
				],
			),
			|| Elem.text(""),
		),
	)
}

document_actions : Handles -> DocumentActions
document_actions = |handles| {
	save_reads = { context: handles.context, next: handles.next_id.signal() }.Signal
	save_message = |save_as| Action.run(save_reads, |{ context, next }| save_document(handles, context, next, { save_as, close_after: False }))
	open = Action.run(
		handles.context,
		|context| if context.document.phase != Phase.Idle {
			Action.none
		} else {
			Action.update([handles.document.set({
				..context.document,
				phase: if dirty(context) {
					Phase.ConfirmOpen
				} else {
					Phase.ChoosingOpen
				},
				problem: "",
			})])
		},
	)
	cancel = Action.run(
		handles.document.signal(),
		|doc| match doc.phase {
			Phase.ChoosingOpen | Phase.ChoosingSave(_) | Phase.Reading(_) | Phase.Writing(_) => Action.none
			_ => Action.update([handles.document.set({ ..doc, phase: Phase.Idle })])
		},
	)
	{ open, save: save_message(False), save_as: save_message(True), cancel }
}
