app [main] { pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.1/3eLQGNMDG9RuL9sn1A7ep1Rtq7QGmemE89y141WSv1XG.tar.zst" }

import Recipes
import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

page_class = "app-shell app-shell-narrow"

panel_class = "panel"

## Quantity column first, ingredient name second, so the figures form one column
## down the page instead of drifting with the length of each name.
line_class = "grid grid-cols-[6.5rem_minmax(0,1fr)] items-baseline gap-4 border-b border-zinc-100 py-1.5"

qty_class = "numeric font-mono text-right text-sm font-medium text-zinc-950"

name_class = "min-w-0 text-sm text-zinc-800"

input_class = "input"

## The context every ingredient quantity is derived from: the target scale in
## milli-servings and the unit system. This is the single fan-in point that a
## servings edit flows through.
DisplayCtx : { scale : U64, system : Recipes.UnitSystem }

## The inputs the target scale is computed from.
ScaleInputs : { mode : Recipes.ScaleMode, draft : Str, pan : Recipes.Pan, recipe : Recipes.Recipe }

## What the scale summary has to say about the current inputs. This is the one
## thing the banner is derived from: both the sentence and the tone come from
## the same tag, so a red notice can never carry the "recipe as printed"
## message and neither has to read the other back out of a string.
ScaleNote := [
	PanScaling(Recipes.Pan),
	BadServings(U64),
	NothingToMake,
	Unscaled,
	ScaledFrom(U64),
].{
	is_eq : ScaleNote, ScaleNote -> Bool
	is_eq = |left, right|
		match left {
			PanScaling(left_pan) => match right {
				PanScaling(right_pan) => left_pan.is_eq(right_pan)
				_ => False
			}
			BadServings(left_base) => match right {
				BadServings(right_base) => left_base == right_base
				_ => False
			}
			NothingToMake => match right {
				NothingToMake => True
				_ => False
			}
			Unscaled => match right {
				Unscaled => True
				_ => False
			}
			ScaledFrom(left_base) => match right {
				ScaledFrom(right_base) => left_base == right_base
				_ => False
			}
		}
}

scale_note : ScaleInputs, U64 -> ScaleNote
scale_note = |inputs, scale|
	match inputs.mode {
		ByPan => PanScaling(inputs.pan)
		ByServings =>
			match Recipes.parse_servings(inputs.draft) {
				Err(_) => BadServings(inputs.recipe.base_servings)
				Ok(servings) =>
					if servings == 0 {
						NothingToMake
					} else if scale == inputs.recipe.base_servings * 1000 {
						Unscaled
					} else {
						ScaledFrom(inputs.recipe.base_servings)
					}
			}
	}

scale_note_text : ScaleNote -> Str
scale_note_text = |note|
	match note {
		PanScaling(pan) => "Pan scaling: ${Recipes.pan_label(pan)}. The servings box is ignored."
		BadServings(base) => "Servings must be a whole number from 0 to 96. Showing the recipe's own ${base.to_str()} servings."
		NothingToMake => "Nothing to make at 0 servings: every quantity is 0."
		Unscaled => "Unscaled: this is the recipe as printed."
		ScaledFrom(base) => "Scaled from the recipe's ${base.to_str()} servings."
	}

scale_note_class : ScaleNote -> Str
scale_note_class = |note|
	match note {
		BadServings(_) => "notice notice-error"
		NothingToMake => "notice notice-warn"
		_ => "notice notice-info"
	}

# Message and class are two projections of one tag, so these pairs cannot drift
# apart the way a `starts_with` on the rendered sentence could.

## An unparseable servings box names the range it wanted and the servings it fell back to.
expect {
	note = scale_note({ mode: Recipes.mode_from_str("servings"), draft: "two", pan: Recipes.pan_from_str("recipe"), recipe: Recipes.find("pancakes") }, 4000)
	scale_note_text(note) == "Servings must be a whole number from 0 to 96. Showing the recipe's own 4 servings."
}

## An unparseable servings box tones the banner as an error.
expect {
	note = scale_note({ mode: Recipes.mode_from_str("servings"), draft: "two", pan: Recipes.pan_from_str("recipe"), recipe: Recipes.find("pancakes") }, 4000)
	scale_note_class(note) == "notice notice-error"
}

## Zero servings is spelled out rather than left as a page of zeros.
expect {
	note = scale_note({ mode: Recipes.mode_from_str("servings"), draft: "0", pan: Recipes.pan_from_str("recipe"), recipe: Recipes.find("pancakes") }, 0)
	scale_note_text(note) == "Nothing to make at 0 servings: every quantity is 0."
}

## Zero servings is a warning tone, not an error: the draft itself parsed.
expect {
	note = scale_note({ mode: Recipes.mode_from_str("servings"), draft: "0", pan: Recipes.pan_from_str("recipe"), recipe: Recipes.find("pancakes") }, 0)
	scale_note_class(note) == "notice notice-warn"
}

## Asking for the recipe's own servings says so instead of claiming a scale.
expect {
	note = scale_note({ mode: Recipes.mode_from_str("servings"), draft: "4", pan: Recipes.pan_from_str("recipe"), recipe: Recipes.find("pancakes") }, 4000)
	scale_note_text(note) == "Unscaled: this is the recipe as printed."
}

## An unscaled page keeps the neutral informational tone.
expect {
	note = scale_note({ mode: Recipes.mode_from_str("servings"), draft: "4", pan: Recipes.pan_from_str("recipe"), recipe: Recipes.find("pancakes") }, 4000)
	scale_note_class(note) == "notice notice-info"
}

## A scaled page names the printed serving count it was scaled from.
expect {
	note = scale_note({ mode: Recipes.mode_from_str("servings"), draft: "8", pan: Recipes.pan_from_str("recipe"), recipe: Recipes.find("pancakes") }, 8000)
	scale_note_text(note) == "Scaled from the recipe's 4 servings."
}

## A servings-scaled page keeps the neutral informational tone.
expect {
	note = scale_note({ mode: Recipes.mode_from_str("servings"), draft: "8", pan: Recipes.pan_from_str("recipe"), recipe: Recipes.find("pancakes") }, 8000)
	scale_note_class(note) == "notice notice-info"
}

## Pan mode names the chosen tin and says the servings box no longer applies.
expect {
	note = scale_note({ mode: Recipes.mode_from_str("pan"), draft: "20", pan: Recipes.pan_from_str("tray30"), recipe: Recipes.find("pancakes") }, 5309)
	scale_note_text(note) == "Pan scaling: a 30x20 cm tray. The servings box is ignored."
}

## A pan-scaled page keeps the neutral informational tone.
expect {
	note = scale_note({ mode: Recipes.mode_from_str("pan"), draft: "20", pan: Recipes.pan_from_str("tray30"), recipe: Recipes.find("pancakes") }, 5309)
	scale_note_class(note) == "notice notice-info"
}

## The metric radio value renders as its display caption.
expect unit_text(Recipes.system_from_str("metric")) == "Metric"

## The imperial radio value renders as its display caption.
expect unit_text(Recipes.system_from_str("imperial")) == "Imperial"

effective_text : U64 -> Str
effective_text = |scale| Recipes.format_amount(scale)

## The scale factor the whole page is multiplied by, as a badge caption. `scale`
## is already in milli-servings, so dividing by the printed serving count lands
## back in milli-units, which is exactly what `format_amount` renders.
factor_text : U64, Recipes.Recipe -> Str
factor_text = |scale, recipe| "×${Recipes.format_amount(scale / recipe.base_servings)}"

unit_text : Recipes.UnitSystem -> Str
unit_text = |system|
	match system {
		Imperial => "Imperial"
		Metric => "Metric"
	}

shopping_summary : List(Str), List(Recipes.ShoppingLine) -> Str
shopping_summary = |selected, lines|
	"${lines.len().to_str()} lines from ${selected.len().to_str()} recipes"

stat : Str, Signal.Signal(Str), Str -> Elem
stat = |label, value, id|
	Html.div_c(
		"stat",
		[
			Html.paragraph_c(label, "stat-label"),
			Html.paragraph_s_attrs(value, [Html.test_id(id), Html.class_attr("stat-value")]),
		],
	)

## The column captions for the ingredient and shopping lists, on the same grid
## as the rows beneath them.
line_head : Str -> Elem
line_head = |name_label|
	Html.div_c(
		line_class,
		[
			Html.paragraph_c("Quantity", "hint text-right uppercase tracking-wide"),
			Html.paragraph_c(name_label, "hint uppercase tracking-wide"),
		],
	)

ingredient_row : Str, Signal.Signal(Recipes.Ingredient), Signal.Signal(DisplayCtx) -> Elem
ingredient_row = |key, item, ctx| {
	name = item.map(|value| value.name)
	quantity =
		Signal.map2(
			item,
			ctx,
			|value, context| Recipes.quantity_text(value.per_serving, value.unit, context.scale, context.system),
		)

	Html.div_c(
		line_class,
		[
			Html.paragraph_s_attrs(quantity, [Html.test_id("ing-qty-${key}"), Html.class_attr(qty_class)]),
			Html.paragraph_s_attrs(name, [Html.test_id("ing-name-${key}"), Html.class_attr(name_class)]),
		],
	)
}

shopping_row : Str, Signal.Signal(Recipes.ShoppingLine), Signal.Signal(DisplayCtx) -> Elem
shopping_row = |key, item, ctx| {
	name =
		item.map(
			|value|
				if value.sources == 1 {
					value.name
				} else {
					"${value.name} (${value.sources.to_str()} recipes)"
				},
		)
	quantity =
		Signal.map2(
			item,
			ctx,
			|value, context| Recipes.quantity_text(value.per_serving, value.unit, context.scale, context.system),
		)

	Html.div_c(
		line_class,
		[
			Html.paragraph_s_attrs(quantity, [Html.test_id("shop-qty-${key}"), Html.class_attr(qty_class)]),
			Html.paragraph_s_attrs(name, [Html.test_id("shop-name-${key}"), Html.class_attr(name_class)]),
		],
	)
}

## Checkboxes and radios are bare inputs, so the visible caption is drawn beside
## them here; the string passed to the control is only its accessible name.
include_checkbox : Recipes.Recipe, Ui.State(List(Str)) -> Elem
include_checkbox = |recipe, selected| {
	id = recipe.id
	checked = selected.signal().map(|ids| ids.contains(id))
	toggle =
		selected.on_bool(
			|ids, on|
				if on {
					if ids.contains(id) {
						ids
					} else {
						ids.append(id)
					}
				} else {
					ids.drop_if(|value| value == id)
				},
		)

	Html.div_c(
		"check-row",
		[
			Html.checkbox_c("Include ${recipe.title}", checked, "checkbox", toggle),
			Html.text(recipe.title),
		],
	)
}

radio_row : Str, Str, Str, Signal.Signal(Str), _ -> Elem
radio_row = |label, group, value, selected, msg|
	Html.div_c(
		"check-row",
		[
			Html.radio_c(label, group, value, selected, "checkbox", msg),
			Html.text(label),
		],
	)

recipe_option : Recipes.Recipe -> Elem
recipe_option = |recipe| Html.option(recipe.id, recipe.title)

main : () -> Elem
main = ||
	Ui.state(
		"pancakes",
		|recipe_id|
			Ui.state(
				"4",
				|servings_draft|
					Ui.state(
						"servings",
						|scale_mode|
							Ui.state(
								"recipe",
								|pan|
									Ui.state(
										"metric",
										|units|
											Ui.state(
												[],
												|selected| page({ recipe_id, servings_draft, scale_mode, pan, units, selected }),
											),
									),
							),
					),
			),
	)

## Every control handle the page reads, as one record: five of the six are
## `Ui.State(Str)`, so naming them at the call site is the only thing that
## stops two of them being swapped without a type error.
Controls : {
	recipe_id : Ui.State(Str),
	servings_draft : Ui.State(Str),
	scale_mode : Ui.State(Str),
	pan : Ui.State(Str),
	units : Ui.State(Str),
	selected : Ui.State(List(Str)),
}

page : Controls -> Elem
page = |controls| {
	recipe_id = controls.recipe_id
	servings_draft = controls.servings_draft
	scale_mode = controls.scale_mode
	pan = controls.pan
	units = controls.units
	selected = controls.selected

	recipe_signal = recipe_id.signal().map(Recipes.find)

	# Four independent sources fan in to the target scale.
	scale_inputs : Signal.Signal(ScaleInputs)
	scale_inputs =
		{
			mode: scale_mode.signal().map(Recipes.mode_from_str),
			draft: servings_draft.signal(),
			pan: pan.signal().map(Recipes.pan_from_str),
			recipe: recipe_signal,
		}.Signal

	scale_signal = scale_inputs.map(|inputs| Recipes.scale_milli(inputs.recipe, inputs.mode, inputs.draft, inputs.pan))

	# The one node every ingredient quantity in the page depends on.
	ctx : Signal.Signal(DisplayCtx)
	ctx = { scale: scale_signal, system: units.signal().map(Recipes.system_from_str) }.Signal

	note_signal = Signal.map2(scale_inputs, scale_signal, scale_note)
	text_signal = note_signal.map(scale_note_text)
	# The headline badge and the ingredient quantities share `scale_signal`, so
	# the factor on the badge is always the factor the list was scaled by.
	factor_signal = Signal.map2(scale_signal, recipe_signal, factor_text)

	# A wide, same-shaped fan-in: four Str sources combined into one summary.
	controls_signal =
		Signal.combine([recipe_id.signal(), scale_mode.signal(), pan.signal(), units.signal()])
		.map(|values| "Controls: ${Str.join_with(values, " / ")}")

	ingredients_signal = recipe_signal.map(|recipe| recipe.ingredients)
	lines_signal = selected.signal().map(Recipes.shopping_lines)
	has_selection = selected.signal().map(|ids| !ids.is_empty())

	Html.div_c(
		page_class,
		[
			Html.section_c(
				"Recipe Scaler",
				"app-header",
				[
					Html.heading_c("Recipe Scaler", "app-title"),
					Html.paragraph_c(
						"Scale a recipe by target servings or by tin size, switch between metric and imperial units, and aggregate several recipes into one shopping list.",
						"app-subtitle",
					),
				],
			),
			Html.section_c(
				"Scaling controls",
				panel_class,
				[
					Html.div_c(
						"panel-head",
						[
							Html.heading_c("Scale", "panel-title"),
							Html.paragraph_s_attrs(factor_signal, [Html.test_id("scale-factor"), Html.class_attr("badge badge-info numeric")]),
						],
					),
					Html.div_c(
						"panel-body",
						[
							Html.div_c(
								"grid gap-4 sm:grid-cols-2",
								[
									Html.div_c(
										"field",
										[
											Html.paragraph_c("Recipe", "field-label"),
											Html.select_c(
												"Recipe",
												recipe_id.signal(),
												input_class,
												Recipes.catalogue.map(recipe_option),
												recipe_id.on_str(|_, value| value),
											),
										],
									),
									Html.div_c(
										"field",
										[
											Html.paragraph_c("Target servings", "field-label"),
											Html.number_input_attrs(
												"Target servings",
												servings_draft.signal(),
												[Html.class_attr(input_class), Html.attr("placeholder", "6"), Html.attr("min", "0"), Html.attr("max", "96")],
												servings_draft.on_str(|_, value| value),
											),
											Html.paragraph_c("A whole number from 0 to 96.", "hint"),
										],
									),
								],
							),
							Html.div_c(
								"grid gap-4 sm:grid-cols-2",
								[
									Html.div_c(
										"field",
										[
											Html.paragraph_c("Scale by", "field-label"),
											Html.div(
												[Html.class_attr("grid gap-2"), Html.attr("role", "radiogroup"), Html.attr("aria-label", "Scale by")],
												[
													radio_row("Scale by servings", "scale-mode", "servings", scale_mode.signal(), scale_mode.on_str(|_, value| value)),
													radio_row("Scale by pan size", "scale-mode", "pan", scale_mode.signal(), scale_mode.on_str(|_, value| value)),
												],
											),
										],
									),
									Html.div_c(
										"field",
										[
											Html.paragraph_c("Pan size", "field-label"),
											Html.select_c(
												"Pan size",
												pan.signal(),
												input_class,
												[
													Html.option("recipe", "Recipe's own tin"),
													Html.option("round20", "20 cm round"),
													Html.option("round24", "24 cm round"),
													Html.option("tray30", "30x20 cm tray"),
												],
												pan.on_str(|_, value| value),
											),
											Html.paragraph_c("Used only while scaling by pan size.", "hint"),
										],
									),
								],
							),
							Html.div_c(
								"field",
								[
									Html.paragraph_c("Units", "field-label"),
									Html.div(
										[Html.class_attr("flex flex-wrap gap-4"), Html.attr("role", "radiogroup"), Html.attr("aria-label", "Units")],
										[
											radio_row("Metric units", "unit-system", "metric", units.signal(), units.on_str(|_, value| value)),
											radio_row("Imperial units", "unit-system", "imperial", units.signal(), units.on_str(|_, value| value)),
										],
									),
									Html.paragraph_c("Teaspoons and pinches are the same in both systems.", "hint"),
								],
							),
						],
					),
				],
			),
			Html.section_c(
				"Scale summary",
				"grid gap-3",
				[
					Html.div_c(
						"stat-grid",
						[
							stat("Effective servings", scale_signal.map(effective_text), "effective-servings"),
							stat("Units", units.signal().map(|value| unit_text(Recipes.system_from_str(value))), "unit-system"),
						],
					),
					Html.paragraph_s_attrs(text_signal, [Html.test_id("scale-note"), Html.class_attr_s(note_signal.map(scale_note_class))]),
					Html.paragraph_s_attrs(controls_signal, [Html.test_id("controls-summary"), Html.class_attr("hint font-mono")]),
				],
			),
			Html.section_c(
				"Ingredients",
				panel_class,
				[
					Html.div_c(
						"panel-head",
						[
							Html.div_c(
								"grid gap-0.5",
								[
									Html.paragraph_c("Ingredients", "panel-title"),
									Html.paragraph_s_attrs(
										recipe_signal.map(|recipe| recipe.title),
										[Html.test_id("recipe-title"), Html.class_attr("text-base font-semibold text-zinc-950")],
									),
								],
							),
						],
					),
					Html.div_c(
						"panel-body gap-1",
						[
							line_head("Ingredient"),
							Html.div(
								[Html.test_id("ingredient-rows"), Html.class_attr("grid")],
								[Ui.each_str(ingredients_signal, |item| item.slug, |key, item| ingredient_row(key, item, ctx))],
							),
						],
					),
				],
			),
			Html.section_c(
				"Shopping list",
				panel_class,
				[
					Html.div_c(
						"panel-head",
						[
							Html.heading_c("Shopping list", "panel-title"),
							Html.paragraph_s_attrs(
								Signal.map2(selected.signal(), lines_signal, shopping_summary),
								[Html.test_id("shopping-count"), Html.class_attr("badge badge-neutral numeric")],
							),
						],
					),
					Html.div_c(
						"panel-body gap-3",
						[
							Html.div_c(
								"flex flex-wrap gap-x-6 gap-y-2",
								Recipes.catalogue.map(|recipe| include_checkbox(recipe, selected)),
							),
							Ui.when(
								has_selection,
								|| Html.div_c(
									"grid gap-1",
									[
										line_head("Combined ingredient"),
										Html.div(
											[Html.test_id("shopping-rows"), Html.class_attr("grid")],
											[Ui.each_str(lines_signal, |line| line.key, |key, item| shopping_row(key, item, ctx))],
										),
									],
								),
								|| Html.paragraph_attrs(
									"No recipes included yet. Tick one above to build a combined list.",
									[Html.test_id("shopping-empty"), Html.class_attr("empty-state")],
								),
							),
						],
					),
				],
			),
		],
	)
}
