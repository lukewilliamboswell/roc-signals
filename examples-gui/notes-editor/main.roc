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
	|session| {
		tasks = Workflow.create_tasks()
		state = session.signal()
		# Derived through the body alone so counting and the controlled editor
		# value stay proportional to text edits, not to every session change.
		body = state.map(|value| value.body)
		ready = state.map(Session.can_start)
		phase = state.map(|value| value.phase)
		dirty = state.map(|value| Document.is_dirty({ draft: Session.draft(value), baseline: value.baseline }))
		revert_ready = Signal.map2(ready, dirty, |can_start, changed| can_start and changed)
		save = session.on_unit(|value| Session.begin_save({ state: value, save_as: False }))
		save_as = session.on_unit(|value| Session.begin_save({ state: value, save_as: True }))
		open = session.on_unit(Session.begin_open)
		new = Ui.action(
			state,
			|value| {
				if !Session.can_start(value) {
					Signal.noop
				}
					else if Document.is_dirty({ draft: Session.draft(value), baseline: value.baseline }) {
						session.set_cmd({ ..value, phase: Session.Phase.ConfirmDiscard(Session.Destination.NewDocument), problem: None })
					} else {
						session.set_cmd(Session.new_document(value))
					}
			},
		)
		revert = Ui.action(
			state,
			|value| {
				if Session.can_start(value) and Document.is_dirty({ draft: Session.draft(value), baseline: value.baseline }) {
					session.set_cmd({ ..value, phase: Session.Phase.ConfirmDiscard(Session.Destination.RevertDocument), problem: None })
				} else {
					Signal.noop
				}
			},
		)
		cancel = Ui.action(phase, |value| Workflow.cancel(session, tasks, value))
		chord = { key: "s", control: True, shift: False, alt: False, meta: False }
		Gui.window_lifecycle(
			{ on_close_requested: session.on_unit(Session.request_close), decision: state.map(Session.close_decision) },
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
								Gui.action_button({ label: Signal.const("Save"), enabled: revert_ready }, [Gui.style({ ..Gui.style_default, padding: theme.control_padding, radius: theme.radius, background: Rgb(theme.accent), hover_background: Rgb(theme.accent_hover), active_background: Rgb(theme.accent_active) })], save),
								Gui.action_button({ label: Signal.const("Save As…"), enabled: ready }, [], save_as),
								Gui.action_button({ label: Signal.const("Revert changes"), enabled: revert_ready }, [], revert),
							],
						),
						Gui.row(
							[Gui.style({ ..Gui.style_default, gap: 12 })],
							[
								Gui.column(
									[Gui.test_id("document-name"), Gui.style({ ..Gui.style_default, font_size: 18, foreground: Rgb(theme.text_primary) })],
									[Gui.text_s(state.map(|value| value.baseline.title))],
								),
								Gui.column(
									[
										Gui.test_id("note-status"),
										Gui.style_s(
											dirty.map(
												|changed| {
													..Gui.style_default,
													padding: 4,
													font_size: 13,
													foreground: if changed {
														Rgb(theme.warning)
													} else {
														Rgb(theme.text_secondary)
													},
												},
											),
										),
									],
									[Gui.text_s(state.map(Session.status))],
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
										# The editor's identity is this document's lifetime. Typing, saving,
										# and the temporary disabled state never change it; every accepted
										# document replacement does, including one with equal text.
										Ui.switch(
											state.map(|value| value.document_generation),
											|_| Gui.textarea(
												{ label: "Note text", value: body },
												[
													Gui.placeholder("Start writing…"),
													Gui.disabled_s(state.map(|value| !Session.can_edit(value.phase) or value.close != Session.CloseState.NoClose)),
													Gui.style({ ..Gui.style_default, width: Fill, height: Fill, grow: True, gap: 4 }),
												],
												session.on_str(Session.edit),
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
									[Gui.text_s(body.map(|text| Document.counts_text(Document.counts(text))))],
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
											state.map(
												|value| match value.problem {
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
															state,
															|value| match value.phase {
																Session.Phase.ConfirmDiscard(Session.Destination.NewDocument) => session.set_cmd(Session.new_document(value))
																Session.Phase.ConfirmDiscard(Session.Destination.OpenDocument) => session.set_cmd({ ..value, phase: Session.Phase.ChoosingOpen })
																Session.Phase.ConfirmDiscard(Session.Destination.RevertDocument) => session.set_cmd(Session.revert(value))
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
									state.map(|value| value.close == Session.CloseState.ConfirmClose),
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
													Gui.button("Discard and close", session.on_unit(|value| { ..value, close: Session.CloseState.AllowClose })),
													Gui.button("Save and close", session.on_unit(Session.save_and_close)),
												],
											),
										],
									),
									|| Gui.text(""),
								),
							],
						),
					].concat(Workflow.bindings(session, tasks)),
				),
			],
		)
	},
)
