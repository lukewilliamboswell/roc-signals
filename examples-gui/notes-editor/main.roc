app [main] { pf: platform "../../platform-gui/main.roc" }

import pf.Elem exposing [Elem]
import pf.Gui
import pf.Signal
import pf.Ui
import Document

main : () -> Elem
main = || Ui.state(
	Document.blank.title,
	|title| {
		Ui.state(
			Document.blank.body,
			|body| {
				Ui.state(
					False,
					|confirm_discard| {
						draft = { title: title.signal(), body: body.signal() }.Signal
						dirty = draft.map(|value| Document.is_dirty({ draft: value, baseline: Document.blank }))
						counts = body.signal().map(Document.counts)

						Gui.column([], [
							Gui.heading("Notes"),
							Gui.text("A quiet place to collect your thoughts."),
							Gui.text_input({ label: "Document title", value: title.signal() }, [], title.on_str(|_, value| value)),
							Gui.textarea({ label: "Note text", value: body.signal() }, [], body.on_str(|_, value| value)),
							Gui.panel([Gui.test_id("note-summary")], [Gui.text_s(counts.map(Document.counts_text))]),
							Gui.panel(
								[Gui.test_id("note-status")],
								[
									Gui.text_s(
										dirty.map(
											|changed| if changed {
												"Unsaved changes"
											} else {
												"No changes"
											},
										),
									),
								],
							),
							Gui.button("Revert changes", Ui.action(dirty, |changed| confirm_discard.set_cmd(changed))),
							Ui.when(
								confirm_discard.signal(),
								|| Gui.panel(
									[Gui.test_id("discard-confirmation")],
									[
										Gui.text("Discard your changes?"),
										Gui.text("The title and note text will return to the starting document."),
										Gui.button("Keep editing", confirm_discard.on_unit(|_| False)),
										Gui.button(
											"Discard changes",
											Ui.action(
												Signal.const({}),
												|_| Ui.update_states([
													title.write(Document.blank.title),
													body.write(Document.blank.body),
													confirm_discard.write(False),
												]),
											),
										),
									],
								),
								|| Gui.text(""),
							),
						])
					},
				)
			},
		)
	},
)
