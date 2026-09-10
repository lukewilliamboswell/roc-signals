app [main] { roc: "nightly-2026-09-04-c125b82", pf: platform "../../platform-gui/main.roc" }

import pf.Elem exposing [Elem]
import pf.Event
import pf.Gui exposing [Px]
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

accent_button : Str, Event.Handler -> Elem
accent_button = |label, message| Elem.action_button(
	{
		caption: Signal.const(label),
		padding: theme.control_padding,
		radius: theme.radius,
		bg: theme.accent,
		hover_bg: theme.accent_hover,
		active_bg: theme.accent_active,
	},
	message,
)

main : () -> Elem
main = || Ui.state(
	0.I64,
	|count| {
		Elem.col(
			{ padding: 32, gap: 20 },
			[
				Elem.heading("Counter"),
				Elem.col(
					{ fg: theme.text_secondary },
					["A minimal Roc Signals application."],
				),
				Elem.panel(
					{
						width: 380.Px,
						padding: 24,
						gap: 20,
						border_width: 1,
						radius: 10,
						border_color: theme.border,
						bg: theme.surface,
					},
					[
						Elem.col(
							{ test_id: "count", font_size: 44, fg: theme.text_primary },
							[Elem.text_s(count.read(|value| value.to_str()))],
						),
						Elem.row(
							{ gap: theme.gap },
							[
								accent_button("Increment", count.update(|value| value + 1)),
								Elem.button("Decrement", count.update(|value| value - 1)),
								Elem.button("Reset", count.update(|_| 0)),
							],
						),
					],
				),
			],
		)
	},
)
