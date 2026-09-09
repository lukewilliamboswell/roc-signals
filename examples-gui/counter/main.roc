app [main] { roc: "nightly-2026-09-04-c125b82", pf: platform "../../platform-gui/main.roc" }

import pf.Elem exposing [Elem]
import pf.Gui
import pf.Signal
import pf.Ui

accent_button : Str, Gui.Msg -> Elem
accent_button = |label, message| Gui.action_button(
	{ label: Signal.const(label), enabled: Signal.const(True) },
	[Gui.style({ ..Gui.style_default, padding: 10, radius: 6, background: Rgb(0x2E6FA3) })],
	message,
)

main : () -> Elem
main = || Ui.state(
	0.I64,
	|count| {
		Gui.column(
			[Gui.style({ ..Gui.style_default, padding: 32, gap: 20 })],
			[
				Gui.heading("Counter"),
				Gui.column(
					[Gui.style({ ..Gui.style_default, foreground: Rgb(0xA9BFCC) })],
					[Gui.text("A minimal Roc Signals application.")],
				),
				Gui.panel(
					[Gui.style({ ..Gui.style_default, width: Px(380), padding: 24, gap: 20, border_width: 1, radius: 10, border_color: Rgb(0x3A4F5C), background: Rgb(0x1B2A33) })],
					[
						Gui.column(
							[Gui.test_id("count"), Gui.style({ ..Gui.style_default, font_size: 44, foreground: Rgb(0xF2F5F6) })],
							[Gui.text_s(count.signal().map(|value| value.to_str()))],
						),
						Gui.row(
							[Gui.style({ ..Gui.style_default, gap: 8 })],
							[
								accent_button("Increment", count.on_unit(|value| value + 1)),
								Gui.button("Decrement", count.on_unit(|value| value - 1)),
								Gui.button("Reset", count.on_unit(|_| 0)),
							],
						),
					],
				),
			],
		)
	},
)
