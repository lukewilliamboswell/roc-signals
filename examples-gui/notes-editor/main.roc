app [main] { roc: "nightly-2026-09-04-c125b82", pf: platform "../../platform-gui/main.roc", unicode: "../../vendor/unicode/main.roc" }

import pf.Action exposing [Action]
import pf.Elem exposing [Elem]
import pf.Gui exposing [Px]
import pf.Signal
import pf.Ui
import Document
import Session
import Theme
import Workflow

import "theme.json" as theme_json : Str

## Parsed while the compiler evaluates top-level definitions, so a bad
## theme.json fails `roc build` with a message naming the file and key.
theme : Theme.Palette
theme = Theme.from_json("examples-gui/notes-editor/theme.json", theme_json)

main : () -> Elem
main = || Ui.state(
	Session.initial,
	|session| {
		# The editable body belongs to the session state, beside the lifetime
		# that owns it: a document replacement advances the lifetime and installs
		# its text in one settled value, so the editor keyed by that lifetime can
		# never mount with another document's text.
		view = session.signal()
		ready = session.read(Session.can_start)
		phase = session.read(|value| value.phase)
		dirty = |value| Document.is_dirty({ draft: Session.draft(value), baseline: value.baseline })
		revert_ready = view.map(|value| Session.can_start(value) and dirty(value))
		save = Action.run(view, |_| Action.then([session.write(Session.begin_save)], |current| Workflow.save!(session, current, False)))
		save_as = Action.run(view, |_| Action.then([session.write(Session.begin_save)], |current| Workflow.save!(session, current, True)))
		open = Action.run(view, |_| Action.then([session.write(Session.begin_open)], |current| Workflow.open!(session, current.phase)))
		new = Action.run(
			view,
			|value| {
				if !Session.can_start(value) {
					Action.none
				} else if dirty(value) {
					Action.update([session.set({ ..value, phase: Session.Phase.ConfirmDiscard(Session.Destination.NewDocument), problem: None })])
				} else {
					Action.update([session.set(Session.new_document(value))])
				}
			},
		)
		revert = Action.run(
			view,
			|value| {
				if Session.can_start(value) and dirty(value) {
					Action.update([session.set({ ..value, phase: Session.Phase.ConfirmDiscard(Session.Destination.RevertDocument), problem: None })])
				} else {
					Action.none
				}
			},
		)
		cancel = Action.run(phase, |value| Workflow.cancel(session, value))
		# The window identity names the open document and marks unsaved work, so
		# the desktop switcher tells two notes apart the way the header does.
		window_title = view.map(
			|value| {
				mark = if dirty(value) { "* " } else { "" }
				"${mark}${value.baseline.title} - Notes"
			},
		)
		chord = { key: "s", control: True, shift: False, alt: False, meta: False }
		Elem.window_lifecycle(
			{ on_close_requested: session.update(Session.request_close), decision: session.read(Session.close_decision) },
			[
					Elem.col(
						{
							test_id: "notes-editor",
							padding: 24,
							gap: 12,
							width: Fill,
							height: Fill,
							bg: theme.background,
							fg: theme.text_primary,
							shortcuts: [{ chord: { ..chord, key: "n" }, msg: new }, { chord: { ..chord, key: "o" }, msg: open }, { chord: chord, msg: save }, { chord: { ..chord, shift: True }, msg: save_as }, { chord: { ..chord, key: "Escape", control: False }, msg: cancel }],
						},
						[
							Ui.on_change_initial(window_title, Gui.set_title),
							Elem.heading("Notes"),
							Elem.col(
								{ fg: theme.text_secondary },
								["A quiet place to collect your thoughts."],
							),
							Elem.row(
								{ gap: 8 },
								[
									Elem.action_button({ caption: Signal.const("New"), enabled: ready }, new),
									Elem.action_button({ caption: Signal.const("Open…"), enabled: ready }, open),
									Elem.action_button({
										caption: Signal.const("Save"),
										enabled: revert_ready,
										padding: theme.control_padding,
										radius: theme.radius,
										bg: theme.accent,
										hover_bg: theme.accent_hover,
										active_bg: theme.accent_active,
									}, save),
									Elem.action_button({ caption: Signal.const("Save As…"), enabled: ready }, save_as),
									Elem.action_button({ caption: Signal.const("Revert changes"), enabled: revert_ready }, revert),
								],
							),
							Elem.row(
								{ gap: 12 },
								[
									Elem.col(
										{ test_id: "document-name", font_size: 18, fg: theme.text_primary },
										[Elem.text_s(session.read(|state| state.baseline.title))],
									),
									Elem.col(
										{
											test_id: "note-status",
											changes: view.map(
												|value| Gui.Style.{
													padding: 4,
													font_size: 13,
													fg: if dirty(value) {
														theme.warning
													} else {
														theme.text_secondary
													},
												},
											),
										},
										[Elem.text_s(view.map(Session.status))],
									),
								],
							),
							Elem.row(
								{ width: Fill, height: Fill, grow: True, gap: 0 },
								[
									Elem.col({ grow: True }, []),
									Elem.col(
										{ width: 740.Px, height: Fill },
										[
											# Keyed by the document lifetime, so a replacement mounts a fresh
											# editor and ordinary typing keeps its selection and undo history.
											Ui.switch(
												session.read(|value| value.document_generation),
												|_| Elem.textarea(
													{
														label: "Note text",
														value: session.read(|value| value.body),
														placeholder: "Start writing…",
														disabled: session.read(|value| !Session.can_edit(value.phase) or value.close != Session.CloseState.NoClose),
														width: Fill,
														height: Fill,
														grow: True,
														gap: 4,
													},
													session.update_str(Session.edit),
												),
											),
										],
									),
									Elem.col({ grow: True }, []),
								],
							),
							Elem.row(
								{ gap: 24 },
								[
									Elem.col(
										{
											test_id: "note-summary",
											font_size: 13,
											fg: theme.text_secondary,
										},
										[Elem.text_s(session.read(|value| Document.counts_text(Document.counts(value.body))))],
									),
								],
							),
							# Conditional problem/dialog rows live in one trailing gap-0
							# wrapper so their empty states cost no vertical rhythm.
							Elem.col(
								{ gap: 0 },
								[
									Elem.col(
										{ test_id: "note-problem", font_size: 13, fg: theme.danger },
										[
											Elem.text_s(
												session.read(
													|state| match state.problem {
														None => ""
														Some(problem) => problem
													},
												),
											),
										],
									),
									Ui.when(
										phase.map(
											|value| match value {
												Session.Phase.ConfirmDiscard(_) => True
												_ => False
											},
										),
										|| Elem.dialog(
											{
												label: "Discard your changes?",
												on_dismiss: session.update(Session.cancel),
												test_id: "discard-confirmation",
												padding: 16,
												gap: theme.gap,
												bg: theme.card,
												radius: theme.radius,
											},
											[
												Elem.heading("Discard your changes?"),
												"Your unsaved text will be replaced. Keep editing to return to this draft.",
												Elem.row(
													Elem.RowProps.{},
													[
														Elem.button("Keep editing", session.update(Session.cancel)),
														Elem.button(
															"Discard changes",
															Action.run(
																view,
																|value| match value.phase {
																	Session.Phase.ConfirmDiscard(Session.Destination.NewDocument) => Action.update([session.set(Session.new_document(value))])
																	Session.Phase.ConfirmDiscard(Session.Destination.OpenDocument) => Action.then([session.write(Session.confirm_open)], |current| Workflow.open!(session, current.phase))
																	Session.Phase.ConfirmDiscard(Session.Destination.RevertDocument) => Action.update([session.set(Session.revert(value))])
																	_ => Action.none
																},
															),
														),
													],
												),
											],
										),
										|| Elem.text(""),
									),
									Ui.when(
										session.read(|state| state.close == Session.CloseState.ConfirmClose),
										|| Elem.dialog(
											{
												label: "Save before closing?",
												on_dismiss: session.update(Session.cancel),
												test_id: "close-confirmation",
											},
											[
												Elem.heading("Save before closing?"),
												"Your note has unsaved changes. Save them, discard them, or keep editing.",
												Elem.row(
													Elem.RowProps.{},
													[
														Elem.button("Keep editing", session.update(Session.cancel)),
														Elem.button("Discard and close", session.update(|state| { ..state, close: Session.CloseState.AllowClose })),
														Elem.button("Save and close", Action.run(view, |_| Action.then([session.write(Session.save_and_close)], |current| Workflow.save!(session, current, False)))),
													],
												),
											],
										),
										|| Elem.text(""),
									),
								],
							),
						],
					),
				],
			)
		},
)
