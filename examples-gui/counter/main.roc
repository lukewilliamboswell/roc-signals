app [main] { roc: "nightly-2026-09-04-c125b82", pf: platform "../../platform-gui/main.roc" }

import pf.Elem exposing [Elem]
import pf.Gui
import pf.Signal
import pf.Ui
import Theme

# The theme is data: swap the import for "theme-high-contrast.json" (keeping
# `as theme_json`) to rebuild the whole app in the alternate palette.
import "theme.json" as theme_json : Str

## Parsed while the compiler evaluates top-level definitions, so a bad
## theme.json fails `roc build` with a message naming the file and key.
theme : Theme.Palette
theme = Theme.from_json("examples-gui/counter/theme.json", theme_json)

accent_button : Str, Gui.Msg -> Elem
accent_button = |label, message| Gui.action_button(
	{ label: Signal.const(label), enabled: Signal.const(True) },
	[Gui.style({ ..Gui.style_default, padding: theme.control_padding, radius: theme.radius, background: Rgb(theme.accent) })],
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
					[Gui.style({ ..Gui.style_default, foreground: Rgb(theme.text_secondary) })],
					[Gui.text("A minimal Roc Signals application.")],
				),
				Gui.panel(
					[Gui.style({ ..Gui.style_default, width: Px(380), padding: 24, gap: 20, border_width: 1, radius: 10, border_color: Rgb(theme.border), background: Rgb(theme.surface) })],
					[
						Gui.column(
							[Gui.test_id("count"), Gui.style({ ..Gui.style_default, font_size: 44, foreground: Rgb(theme.text_primary) })],
							[Gui.text_s(count.signal().map(|value| value.to_str()))],
						),
						Gui.row(
							[Gui.style({ ..Gui.style_default, gap: theme.gap })],
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
