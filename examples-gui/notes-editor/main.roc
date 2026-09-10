app [main] { roc: "nightly-2026-09-04-c125b82", pf: platform "../../platform-gui/main.roc", unicode: "../../vendor/unicode/main.roc" }

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
			ready = session.signal().map(Session.can_start)
			phase = session.signal().map(|state| state.phase)
			revert_ready = view.map(|value| Session.can_start(value.state) and Document.is_dirty({ draft: Session.draft(value.state, value.body), baseline: value.state.baseline }))
			save = session.on_unit_with(body, |state, text| Session.begin_save({ state, draft: Session.draft(state, text), save_as: False }))
			save_as = session.on_unit_with(body, |state, text| Session.begin_save({ state, draft: Session.draft(state, text), save_as: True }))
			open = session.on_unit_with(body, |state, text| Session.begin_open({ state, draft: Session.draft(state, text) }))
			new = Ui.action(
				view,
				|{ state, body: text }| {
					if !Session.can_start(state) {
						Signal.noop
					}
						else if Document.is_dirty({ draft: Session.draft(state, text), baseline: state.baseline }) {
							session.set_cmd({ ..state, phase: Session.Phase.ConfirmDiscard(Session.Destination.NewDocument), problem: None })
						} else {
							Ui.update_states([session.write(Session.new_document(state)), body.write("")])
						}
				},
			)
			revert = Ui.action(
				view,
				|{ state, body: text }| {
					if Session.can_start(state) and Document.is_dirty({ draft: Session.draft(state, text), baseline: state.baseline }) {
						session.set_cmd({ ..state, phase: Session.Phase.ConfirmDiscard(Session.Destination.RevertDocument), problem: None })
					} else {
						Signal.noop
					}
				},
			)
			cancel = Ui.action(phase, |value| Workflow.cancel(session, tasks, value))
			chord = { key: "s", control: True, shift: False, alt: False, meta: False }
			Gui.window_lifecycle(
				{ on_close_requested: session.on_unit_with(body, Session.request_close), decision: session.signal().map(Session.close_decision) },
				[
					Gui.column(
						{
							test_id: "notes-editor",
							padding: 24,
							gap: 12,
							width: Fill,
							height: Fill,
							background: theme.background,
							foreground: theme.text_primary,
							shortcuts: [{ chord: { ..chord, key: "n" }, msg: new }, { chord: { ..chord, key: "o" }, msg: open }, { chord: chord, msg: save }, { chord: { ..chord, shift: True }, msg: save_as }, { chord: { ..chord, key: "Escape", control: False }, msg: cancel }],
						},
						[
							Gui.heading("Notes"),
							Gui.column(
								{ foreground: theme.text_secondary },
								["A quiet place to collect your thoughts."],
							),
							Gui.row(
								{ gap: 8 },
								[
									Gui.action_button({ caption: Signal.const("New"), enabled: ready }, new),
									Gui.action_button({ caption: Signal.const("Open…"), enabled: ready }, open),
									Gui.action_button({
										caption: Signal.const("Save"),
										enabled: revert_ready,
										padding: theme.control_padding,
										radius: theme.radius,
										background: theme.accent,
										hover_background: theme.accent_hover,
										active_background: theme.accent_active,
									}, save),
									Gui.action_button({ caption: Signal.const("Save As…"), enabled: ready }, save_as),
									Gui.action_button({ caption: Signal.const("Revert changes"), enabled: revert_ready }, revert),
								],
							),
							Gui.row(
								{ gap: 12 },
								[
									Gui.column(
										{ test_id: "document-name", font_size: 18, foreground: theme.text_primary },
										[Gui.text_s(session.signal().map(|state| state.baseline.title))],
									),
									Gui.column(
										{
											test_id: "note-status",
											changes: view.map(
												|value| {
													dirty = Document.is_dirty({ draft: Session.draft(value.state, value.body), baseline: value.state.baseline })
													Gui.Style.{
														padding: 4,
														font_size: 13,
														foreground: if dirty {
															theme.warning
														} else {
															theme.text_secondary
														},
													}
												},
											),
										},
										[Gui.text_s(view.map(Session.status))],
									),
								],
							),
							Gui.row(
								{ width: Fill, height: Fill, grow: True, gap: 0 },
								[
									Gui.column({ grow: True }, []),
									Gui.column(
										{ width: 740.Px, height: Fill },
										[
											Ui.switch(
												session.signal().map(|state| state.document_generation),
												|_| Gui.textarea(
													{
														label: "Note text",
														value: body.signal(),
														placeholder: "Start writing…",
														disabled: session.signal().map(|state| !Session.can_edit(state.phase) or state.close != Session.CloseState.NoClose),
														width: Fill,
														height: Fill,
														grow: True,
														gap: 4,
													},
													body.on_str(|_, value| value),
												),
											),
										],
									),
									Gui.column({ grow: True }, []),
								],
							),
							Gui.row(
								{ gap: 24 },
								[
									Gui.column(
										{
											test_id: "note-summary",
											font_size: 13,
											foreground: theme.text_secondary,
										},
										[Gui.text_s(body.signal().map(|text| Document.counts_text(Document.counts(text))))],
									),
								],
							),
							# Conditional problem/dialog rows live in one trailing gap-0
							# wrapper so their empty states cost no vertical rhythm.
							Gui.column(
								{ gap: 0 },
								[
									Gui.column(
										{ test_id: "note-problem", font_size: 13, foreground: theme.danger },
										[
											Gui.text_s(
												session.signal().map(
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
										|| Gui.button("Cancel operation", cancel),
										|| Gui.text(""),
									),
									Ui.when(
										phase.map(
											|value| match value {
												Session.Phase.ConfirmDiscard(_) => True
												_ => False
											},
										),
										|| Gui.dialog(
											{
												label: "Discard your changes?",
												on_dismiss: session.on_unit(Session.cancel),
												test_id: "discard-confirmation",
												padding: 16,
												gap: theme.gap,
												background: theme.card,
												radius: theme.radius,
											},
											[
												Gui.heading("Discard your changes?"),
												"Your unsaved text will be replaced. Keep editing to return to this draft.",
												Gui.row(
													Gui.RowProps.{},
													[
														Gui.button("Keep editing", session.on_unit(Session.cancel)),
														Gui.button(
															"Discard changes",
															Ui.action(
																session.signal(),
																|state| match state.phase {
																	Session.Phase.ConfirmDiscard(Session.Destination.NewDocument) => Ui.update_states([session.write(Session.new_document(state)), body.write("")])
																	Session.Phase.ConfirmDiscard(Session.Destination.OpenDocument) => session.set_cmd({ ..state, phase: Session.Phase.ChoosingOpen })
																	Session.Phase.ConfirmDiscard(Session.Destination.RevertDocument) => Ui.update_states([session.write({ ..Session.cancel(state), document_generation: Session.next_generation(state) }), body.write(state.baseline.body)])
																	_ => Signal.noop
																},
															),
														),
													],
												),
											],
										),
										|| Gui.text(""),
									),
									Ui.when(
										session.signal().map(|state| state.close == Session.CloseState.ConfirmClose),
										|| Gui.dialog(
											{
												label: "Save before closing?",
												on_dismiss: session.on_unit(Session.cancel),
												test_id: "close-confirmation",
											},
											[
												Gui.heading("Save before closing?"),
												"Your note has unsaved changes. Save them, discard them, or keep editing.",
												Gui.row(
													Gui.RowProps.{},
													[
														Gui.button("Keep editing", session.on_unit(Session.cancel)),
														Gui.button("Discard and close", session.on_unit(|state| { ..state, close: Session.CloseState.AllowClose })),
														Gui.button("Save and close", session.on_unit_with(body, Session.save_and_close)),
													],
												),
											],
										),
										|| Gui.text(""),
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
