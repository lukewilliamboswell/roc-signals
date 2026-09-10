app [main] { roc: "nightly-2026-09-04-c125b82", pf: platform "../../platform-gui/main.roc" }

import pf.Elem exposing [Elem]
import pf.Gui
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

accent_button : Str, Gui.Msg -> Elem
accent_button = |label, message| Gui.action_button(
	{ label: Signal.const(label), enabled: Signal.const(True) },
	[Gui.test_id(label), Gui.style({ ..Gui.style_default, padding: theme.control_padding, radius: theme.radius, foreground: Rgb(theme.text_primary), background: Rgb(theme.accent), hover_background: Rgb(theme.accent_hover), active_background: Rgb(theme.accent_active) })],
	message,
)

## The quiet actions. They read from the same palette as the accent button
## rather than falling back to the host's default control colours, which is
## what makes swapping the file rebuild the whole example.
secondary_button : Str, Gui.Msg -> Elem
secondary_button = |label, message| Gui.action_button(
	{ label: Signal.const(label), enabled: Signal.const(True) },
	[Gui.test_id(label), Gui.style({ ..Gui.style_default, padding: theme.control_padding, radius: theme.radius, border_width: 1, border_color: Rgb(theme.border), foreground: Rgb(theme.text_primary), background: Rgb(theme.surface), hover_background: Rgb(theme.card), active_background: Rgb(theme.background) })],
	message,
)

main : () -> Elem
main = || Ui.state(
	0.I64,
	|count| {
		Gui.column(
			[Gui.style({ ..Gui.style_default, padding: 16, gap: 12, width: Fill, height: Fill, background: Rgb(theme.background), foreground: Rgb(theme.text_primary) })],
			[
				Ui.on_change_initial(Signal.const("Counter - Roc Signals"), Gui.set_title),
				Gui.heading("Counter"),
				Gui.column(
					[Gui.style({ ..Gui.style_default, foreground: Rgb(theme.text_secondary) })],
					[Gui.text("A minimal Roc Signals application.")],
				),
				# The panel takes the width of its own contents. A pinned width
				# wider than the smallest window the host allows would put it off
				# the edge; letting it stretch would leave a teaching example as
				# one band across a wide window. The trailing column absorbs the
				# remaining width instead.
				Gui.row(
					[Gui.style({ ..Gui.style_default, width: Fill, gap: 0 })],
					[
						Gui.panel(
							[Gui.style({ ..Gui.style_default, padding: 16, gap: 12, border_width: 1, radius: theme.radius, border_color: Rgb(theme.border), background: Rgb(theme.card) })],
							[
								Gui.column(
									[Gui.test_id("count"), Gui.style({ ..Gui.style_default, font_size: 32, foreground: Rgb(theme.text_primary) })],
									[Gui.text_s(count.signal().map(|value| value.to_str()))],
								),
								Gui.row(
									[Gui.style({ ..Gui.style_default, gap: theme.gap })],
									[
										accent_button("Increment", count.on_unit(|value| value + 1)),
										secondary_button("Decrement", count.on_unit(|value| value - 1)),
										secondary_button("Reset", count.on_unit(|_| 0)),
									],
								),
							],
						),
						Gui.column([Gui.style({ ..Gui.style_default, grow: True })], []),
					],
				),
			],
		)
	},
)
