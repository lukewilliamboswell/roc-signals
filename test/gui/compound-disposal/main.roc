app [main] { pf: platform "../../../platform-gui/main.roc" }
import pf.Elem exposing [Elem]
import pf.Gui
import pf.Rows
import pf.Ui

main : () -> Elem
main = || Ui.state(
	Rows.from_list(["a", "b"], |item| item) ?? crash "unique",
	|rows|
		Ui.state(
			True,
			|editing|
				Ui.state(
					True,
					|confirm| Gui.column(
						Gui.ColumnProps.{},
						[
							Gui.button("Add", Ui.action(rows.signal(), |current| Ui.update_states([rows.write(Rows.apply(current, [Append(["c"])]) ?? crash "unique"), editing.write(True), confirm.write(True)]))),
							Gui.button(
								"Delete",
								Ui.action(
									rows.signal(),
									|current| Ui.update_states([
										rows.write(Rows.apply(current, [RemoveKey("c")]) ?? crash "exists"),
										editing.write(False),
										confirm.write(False),
									]),
								),
							),
							Gui.button("Empty list", rows.on_unit(|current| Rows.replace_all(current, []) ?? crash "unique")),
							Gui.button("Restore list", rows.on_unit(|current| Rows.replace_all(current, ["a", "b"]) ?? crash "unique")),
							Gui.column({ test_id: "rows" }, [Ui.each(rows.signal(), |row| Gui.text_s(row.signal()))]),
							Ui.when(
								editing.signal(),
								|| Gui.column(
									Gui.ColumnProps.{},
									[
										"Detail",
										Ui.when(confirm.signal(), || Gui.text("Confirm"), || Gui.text("Editing")),
									],
								),
								|| Gui.text("Closed"),
							),
						],
					),
				),
		),
)
