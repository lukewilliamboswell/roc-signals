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
				{ test_id: "row-${key}", selected: Signal.select(selected.signal(), key), width: Fill, padding: 12, gap: 8, border_width: 1, radius: 8, background: Rgb(0x283A47), border_color: Rgb(0x4A6272) },
				[
					Gui.row(
						{ gap: 12 },
						[
							Gui.button("Select ${key}", selected.on_unit(|_| key)),
							Gui.column(
								{ padding: 6, font_size: 13, foreground: Rgb(0xA9BFCC) },
								[
									Gui.text_s(
										Signal.select(selected.signal(), key).map(
											|yes| if yes {
												"Selected"
											} else {
												""
											},
										),
									),
								],
							),
						],
					),
					Gui.text_input({ label: "Draft ${key}", value: draft.signal(), placeholder: "Type a draft…", width: Px(240), gap: 4 }, draft.on_str(|_, value| value)),
					Gui.column(
						{ font_size: 13, foreground: Rgb(0x93A9B6) },
						[Gui.text_s(draft.signal().map(|text| "Saved draft: ${text}"))],
					),
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
							{ padding: 32, gap: 16, width: Fill },
							[
								Gui.heading("Roc Signals + GPUI"),
								Gui.column(
									{ foreground: Rgb(0xA9BFCC) },
									[Gui.text("Edit a row, then move it. Hide/show creates fresh row scopes.")],
								),
								Gui.row(
									{ gap: 8 },
									[
										Gui.action_button(
											{
												caption: Signal.const("Move first to end"),
												padding: 8,
												radius: 6,
												background: Rgb(0x2E6FA3),
											},
											rows.on_unit(move_first),
										),
										Gui.button("Hide / show rows", visible.on_unit(|v| !v)),
									],
								),
								Ui.when(
									visible.signal(),
									|| {
										Gui.column(
											{ gap: 12, width: Px(520) },
											[
												Gui.column(
													{ font_size: 13, foreground: Rgb(0x93A9B6) },
													[Gui.text_s(Signal.interval(1000).map(|tick| "Scope clock: ${tick.to_str()}"))],
												),
												Ui.each(rows.signal(), |row| row_view(row, selected)),
											],
										)
									},
									|| Gui.column(
										{ font_size: 13, foreground: Rgb(0x93A9B6) },
										[Gui.text("Rows disposed")],
									),
								),
							],
						)
					},
				)
			},
		)
	},
)
