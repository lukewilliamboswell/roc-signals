app [main] { pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.1/3eLQGNMDG9RuL9sn1A7ep1Rtq7QGmemE89y141WSv1XG.tar.zst" }

import Tokens
import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

page_class = "app-shell"

panel_class = "panel grid gap-4 p-5"

token_row_class = "grid gap-2 rounded-lg border border-zinc-200 bg-white p-3"

input_class = "input"

## Resolved token text is monospace so the hex digits line up down the column.
mono_class = "numeric font-mono text-xs font-medium text-zinc-700"

code_class = "overflow-x-auto rounded-md bg-zinc-900 p-4 text-xs leading-5 text-zinc-50"

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

preview_caption : Str -> Str
preview_caption = |key|
	if key == "button" {
		"Primary button — background on accent"
	} else if key == "badge" {
		"Badge — background on text colour"
	} else {
		"Surface card — text on background"
	}

## The three keyed rows are the miniature product screen. Each one is painted
## with the resolved tokens through a `style` attribute, because an arbitrary
## runtime colour cannot be expressed as a Tailwind class: the derived value has
## to reach the DOM as real paint, not as a caption describing the paint.
render_preview : Str, Signal.Signal(Tokens.Preview) -> Elem
render_preview = |key, preview| {
	style = preview.map(Tokens.preview_style)

	Html.section(
		"Preview ${key}",
		[Html.class_attr("grid gap-1.5")],
		[
			Html.paragraph_c(preview_caption(key), "hint"),
			if key == "surface" {
				Html.div(
					[
						Html.test_id("preview-surface"),
						Html.attr_s("style", style),
						Html.class_attr("grid gap-2 rounded-lg border border-zinc-200 shadow-sm"),
					],
					[
						Html.paragraph_c("Order summary", "font-semibold leading-tight"),
						Html.paragraph_c(
							"Two items, arriving Thursday. The card ending 4242 is charged when the order ships.",
							"leading-6 opacity-90",
						),
					],
				)
			} else if key == "button" {
				Html.div(
					[
						Html.test_id("preview-button"),
						Html.attr_s("style", style),
						Html.class_attr("inline-flex w-fit items-center rounded-md font-medium shadow-sm"),
					],
					[Html.text("Place order")],
				)
			} else {
				Html.div(
					[
						Html.test_id("preview-badge"),
						Html.attr_s("style", style),
						Html.class_attr("inline-flex w-fit items-center rounded-full font-medium"),
					],
					[Html.text("New")],
				)
			},
		],
	)
}

## WCAG grades, in hundredths. AA is 4.50:1 for normal text, AAA is 7.00:1.
aaa_threshold : U64
aaa_threshold = 700

grade_label : Tokens.Contrast -> Str
grade_label = |value|
	if !value.ok {
		"Invalid"
	} else if value.ratio >= aaa_threshold {
		"AAA"
	} else if Tokens.passes_aa(value) {
		"AA"
	} else {
		"Fail"
	}

## The badge tone comes off the same contrast signal as the number beside it, so
## the grade can never disagree with the ratio it is grading.
grade_class : Tokens.Contrast -> Str
grade_class = |value|
	if !value.ok {
		"badge badge-neutral"
	} else if value.ratio >= aaa_threshold {
		"badge badge-ok"
	} else if Tokens.passes_aa(value) {
		"badge badge-ok"
	} else {
		"badge badge-danger"
	}

pair_line : Str, Str, Signal.Signal(Tokens.Contrast) -> Elem
pair_line = |id, label, pair|
	Html.section(
		label,
		[Html.class_attr("card gap-1.5")],
		[
			Html.div_c(
				"flex flex-wrap items-center justify-between gap-3",
				[
					Html.paragraph_c(label, "card-title"),
					Html.paragraph_s_attrs(
						pair.map(grade_label),
						[Html.test_id("aa-${id}"), Html.class_attr_s(pair.map(grade_class))],
					),
				],
			),
			Html.paragraph_s_attrs(
				pair.map(Tokens.format_ratio),
				[Html.test_id("ratio-${id}"), Html.class_attr("numeric font-mono text-2xl font-semibold text-zinc-950")],
			),
		],
	)

## A colour token: the chip is the token. Reading a design token editor without
## seeing the colour is reading a spreadsheet.
colour_field : Str, Ui.State(Str), Str, Signal.Signal(Tokens.Colour) -> Elem
colour_field = |label, state, css_name, parsed| {
	resolved = parsed.map(Tokens.colour_css)

	Html.section(
		"Token ${css_name}",
		[Html.class_attr(token_row_class)],
		[
			Html.div_c(
				"flex items-end gap-3",
				[
					Html.div(
						[
							Html.class_attr("h-10 w-10 shrink-0 rounded-md border border-zinc-300 shadow-inner"),
							Html.attr_s("style", resolved.map(|hex| "background-color: ${hex}")),
						],
						[],
					),
					Html.div_c(
						"field min-w-0 flex-1",
						[
							Html.paragraph_c(label, "field-label"),
							Html.text_input_attrs(
								label,
								state.signal(),
								[Html.class_attr(input_class), Html.attr("placeholder", "#2563eb"), Html.attr("spellcheck", "false")],
								state.on_str(|_, value| value),
							),
						],
					),
				],
			),
			Html.div_c(
				"flex items-center justify-between gap-2",
				[
					Html.paragraph_c("var(--${css_name})", "hint font-mono"),
					Html.paragraph_s_attrs(resolved, [Html.class_attr(mono_class)]),
				],
			),
		],
	)
}

## Size chips are drawn to scale, capped at the width of the chip so a runaway
## font size cannot blow out the column.
size_bar_style : Tokens.Size -> Str
size_bar_style = |size| {
	width = if !size.ok {
		0
	} else if size.px > 32 {
		32
	} else {
		size.px
	}
	"width: ${width.to_str()}px; height: 8px"
}

size_field : Str, Ui.State(Str), Str, Signal.Signal(Tokens.Size) -> Elem
size_field = |label, state, css_name, parsed|
	Html.section(
		"Token ${css_name}",
		[Html.class_attr(token_row_class)],
		[
			Html.div_c(
				"flex items-end gap-3",
				[
					Html.div_c(
						"flex h-10 w-10 shrink-0 items-center justify-center rounded-md border border-zinc-200 bg-zinc-100",
						[
							Html.div(
								[Html.class_attr("rounded-sm bg-zinc-900"), Html.attr_s("style", parsed.map(size_bar_style))],
								[],
							),
						],
					),
					Html.div_c(
						"field min-w-0 flex-1",
						[
							Html.paragraph_c(label, "field-label"),
							Html.text_input_attrs(
								label,
								state.signal(),
								[Html.class_attr(input_class), Html.attr("placeholder", "8"), Html.attr("inputmode", "numeric")],
								state.on_str(|_, value| value),
							),
						],
					),
				],
			),
			Html.div_c(
				"flex items-center justify-between gap-2",
				[
					Html.paragraph_c("var(--${css_name})", "hint font-mono"),
					Html.paragraph_s_attrs(parsed.map(Tokens.size_css), [Html.class_attr(mono_class)]),
				],
			),
		],
	)

## Two independent booleans feeding one rollup.
aa_summary : Bool, Bool -> Str
aa_summary = |text_ok, button_ok| {
	passing : U64
	passing = (if text_ok { 1 } else { 0 }) + (if button_ok { 1 } else { 0 })
	"${passing.to_str()} of 2 pairs pass AA"
}

aa_summary_class : Bool, Bool -> Str
aa_summary_class = |text_ok, button_ok|
	if text_ok and button_ok {
		"badge badge-ok"
	} else {
		"badge badge-warn"
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

## The notice tone is derived from the very message it tints, so a red banner
## can never carry the all-clear sentence.
validity_class : Str -> Str
validity_class = |text|
	if text.starts_with("Invalid") {
		"notice notice-error"
	} else {
		"notice notice-ok"
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
	summary_class = Signal.map2(text_passes, button_passes, aa_summary_class)

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
				"app-header",
				[
					Html.heading_c("Design Token Editor", "app-title"),
					Html.paragraph_c(
						"Edit the six source tokens. The painted preview, the WCAG contrast grades, and the exported stylesheet are all derived from them — nothing here is stored twice.",
						"app-subtitle",
					),
				],
			),
			Html.div_c(
				"grid gap-6 lg:grid-cols-2",
				[
					Html.section_c(
						"Tokens",
						panel_class,
						[
							Html.heading_c("Tokens", "panel-title"),
							colour_field("Background colour", bg, "color-bg", bg_colour),
							colour_field("Text colour", fg, "color-fg", fg_colour),
							colour_field("Accent colour", accent, "color-accent", accent_colour),
							size_field("Spacing small", space, "space-sm", space_size),
							size_field("Font size medium", font, "font-md", font_size),
							size_field("Corner radius medium", radius, "radius-md", radius_size),
							Html.paragraph_s_attrs(
								validity,
								[Html.test_id("token-validity"), Html.class_attr_s(validity.map(validity_class))],
							),
						],
					),
					Html.div_c(
						"grid content-start gap-6",
						[
							Html.section_c(
								"Preview",
								panel_class,
								[
									Html.heading_c("Preview", "panel-title"),
									Ui.each_str(previews, |preview| preview.id, render_preview),
								],
							),
							Html.section_c(
								"Contrast validation",
								panel_class,
								[
									Html.div_c(
										"flex flex-wrap items-center justify-between gap-3",
										[
											Html.heading_c("Contrast validation", "panel-title"),
											Html.paragraph_s_attrs(
												summary,
												[Html.test_id("aa-summary"), Html.class_attr_s(summary_class)],
											),
										],
									),
									pair_line("text", "Text on background", text_pair),
									pair_line("button", "Button label on accent", button_pair),
									Html.paragraph_c("AA needs 4.50:1 for body text; AAA needs 7.00:1.", "hint"),
								],
							),
						],
					),
				],
			),
			Html.section_c(
				"CSS export",
				panel_class,
				[
					Html.heading_c("CSS export", "panel-title"),
					Html.div(
						[Html.test_id("stylesheet")],
						[Html.pre_s_c(stylesheet, code_class)],
					),
					Html.paragraph_c("--radius-md is exported but referenced by no preview, so editing it moves this block alone.", "hint"),
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
