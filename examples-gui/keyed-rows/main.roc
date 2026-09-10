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
				[Gui.test_id("row-${key}"), Gui.selected_s(Signal.select(selected.signal(), key)), Gui.style({ width: Fill, padding: 12, gap: 8, border_width: 1, radius: 8, background: Rgb(0x283A47), border_color: Rgb(0x4A6272) })],
				[
					Gui.row(
						[Gui.style({ gap: 12 })],
						[
							Gui.button("Select ${key}", selected.on_unit(|_| key)),
							Gui.column(
								[Gui.style({ padding: 6, font_size: 13, foreground: Rgb(0xA9BFCC) })],
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
					Gui.text_input({ label: "Draft ${key}", value: draft.signal() }, [Gui.placeholder("Type a draft…"), Gui.style({ width: Px(240), gap: 4 })], draft.on_str(|_, value| value)),
					Gui.column(
						[Gui.style({ font_size: 13, foreground: Rgb(0x93A9B6) })],
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
							[Gui.style({ padding: 16, gap: 12, width: Fill })],
							[
								Ui.on_change_initial(Signal.const("Keyed Rows - Roc Signals"), Gui.set_title),
								Gui.heading("Roc Signals + GPUI"),
								Gui.column(
									[Gui.style({ foreground: Rgb(0xA9BFCC) })],
									[Gui.text("Edit a row, then move it. Hide/show creates fresh row scopes.")],
								),
								Gui.row(
									[Gui.style({ gap: 8 })],
									[
										Gui.action_button(
											{ label: Signal.const("Move first to end"), enabled: Signal.const(True) },
											[Gui.style({ padding: 8, radius: 6, background: Rgb(0x2E6FA3) })],
											rows.on_unit(move_first),
										),
										Gui.button("Hide / show rows", visible.on_unit(|v| !v)),
									],
								),
								Ui.when(
									visible.signal(),
									|| {
										Gui.column(
											# Grow into the available width instead of pinning 520 pixels, which is
											# wider than the smallest window the host allows.
											[Gui.style({ gap: 12, width: Fill })],
											[
												Gui.column(
													[Gui.style({ font_size: 13, foreground: Rgb(0x93A9B6) })],
													[Gui.text_s(Signal.interval(1000).map(|tick| "Scope clock: ${tick.to_str()}"))],
												),
												Ui.each(rows.signal(), |row| row_view(row, selected)),
											],
										)
									},
									|| Gui.column(
										[Gui.style({ font_size: 13, foreground: Rgb(0x93A9B6) })],
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
