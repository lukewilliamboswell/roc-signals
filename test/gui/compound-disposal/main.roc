app [main] { pf: platform "../../../platform-gui/main.roc" }
import pf.Action exposing [Action]
import pf.Elem exposing [Elem]
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
					|confirm| Elem.col(
						Elem.ColProps.{},
						[
							Elem.button("Add", Action.run(rows.signal(), |current| Action.update([rows.set(Rows.apply(current, [Append(["c"])]) ?? crash "unique"), editing.set(True), confirm.set(True)]))),
							Elem.button(
								"Delete",
								Action.run(
									rows.signal(),
									|current| Action.update([
										rows.set(Rows.apply(current, [RemoveKey("c")]) ?? crash "exists"),
										editing.set(False),
										confirm.set(False),
									]),
								),
							),
							Elem.button("Empty list", rows.update(|current| Rows.replace_all(current, []) ?? crash "unique")),
							Elem.button("Restore list", rows.update(|current| Rows.replace_all(current, ["a", "b"]) ?? crash "unique")),
							Elem.col({ test_id: "rows" }, [Ui.each(rows.signal(), |row| Elem.text_s(row.signal()))]),
							Ui.when(
								editing.signal(),
								|| Elem.col(
									Elem.ColProps.{},
									[
										"Detail",
										Ui.when(confirm.signal(), || Elem.text("Confirm"), || Elem.text("Editing")),
									],
								),
								|| Elem.text("Closed"),
							),
						],
					),
				),
		),
)
