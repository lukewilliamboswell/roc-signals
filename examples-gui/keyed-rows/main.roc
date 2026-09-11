app [main] { roc: "nightly-2026-09-04-c125b82", pf: platform "../../platform-gui/main.roc" }

import pf.Elem exposing [Elem]
import pf.Gui exposing [Px]
import pf.Rows
import pf.Signal
import pf.Ui

initial_rows : Rows.Rows(Str)
initial_rows = Rows.from_list(["Alpha", "Beta", "Gamma"], |key| key) ?? crash "initial rows must have distinct keys"

move_first : Rows.Rows(Str) -> Rows.Rows(Str)
move_first = |rows| Rows.apply(rows, [MoveRange({ from: 0, count: 1, to: 2 })]) ?? crash "moving the first row must be a valid range"

row_view : Ui.Row(Str), Ui.State(Str) -> Elem
row_view = |row, selected| {
	key = row.key()
	Ui.state(
		"",
		|draft| {
			Elem.panel(
				{
					test_id: "row-${key}",
					selected: Signal.select(selected.signal(), key),
					width: Fill,
					padding: 12,
					gap: 8,
					border_width: 1,
					radius: 8,
					bg: Rgb(0x283A47),
					border_color: Rgb(0x4A6272),
				},
				[
					Elem.row(
						{ gap: 12 },
						[
							Elem.button("Select ${key}", selected.update(|_| key)),
							Elem.col(
								{ padding: 6, font_size: 13, fg: Rgb(0xA9BFCC) },
								[
									Elem.text_s(
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
					Elem.text_input({
						label: "Draft ${key}",
						value: draft.signal(),
						placeholder: "Type a draft…",
						width: 240.Px,
						gap: 4,
					}, draft.update_str(|_, value| value)),
					Elem.col(
						{ font_size: 13, fg: Rgb(0x93A9B6) },
						[Elem.text_s(draft.read(|text| "Saved draft: ${text}"))],
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
						Elem.col(
							{ padding: 16, gap: 12, width: Fill },
							[
								Ui.on_change_initial(Signal.const("Keyed Rows - Roc Signals"), Gui.set_title),
								Elem.heading("Roc Signals + GPUI"),
								Elem.col(
									{ fg: Rgb(0xA9BFCC) },
									["Edit a row, then move it. Hide/show creates fresh row scopes."],
								),
								Elem.row(
									{ gap: 8 },
									[
										Elem.action_button(
											{
												caption: Signal.const("Move first to end"),
												padding: 8,
												radius: 6,
												bg: Rgb(0x2E6FA3),
											},
											rows.update(move_first),
										),
										Elem.button("Hide / show rows", visible.update(|v| !v)),
									],
								),
								Ui.when(
									visible.signal(),
									|| {
										Elem.col(
											# Grow into the available width instead of pinning 520 pixels, which is
											# wider than the smallest window the host allows.
											{ gap: 12, width: Fill },
											[
												Elem.col(
													{ font_size: 13, fg: Rgb(0x93A9B6) },
													[Elem.text_s(Signal.interval(1000).map(|tick| "Scope clock: ${tick.to_str()}"))],
												),
												Ui.each(rows.signal(), |row| row_view(row, selected)),
											],
										)
									},
									|| Elem.col(
										{ font_size: 13, fg: Rgb(0x93A9B6) },
										["Rows disposed"],
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
