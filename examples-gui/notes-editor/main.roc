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
	|session| Ui.state(
		"",
		|body| {
			tasks = Workflow.create_tasks()
			view = { state: session.signal(), body: body.signal() }.Signal
			ready = session.read(Session.can_start)
			phase = session.read(|state| state.phase)
			revert_ready = view.map(|value| Session.can_start(value.state) and Document.is_dirty({ draft: Session.draft(value.state, value.body), baseline: value.state.baseline }))
			save = session.update_with(body, |state, text| Session.begin_save({ state, draft: Session.draft(state, text), save_as: False }))
			save_as = session.update_with(body, |state, text| Session.begin_save({ state, draft: Session.draft(state, text), save_as: True }))
			open = session.update_with(body, |state, text| Session.begin_open({ state, draft: Session.draft(state, text) }))
			new = Action.run(
				view,
				|{ state, body: text }| {
					if !Session.can_start(state) {
						Action.none
					}
						else if Document.is_dirty({ draft: Session.draft(state, text), baseline: state.baseline }) {
							Action.update([session.set({ ..state, phase: Session.Phase.ConfirmDiscard(Session.Destination.NewDocument), problem: None })])
						} else {
							Action.update([session.set(Session.new_document(state)), body.set("")])
						}
				},
			)
			revert = Action.run(
				view,
				|{ state, body: text }| {
					if Session.can_start(state) and Document.is_dirty({ draft: Session.draft(state, text), baseline: state.baseline }) {
						Action.update([session.set({ ..state, phase: Session.Phase.ConfirmDiscard(Session.Destination.RevertDocument), problem: None })])
					} else {
						Action.none
					}
				},
			)
			cancel = Action.run(phase, |value| Workflow.cancel(session, tasks, value))
			chord = { key: "s", control: True, shift: False, alt: False, meta: False }
			Elem.window_lifecycle(
				{ on_close_requested: session.update_with(body, Session.request_close), decision: session.read(Session.close_decision) },
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
												|value| {
													dirty = Document.is_dirty({ draft: Session.draft(value.state, value.body), baseline: value.state.baseline })
													Gui.Style.{
														padding: 4,
														font_size: 13,
														fg: if dirty {
															theme.warning
														} else {
															theme.text_secondary
														},
													}
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
											Ui.switch(
												session.read(|state| state.document_generation),
												|_| Elem.textarea(
													{
														label: "Note text",
														value: body.signal(),
														placeholder: "Start writing…",
														disabled: session.read(|state| !Session.can_edit(state.phase) or state.close != Session.CloseState.NoClose),
														width: Fill,
														height: Fill,
														grow: True,
														gap: 4,
													},
													body.update_str(|_, value| value),
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
										[Elem.text_s(body.read(|text| Document.counts_text(Document.counts(text))))],
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
												Session.Phase.ChoosingOpen | Session.Phase.ChoosingSave(_) | Session.Phase.Reading(_) | Session.Phase.Writing(_) => True
												_ => False
											},
										),
										|| Elem.button("Cancel operation", cancel),
										|| Elem.text(""),
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
																session.signal(),
																|state| match state.phase {
																	Session.Phase.ConfirmDiscard(Session.Destination.NewDocument) => Action.update([session.set(Session.new_document(state)), body.set("")])
																	Session.Phase.ConfirmDiscard(Session.Destination.OpenDocument) => Action.update([session.set({ ..state, phase: Session.Phase.ChoosingOpen })])
																	Session.Phase.ConfirmDiscard(Session.Destination.RevertDocument) => Action.update([session.set({ ..Session.cancel(state), document_generation: Session.next_generation(state) }), body.set(state.baseline.body)])
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
														Elem.button("Save and close", session.update_with(body, Session.save_and_close)),
													],
												),
											],
										),
										|| Elem.text(""),
									),
								],
							),
						].concat(Workflow.bindings(session, body, tasks)),
					),
				],
			)
		},
	),
)
