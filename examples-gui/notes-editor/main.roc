app [main] { roc: "nightly-2026-09-04-c125b82", pf: platform "../../platform-gui/main.roc", unicode: "../../vendor/unicode/main.roc" }

import pf.Elem exposing [Elem]
import pf.Gui
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
						[
							Gui.test_id("notes-editor"),
							Gui.style({ ..Gui.style_default, padding: 24, gap: 12, width: Fill, height: Fill, background: Rgb(theme.background), foreground: Rgb(theme.text_primary) }),
							Gui.on_shortcut({ ..chord, key: "n" }, new),
							Gui.on_shortcut({ ..chord, key: "o" }, open),
							Gui.on_shortcut(chord, save),
							Gui.on_shortcut({ ..chord, shift: True }, save_as),
							Gui.on_shortcut({ ..chord, key: "Escape", control: False }, cancel),
						],
						[
							Gui.heading("Notes"),
							Gui.column(
								[Gui.style({ ..Gui.style_default, foreground: Rgb(theme.text_secondary) })],
								[Gui.text("A quiet place to collect your thoughts.")],
							),
							Gui.row(
								[Gui.style({ ..Gui.style_default, gap: 8 })],
								[
									Gui.action_button({ label: Signal.const("New"), enabled: ready }, [], new),
									Gui.action_button({ label: Signal.const("Open…"), enabled: ready }, [], open),
									Gui.action_button({ label: Signal.const("Save"), enabled: revert_ready }, [Gui.style({ ..Gui.style_default, padding: theme.control_padding, radius: theme.radius, background: Rgb(theme.accent) })], save),
									Gui.action_button({ label: Signal.const("Save As…"), enabled: ready }, [], save_as),
									Gui.action_button({ label: Signal.const("Revert changes"), enabled: revert_ready }, [], revert),
								],
							),
							Gui.row(
								[Gui.style({ ..Gui.style_default, gap: 12 })],
								[
									Gui.column(
										[Gui.test_id("document-name"), Gui.style({ ..Gui.style_default, font_size: 18, foreground: Rgb(theme.text_primary) })],
										[Gui.text_s(session.signal().map(|state| state.baseline.title))],
									),
									Gui.column(
										[
											Gui.test_id("note-status"),
											Gui.style_s(
												view.map(
													|value| {
														dirty = Document.is_dirty({ draft: Session.draft(value.state, value.body), baseline: value.state.baseline })
														{
															..Gui.style_default,
															padding: 4,
															font_size: 13,
															foreground: if dirty {
																Rgb(theme.warning)
															} else {
																Rgb(theme.text_secondary)
															},
														}
													},
												),
											),
										],
										[Gui.text_s(view.map(Session.status))],
									),
								],
							),
							Gui.row(
								[Gui.style({ ..Gui.style_default, width: Fill, height: Fill, grow: True, gap: 0 })],
								[
									Gui.column([Gui.style({ ..Gui.style_default, grow: True })], []),
									Gui.column(
										[Gui.style({ ..Gui.style_default, width: Px(740), height: Fill })],
										[
											Ui.switch(
												session.signal().map(|state| state.document_generation),
												|_| Gui.textarea(
													{ label: "Note text", value: body.signal() },
													[
														Gui.placeholder("Start writing…"),
														Gui.disabled_s(session.signal().map(|state| !Session.can_edit(state.phase) or state.close != Session.CloseState.NoClose)),
														Gui.style({ ..Gui.style_default, width: Fill, height: Fill, grow: True, gap: 4 }),
													],
													body.on_str(|_, value| value),
												),
											),
										],
									),
									Gui.column([Gui.style({ ..Gui.style_default, grow: True })], []),
								],
							),
							Gui.row(
								[Gui.style({ ..Gui.style_default, gap: 24 })],
								[
									Gui.column(
										[Gui.test_id("note-summary"), Gui.style({ ..Gui.style_default, font_size: 13, foreground: Rgb(theme.text_secondary) })],
										[Gui.text_s(body.signal().map(|text| Document.counts_text(Document.counts(text))))],
									),
								],
							),
							# Conditional problem/dialog rows live in one trailing gap-0
							# wrapper so their empty states cost no vertical rhythm.
							Gui.column(
								[Gui.style({ ..Gui.style_default, gap: 0 })],
								[
									Gui.column(
										[Gui.test_id("note-problem"), Gui.style({ ..Gui.style_default, font_size: 13, foreground: Rgb(theme.danger) })],
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
											{ label: "Discard your changes?", on_dismiss: session.on_unit(Session.cancel) },
											[
												Gui.test_id("discard-confirmation"),
												Gui.style({ ..Gui.style_default, padding: 16, gap: theme.gap, background: Rgb(theme.card), radius: theme.radius }),
											],
											[
												Gui.heading("Discard your changes?"),
												Gui.text("Your unsaved text will be replaced. Keep editing to return to this draft."),
												Gui.row(
													[],
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
											{ label: "Save before closing?", on_dismiss: session.on_unit(Session.cancel) },
											[Gui.test_id("close-confirmation")],
											[
												Gui.heading("Save before closing?"),
												Gui.text("Your note has unsaved changes. Save them, discard them, or keep editing."),
												Gui.row(
													[],
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
