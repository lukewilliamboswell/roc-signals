app [main] { roc: "nightly-2026-09-04-c125b82", pf: platform "../../platform-gui/main.roc" }

import pf.Elem exposing [Elem]
import pf.Event
import pf.Gui exposing [Px]
import pf.Signal
import pf.Ui
import Theme

# The theme is data: swap the import for "theme-high-contrast.json" (keeping
# `as theme_json`) to rebuild this example in the alternate palette. Every
# surface, border, text colour, radius, padding and gap the Counter draws comes
# from the file below. It does not cover the palette's status colours (danger,
# warning, success) or `text_tertiary`, which a counter has nothing to say
# with, and it cannot cover focus rings, scrollbars or the modal scrim, which
# the host owns and styles for accessibility.
import "theme.json" as theme_json : Str

## Parsed while the compiler evaluates top-level definitions, so a bad
## theme.json fails `roc build` with a message naming the file and key.
theme : Theme.Palette
theme = Theme.from_json("examples-gui/counter/theme.json", theme_json)

accent_button : Str, Event.Handler -> Elem
accent_button = |label, message| Elem.action_button(
	{
		caption: Signal.const(label),
		test_id: label,
		padding: theme.control_padding,
		radius: theme.radius,
		fg: theme.text_primary,
		bg: theme.accent,
		hover_bg: theme.accent_hover,
		active_bg: theme.accent_active,
	},
	message,
)

## The quiet actions. They read from the same palette as the accent button
## rather than falling back to the host's default control colours, which is
## what makes swapping the file rebuild the whole example.
secondary_button : Str, Event.Handler -> Elem
secondary_button = |label, message| Elem.action_button(
	{
		caption: Signal.const(label),
		test_id: label,
		padding: theme.control_padding,
		radius: theme.radius,
		border_width: 1,
		border_color: theme.border,
		fg: theme.text_primary,
		bg: theme.surface,
		hover_bg: theme.card,
		active_bg: theme.background,
	},
	message,
)

main : () -> Elem
main = || Ui.state(
	0.I64,
	|count| {
		Elem.col(
			{ padding: 16, gap: 12, width: Fill, height: Fill, bg: theme.background, fg: theme.text_primary },
			[
				Ui.on_change_initial(Signal.const("Counter - Roc Signals"), Gui.set_title),
				Elem.heading("Counter"),
				Elem.col(
					{ fg: theme.text_secondary },
					["A minimal Roc Signals application."],
				),
				# The panel takes the width of its own contents. A pinned width
				# wider than the smallest window the host allows would put it off
				# the edge; letting it stretch would leave a teaching example as
				# one band across a wide window. The trailing column absorbs the
				# remaining width instead.
				Elem.row(
					{ width: Fill, gap: 0 },
					[
						Elem.panel(
							{
								padding: 16,
								gap: 12,
								border_width: 1,
								radius: theme.radius,
								border_color: theme.border,
								bg: theme.card,
							},
							[
								Elem.col(
									{ test_id: "count", font_size: 32, fg: theme.text_primary },
									[Elem.text_s(count.read(|value| value.to_str()))],
								),
								Elem.row(
									{ gap: theme.gap },
									[
										accent_button("Increment", count.update(|value| value + 1)),
										secondary_button("Decrement", count.update(|value| value - 1)),
										secondary_button("Reset", count.update(|_| 0)),
									],
								),
							],
						),
						Elem.col({ grow: True }, []),
					],
				),
			],
		)
	},
)
