app [main] { roc: "nightly-2026-09-04-c125b82", pf: platform "../../platform-gui/main.roc" }

import pf.Elem exposing [Elem]
import pf.Gui
import pf.Rows
import pf.Signal
import pf.Ui

initial_rows : Rows.Rows(Str)
initial_rows = Rows.from_list(["Alpha", "Beta", "Gamma"], |key| key) ?? crash "duplicate spike key"

move_first : Rows.Rows(Str) -> Rows.Rows(Str)
move_first = |rows| Rows.apply(rows, [MoveRange({ from: 0, count: 1, to: 2 })]) ?? crash "invalid spike move"

row_view : Ui.Row(Str), Ui.State(Str) -> Elem
row_view = |row, selected| {
	key = row.key()
	Ui.state(
		"",
		|draft| {
			Gui.panel(
				[Gui.test_id("row-${key}"), Gui.style({ ..Gui.style_default, width: Fill, height: Px(170), padding: 12, border_width: 1, radius: 8 })],
				[
					Gui.button("Select ${key}", selected.on_unit(|_| key)),
					Gui.text_s(
						Signal.select(selected.signal(), key).map(
							|yes| if yes {
								"Selected"
							} else {
								""
							},
						),
					),
					Gui.text_input({ label: "Draft ${key}", value: draft.signal() }, [], draft.on_str(|_, value| value)),
					Gui.text_s(draft.signal().map(|text| "Saved draft: ${text}")),
				],
			)
		},
	)
}

main : () -> Elem
main = || Ui.state(
	initial_rows,
	|rows| {
		Ui.state(
			"Alpha",
			|selected| {
				Ui.state(
					True,
					|visible| {
						Gui.column(
							[Gui.style({ ..Gui.style_default, padding: 24 })],
							[
								Gui.heading("Roc Signals + GPUI"),
								Gui.text("Edit a row, then move it. Hide/show creates fresh row scopes."),
								Gui.button("Move first to end", rows.on_unit(move_first)),
								Gui.button("Hide / show rows", visible.on_unit(|v| !v)),
								Ui.when(
									visible.signal(),
									|| {
										Gui.column(
											[],
											[
												Gui.text_s(Signal.interval(1000).map(|tick| "Scope clock: ${tick.to_str()}")),
												Ui.each(rows.signal(), |row| row_view(row, selected)),
											],
										)
									},
									|| Gui.text("Rows disposed"),
								),
							],
						)
					},
				)
			},
		)
	},
)
