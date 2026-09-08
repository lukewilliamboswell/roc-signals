app [main] { pf: platform "../../platform-gui/main.roc" }

import pf.Elem exposing [Elem]
import pf.Gui
import pf.Signal
import pf.Ui
import Document
import Session
import Workflow

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
							Ui.update_states([session.write(Session.initial), body.write("")])
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
			Gui.column(
				[
					Gui.test_id("notes-editor"),
					Gui.style({ ..Gui.style_default, padding: 24, gap: 16, width: Fill, height: Fill, background: Rgb(1317150), foreground: Rgb(14870247) }),
					Gui.on_shortcut({ ..chord, key: "n" }, new),
					Gui.on_shortcut({ ..chord, key: "o" }, open),
					Gui.on_shortcut(chord, save),
					Gui.on_shortcut({ ..chord, shift: True }, save_as),
					Gui.on_shortcut({ ..chord, key: "Escape", control: False }, cancel),
				],
				[
					Gui.heading("Notes"),
					Gui.text("A quiet place to collect your thoughts."),
					Gui.row(
						[Gui.style({ ..Gui.style_default, gap: 8 })],
						[
							Gui.action_button({ label: Signal.const("New"), enabled: ready }, [], new),
							Gui.action_button({ label: Signal.const("Open…"), enabled: ready }, [], open),
							Gui.action_button({ label: Signal.const("Save"), enabled: ready }, [], save),
							Gui.action_button({ label: Signal.const("Save As…"), enabled: ready }, [], save_as),
							Gui.action_button({ label: Signal.const("Revert changes"), enabled: revert_ready }, [], revert),
						],
					),
					Gui.panel([Gui.test_id("document-name")], [Gui.text_s(session.signal().map(|state| state.baseline.title))]),
					Gui.textarea(
						{ label: "Note text", value: body.signal() },
						[
							Gui.disabled_s(phase.map(|value| !Session.can_edit(value))),
							Gui.style({ ..Gui.style_default, width: Fill, grow: True, padding: 12, border_width: 1, border_color: Rgb(4213592), radius: 6 }),
						],
						body.on_str(|_, value| value),
					),
					Gui.row(
						[Gui.style({ ..Gui.style_default, gap: 24 })],
						[
							Gui.panel([Gui.test_id("note-summary")], [Gui.text_s(body.signal().map(|text| Document.counts_text(Document.counts(text))))]),
							Gui.panel([Gui.test_id("note-status")], [Gui.text_s(view.map(Session.status))]),
						],
					),
					Gui.panel(
						[Gui.test_id("note-problem")],
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
						|| Gui.panel(
							[
								Gui.test_id("discard-confirmation"),
								Gui.style({ ..Gui.style_default, padding: 16, gap: 8, background: Rgb(3354153), radius: 6 }),
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
													Session.Phase.ConfirmDiscard(Session.Destination.NewDocument) => Ui.update_states([session.write(Session.initial), body.write("")])
													Session.Phase.ConfirmDiscard(Session.Destination.OpenDocument) => session.set_cmd({ ..state, phase: Session.Phase.ChoosingOpen })
													Session.Phase.ConfirmDiscard(Session.Destination.RevertDocument) => Ui.update_states([session.write(Session.cancel(state)), body.write(state.baseline.body)])
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
				].concat(Workflow.bindings(session, body, tasks)),
			)
		},
	),
)
