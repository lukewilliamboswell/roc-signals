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
	bg : Tokens.ColourToken,
	fg : Tokens.ColourToken,
	accent : Tokens.ColourToken,
	space : Tokens.SizeToken,
	font : Tokens.SizeToken,
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

## The verdict for one measured pair. Both the badge text and the badge tone are
## read off this tag, so the two can never disagree about the same ratio.
Grade : [Unmeasurable, Aaa, Aa, Fail]

grade_of : Tokens.Contrast -> Grade
grade_of = |value|
	match value {
		Err(_) => Unmeasurable
		Ok(ratio) =>
			if ratio >= aaa_threshold {
				Aaa
			} else if ratio >= Tokens.aa_threshold {
				Aa
			} else {
				Fail
			}
	}

grade_label : Grade -> Str
grade_label = |grade|
	match grade {
		Unmeasurable => "Invalid"
		Aaa => "AAA"
		Aa => "AA"
		Fail => "Fail"
	}

grade_class : Grade -> Str
grade_class = |grade|
	match grade {
		Unmeasurable => "badge badge-neutral"
		Aaa => "badge badge-ok"
		Aa => "badge badge-ok"
		Fail => "badge badge-danger"
	}

expect grade_label(grade_of(Err(NotAHexColour))) == "Invalid"
expect grade_label(grade_of(Ok(449))) == "Fail"
expect grade_label(grade_of(Ok(454))) == "AA"
expect grade_label(grade_of(Ok(700))) == "AAA"

pair_line : Str, Str, Signal.Signal(Tokens.Contrast) -> Elem
pair_line = |id, label, pair| {
	grade = pair.map(grade_of)

	Html.section(
		label,
		[Html.class_attr("card gap-1.5")],
		[
			Html.div_c(
				"flex flex-wrap items-center justify-between gap-3",
				[
					Html.paragraph_c(label, "card-title"),
					Html.paragraph_s_attrs(
						grade.map(grade_label),
						[Html.test_id("aa-${id}"), Html.class_attr_s(grade.map(grade_class))],
					),
				],
			),
			Html.paragraph_s_attrs(
				pair.map(Tokens.format_ratio),
				[Html.test_id("ratio-${id}"), Html.class_attr("numeric font-mono text-2xl font-semibold text-zinc-950")],
			),
		],
	)
}

## A colour token: the chip is the token. Reading a design token editor without
## seeing the colour is reading a spreadsheet.
colour_field : Str, Ui.State(Str), Str, Signal.Signal(Tokens.ColourToken) -> Elem
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
size_bar_style : Tokens.SizeToken -> Str
size_bar_style = |size| {
	width = Try.ok_or(Try.map_ok(size, |px| if px > 32 { 32 } else { px }), 0)
	"width: ${width.to_str()}px; height: 8px"
}

size_field : Str, Ui.State(Str), Str, Signal.Signal(Tokens.SizeToken) -> Elem
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

## Two independent AA flags feeding one rollup. They travel as a named record,
## not as two bare `Bool`s: `aa_summary(button_ok, text_ok)` would type-check
## just as happily as the right order.
AaFlags : {
	text : Bool,
	button : Bool,
}

aa_summary : AaFlags -> Str
aa_summary = |flags| {
	passing : U64
	passing = (if flags.text { 1 } else { 0 }) + (if flags.button { 1 } else { 0 })
	"${passing.to_str()} of 2 pairs pass AA"
}

aa_summary_class : AaFlags -> Str
aa_summary_class = |flags|
	if flags.text and flags.button {
		"badge badge-ok"
	} else {
		"badge badge-warn"
	}

expect aa_summary({ text: True, button: False }) == "1 of 2 pairs pass AA"
expect aa_summary_class({ text: True, button: True }) == "badge badge-ok"

## Which of the six tokens currently fail to parse. The notice renders from this
## tag: the sentence and the tone are two views of the same value, so neither
## has to be recovered by sniffing the other.
Validity : [AllValid, SomeInvalid(List(Str))]

token_validity : Design, Tokens.SizeToken -> Validity
token_validity = |design, radius| {
	flags = [
		{ name: "color-bg", ok: design.bg.is_ok() },
		{ name: "color-fg", ok: design.fg.is_ok() },
		{ name: "color-accent", ok: design.accent.is_ok() },
		{ name: "space-sm", ok: design.space.is_ok() },
		{ name: "font-md", ok: design.font.is_ok() },
		{ name: "radius-md", ok: radius.is_ok() },
	]
	broken = flags.keep_if(|flag| !flag.ok).map(|flag| flag.name)
	if broken.is_empty() {
		AllValid
	} else {
		SomeInvalid(broken)
	}
}

validity_text : Validity -> Str
validity_text = |validity|
	match validity {
		AllValid => "All 6 tokens valid"
		SomeInvalid(names) => "Invalid tokens: ${Str.join_with(names, ", ")}"
	}

validity_class : Validity -> Str
validity_class = |validity|
	match validity {
		AllValid => "notice notice-ok"
		SomeInvalid(_) => "notice notice-error"
	}

expect validity_text(AllValid) == "All 6 tokens valid"
expect validity_text(SomeInvalid(["color-bg", "font-md"])) == "Invalid tokens: color-bg, font-md"

## The six draft text boxes. Six positional `Ui.State(Str)` parameters are
## indistinguishable to the type checker, so they travel named instead: swapping
## `bg` and `fg` at the call site is now a compile error, not a silent bug.
Drafts : {
	bg : Ui.State(Str),
	fg : Ui.State(Str),
	accent : Ui.State(Str),
	space : Ui.State(Str),
	font : Ui.State(Str),
	radius : Ui.State(Str),
}

editor : Drafts -> Elem
editor = |drafts| {
	# Hop 1: raw draft text -> parsed token.
	bg_colour = drafts.bg.signal().map(Tokens.parse_colour)
	fg_colour = drafts.fg.signal().map(Tokens.parse_colour)
	accent_colour = drafts.accent.signal().map(Tokens.parse_colour)
	space_size = drafts.space.signal().map(Tokens.parse_size)
	font_size = drafts.font.signal().map(Tokens.parse_size)
	radius_size = drafts.radius.signal().map(Tokens.parse_size)

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
	aa_flags = Signal.map2(text_passes, button_passes, |text, button| { text: text, button: button })
	summary = aa_flags.map(aa_summary)
	summary_class = aa_flags.map(aa_summary_class)

	validity = Signal.map2(design, radius_size, token_validity)

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
							colour_field("Background colour", drafts.bg, "color-bg", bg_colour),
							colour_field("Text colour", drafts.fg, "color-fg", fg_colour),
							colour_field("Accent colour", drafts.accent, "color-accent", accent_colour),
							size_field("Spacing small", drafts.space, "space-sm", space_size),
							size_field("Font size medium", drafts.font, "font-md", font_size),
							size_field("Corner radius medium", drafts.radius, "radius-md", radius_size),
							Html.paragraph_s_attrs(
								validity.map(validity_text),
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
												|radius|
													editor(
														{
															bg: bg,
															fg: fg,
															accent: accent,
															space: space,
															font: font,
															radius: radius,
														},
													),
											),
									),
							),
					),
			),
	)
