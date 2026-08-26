app [main] { pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.1/3eLQGNMDG9RuL9sn1A7ep1Rtq7QGmemE89y141WSv1XG.tar.zst" }

import Tokens
import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

page_class = "grid gap-5"

hero_class = "panel grid gap-2 p-5"

panel_class = "panel grid gap-3 p-4"

row_class = "grid gap-1 rounded border border-zinc-200 p-3"

input_class = "w-full max-w-xs rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm"

heading_class = "text-lg font-semibold text-zinc-950"

value_class = "text-sm text-zinc-700"

code_class = "overflow-x-auto rounded bg-zinc-900 p-3 text-xs text-zinc-50"

## The six source tokens, already parsed. This is the fan-in point that the
## preview list and the validation panel both hang off.
Design : {
	bg : Tokens.Colour,
	fg : Tokens.Colour,
	accent : Tokens.Colour,
	space : Tokens.Size,
	font : Tokens.Size,
}

## Resolve the tokens into the three preview components. `id` is the keyed-row
## identity, so a token edit patches row text instead of recreating rows.
build_previews : Design -> List(Tokens.Preview)
build_previews = |design| {
	pad = Tokens.size_css(design.space)
	size = Tokens.size_css(design.font)
	bg = Tokens.colour_css(design.bg)
	fg = Tokens.colour_css(design.fg)
	accent = Tokens.colour_css(design.accent)

	[
		{ id: "surface", fg: fg, bg: bg, pad: pad, size: size },
		{ id: "button", fg: bg, bg: accent, pad: pad, size: size },
		{ id: "badge", fg: bg, bg: fg, pad: pad, size: size },
	]
}

render_preview : Str, Signal.Signal(Tokens.Preview) -> Elem
render_preview = |key, preview|
	Html.section(
		"Preview ${key}",
		[Html.class_attr(row_class)],
		[
			Html.paragraph_c(key, "text-sm font-medium text-zinc-950"),
			Html.paragraph_s_attrs(
				preview.map(Tokens.preview_style),
				[Html.class_attr(value_class), Html.test_id("preview-${key}")],
			),
		],
	)

pair_line : Str, Str, Signal.Signal(Tokens.Contrast) -> Elem
pair_line = |id, label, pair|
	Html.section(
		label,
		[Html.class_attr(row_class)],
		[
			Html.paragraph_c(label, "text-sm font-medium text-zinc-950"),
			Html.paragraph_s_attrs(
				pair.map(Tokens.format_ratio),
				[Html.class_attr(value_class), Html.test_id("ratio-${id}")],
			),
			Html.paragraph_s_attrs(
				pair.map(|value| if Tokens.passes_aa(value) { "AA pass" } else { "AA fail" }),
				[Html.class_attr(value_class), Html.test_id("aa-${id}")],
			),
		],
	)

token_field : Str, Ui.State(Str), Str -> Elem
token_field = |label, state, css_name|
	Html.section(
		"Token ${css_name}",
		[Html.class_attr(row_class)],
		[
			Html.text_input_c(label, state.signal(), input_class, state.on_str(|_, value| value)),
			Html.paragraph_c("var(--${css_name})", "text-xs text-zinc-500"),
		],
	)

## Two independent booleans feeding one rollup.
aa_summary : Bool, Bool -> Str
aa_summary = |text_ok, button_ok| {
	passing : U64
	passing = (if text_ok { 1 } else { 0 }) + (if button_ok { 1 } else { 0 })
	"${passing.to_str()} of 2 pairs pass AA"
}

validity_summary : Design, Tokens.Size -> Str
validity_summary = |design, radius| {
	flags = [
		{ name: "color-bg", ok: design.bg.ok },
		{ name: "color-fg", ok: design.fg.ok },
		{ name: "color-accent", ok: design.accent.ok },
		{ name: "space-sm", ok: design.space.ok },
		{ name: "font-md", ok: design.font.ok },
		{ name: "radius-md", ok: radius.ok },
	]
	broken = flags.keep_if(|flag| !flag.ok).map(|flag| flag.name)
	if broken.is_empty() {
		"All 6 tokens valid"
	} else {
		"Invalid tokens: ${Str.join_with(broken, ", ")}"
	}
}

editor : Ui.State(Str), Ui.State(Str), Ui.State(Str), Ui.State(Str), Ui.State(Str), Ui.State(Str) -> Elem
editor = |bg, fg, accent, space, font, radius| {
	# Hop 1: raw draft text -> parsed token.
	bg_colour = bg.signal().map(Tokens.parse_colour)
	fg_colour = fg.signal().map(Tokens.parse_colour)
	accent_colour = accent.signal().map(Tokens.parse_colour)
	space_size = space.signal().map(Tokens.parse_size)
	font_size = font.signal().map(Tokens.parse_size)
	radius_size = radius.signal().map(Tokens.parse_size)

	# Hop 2: five parsed tokens fan in to one design record...
	design : Signal.Signal(Design)
	design =
		{
			bg: bg_colour,
			fg: fg_colour,
			accent: accent_colour,
			space: space_size,
			font: font_size,
		}.Signal

	# ...and hop 3 resolves that into the keyed preview rows.
	previews = design.map(build_previews)

	# Independent chain: parsed colour -> luminance -> pairwise contrast ->
	# AA flag -> rollup. Five hops, and the two pair signals are genuine
	# two-input fan-ins over independently created luminance signals.
	bg_luminance = bg_colour.map(Tokens.luminance)
	fg_luminance = fg_colour.map(Tokens.luminance)
	accent_luminance = accent_colour.map(Tokens.luminance)

	text_pair = Signal.map2(fg_luminance, bg_luminance, Tokens.contrast)
	button_pair = Signal.map2(bg_luminance, accent_luminance, Tokens.contrast)

	text_passes = text_pair.map(Tokens.passes_aa)
	button_passes = button_pair.map(Tokens.passes_aa)
	summary = Signal.map2(text_passes, button_passes, aa_summary)

	validity = Signal.map2(design, radius_size, validity_summary)

	# Wide fan-in: six independently created declaration signals combined into
	# one stylesheet. `radius-md` is in here and nowhere else, so editing it
	# moves the export without touching a preview row.
	declarations =
		Signal.combine(
			[
				bg_colour.map(|value| Tokens.css_declaration("color-bg", Tokens.colour_css(value))),
				fg_colour.map(|value| Tokens.css_declaration("color-fg", Tokens.colour_css(value))),
				accent_colour.map(|value| Tokens.css_declaration("color-accent", Tokens.colour_css(value))),
				space_size.map(|value| Tokens.css_declaration("space-sm", Tokens.size_css(value))),
				font_size.map(|value| Tokens.css_declaration("font-md", Tokens.size_css(value))),
				radius_size.map(|value| Tokens.css_declaration("radius-md", Tokens.size_css(value))),
			],
		)
	stylesheet = declarations.map(Tokens.css_block)

	Html.div_c(
		page_class,
		[
			Html.section_c(
				"Design Token Editor",
				hero_class,
				[
					Html.heading_c("Design Token Editor", "text-3xl font-semibold text-zinc-950"),
					Html.paragraph_c(
						"Edit the design tokens; every preview component, the WCAG AA contrast checks, and the generated stylesheet are derived, never stored.",
						"max-w-3xl text-sm text-zinc-700",
					),
				],
			),
			Html.section_c(
				"Tokens",
				panel_class,
				[
					Html.heading_c("Tokens", heading_class),
					token_field("Background colour", bg, "color-bg"),
					token_field("Text colour", fg, "color-fg"),
					token_field("Accent colour", accent, "color-accent"),
					token_field("Spacing small", space, "space-sm"),
					token_field("Font size medium", font, "font-md"),
					token_field("Corner radius medium", radius, "radius-md"),
					Html.paragraph_s_attrs(validity, [Html.class_attr(value_class), Html.test_id("token-validity")]),
				],
			),
			Html.section_c(
				"Preview",
				panel_class,
				[
					Html.heading_c("Preview", heading_class),
					Ui.each_str(previews, |preview| preview.id, render_preview),
				],
			),
			Html.section_c(
				"Contrast validation",
				panel_class,
				[
					Html.heading_c("Contrast validation", heading_class),
					pair_line("text", "Text on background", text_pair),
					pair_line("button", "Button label on accent", button_pair),
					Html.paragraph_s_attrs(summary, [Html.class_attr(value_class), Html.test_id("aa-summary")]),
				],
			),
			Html.section_c(
				"CSS export",
				panel_class,
				[
					Html.heading_c("CSS export", heading_class),
					Html.div(
						[Html.test_id("stylesheet")],
						[Html.pre_s_c(stylesheet, code_class)],
					),
					Html.paragraph_c("Unreferenced by any preview: --radius-md", "text-xs text-zinc-500"),
				],
			),
		],
	)
}

main : () -> Elem
main = ||
	Ui.state(
		"#ffffff",
		|bg|
			Ui.state(
				"#767676",
				|fg|
					Ui.state(
						"#2563eb",
						|accent|
							Ui.state(
								"8",
								|space|
									Ui.state(
										"16",
										|font|
											Ui.state(
												"4",
												|radius| editor(bg, fg, accent, space, font, radius),
											),
									),
							),
					),
			),
	)
