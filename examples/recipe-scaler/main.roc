app [main] { pf: platform "https://github.com/lukewilliamboswell/roc-signals/releases/download/0.1/3eLQGNMDG9RuL9sn1A7ep1Rtq7QGmemE89y141WSv1XG.tar.zst" }

import Recipes
import pf.Elem exposing [Elem]
import pf.Html
import pf.Signal
import pf.Ui

page_class = "grid gap-5"

hero_class = "panel grid gap-2 p-5"

panel_class = "panel grid gap-4 p-4"

controls_class = "flex flex-wrap items-end gap-4"

rows_class = "grid gap-2"

row_class = "flex items-baseline justify-between gap-4"

name_class = "text-sm font-medium text-zinc-900"

qty_class = "text-sm tabular-nums text-zinc-700"

note_class = "text-sm text-zinc-700"

input_class = "w-32 rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm"

select_class = "rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm"

## The context every ingredient quantity is derived from: the target scale in
## milli-servings and the unit system. This is the single fan-in point that a
## servings edit flows through.
DisplayCtx : { scale : U64, system : Str }

## The inputs the target scale is computed from.
ScaleInputs : { mode : Str, draft : Str, pan : Str, recipe : Recipes.Recipe }

scale_note : ScaleInputs, U64 -> Str
scale_note = |inputs, scale|
	if inputs.mode == "pan" {
		"Pan scaling: ${Recipes.pan_label(inputs.pan)}. The servings box is ignored."
	} else {
		match Recipes.parse_servings(inputs.draft) {
			Err(_) => "Servings must be a whole number from 0 to 96. Showing the recipe's own ${inputs.recipe.base_servings.to_str()} servings."
			Ok(servings) =>
				if servings == 0 {
					"Nothing to make at 0 servings: every quantity is 0."
				} else if scale == inputs.recipe.base_servings * 1000 {
					"Unscaled: this is the recipe as printed."
				} else {
					"Scaled from the recipe's ${inputs.recipe.base_servings.to_str()} servings."
				}
		}
	}

effective_text : U64 -> Str
effective_text = |scale| "Effective servings: ${Recipes.format_amount(scale)}"

unit_text : Str -> Str
unit_text = |system|
	if system == "imperial" {
		"Units: imperial (tsp and pinch are unchanged)"
	} else {
		"Units: metric (tsp and pinch are unchanged)"
	}

shopping_summary : List(Str), List(Recipes.ShoppingLine) -> Str
shopping_summary = |selected, lines|
	"Shopping list: ${lines.len().to_str()} lines from ${selected.len().to_str()} recipes"

ingredient_row : Str, Signal.Signal(Recipes.Ingredient), Signal.Signal(DisplayCtx) -> Elem
ingredient_row = |key, item, ctx| {
	name = item.map(|value| value.name)
	quantity =
		Signal.map2(
			item,
			ctx,
			|value, context| Recipes.quantity_text(value.per_serving, value.unit_code, context.scale, context.system),
		)

	Html.div_c(
		row_class,
		[
			Html.paragraph_s_attrs(name, [Html.test_id("ing-name-${key}"), Html.class_attr(name_class)]),
			Html.paragraph_s_attrs(quantity, [Html.test_id("ing-qty-${key}"), Html.class_attr(qty_class)]),
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
			|value, context| Recipes.quantity_text(value.per_serving, value.unit_code, context.scale, context.system),
		)

	Html.div_c(
		row_class,
		[
			Html.paragraph_s_attrs(name, [Html.test_id("shop-name-${key}"), Html.class_attr(name_class)]),
			Html.paragraph_s_attrs(quantity, [Html.test_id("shop-qty-${key}"), Html.class_attr(qty_class)]),
		],
	)
}

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

	Html.checkbox("Include ${recipe.title}", checked, toggle)
}

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
												|selected| page(recipe_id, servings_draft, scale_mode, pan, units, selected),
											),
									),
							),
					),
			),
	)

page : Ui.State(Str), Ui.State(Str), Ui.State(Str), Ui.State(Str), Ui.State(Str), Ui.State(List(Str)) -> Elem
page = |recipe_id, servings_draft, scale_mode, pan, units, selected| {
	recipe_signal = recipe_id.signal().map(Recipes.find)

	# Four independent sources fan in to the target scale.
	scale_inputs : Signal.Signal(ScaleInputs)
	scale_inputs =
		{
			mode: scale_mode.signal(),
			draft: servings_draft.signal(),
			pan: pan.signal(),
			recipe: recipe_signal,
		}.Signal

	scale_signal = scale_inputs.map(|inputs| Recipes.scale_milli(inputs.recipe, inputs.mode, inputs.draft, inputs.pan))

	# The one node every ingredient quantity in the page depends on.
	ctx : Signal.Signal(DisplayCtx)
	ctx = { scale: scale_signal, system: units.signal() }.Signal

	note_signal = Signal.map2(scale_inputs, scale_signal, scale_note)

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
				hero_class,
				[
					Html.heading_c("Recipe Scaler", "text-3xl font-semibold text-zinc-950"),
					Html.paragraph_c(
						"Scale a recipe by target servings or by tin size, switch between metric and imperial units, and aggregate several recipes into one shopping list.",
						"max-w-3xl text-sm text-zinc-700",
					),
				],
			),
			Html.section_c(
				"Scaling controls",
				panel_class,
				[
					Html.div_c(
						controls_class,
						[
							Html.select_c(
								"Recipe",
								recipe_id.signal(),
								select_class,
								Recipes.catalogue.map(recipe_option),
								recipe_id.on_str(|_, value| value),
							),
							Html.number_input_c(
								"Target servings",
								servings_draft.signal(),
								input_class,
								servings_draft.on_str(|_, value| value),
							),
							Html.select_c(
								"Pan size",
								pan.signal(),
								select_class,
								[
									Html.option("recipe", "Recipe's own tin"),
									Html.option("round20", "20 cm round"),
									Html.option("round24", "24 cm round"),
									Html.option("tray30", "30x20 cm tray"),
								],
								pan.on_str(|_, value| value),
							),
						],
					),
					Html.div_c(
						controls_class,
						[
							Html.radio("Scale by servings", "scale-mode", "servings", scale_mode.signal(), scale_mode.on_str(|_, value| value)),
							Html.radio("Scale by pan size", "scale-mode", "pan", scale_mode.signal(), scale_mode.on_str(|_, value| value)),
							Html.radio("Metric units", "unit-system", "metric", units.signal(), units.on_str(|_, value| value)),
							Html.radio("Imperial units", "unit-system", "imperial", units.signal(), units.on_str(|_, value| value)),
						],
					),
				],
			),
			Html.section_c(
				"Scale summary",
				panel_class,
				[
					Html.paragraph_s_attrs(scale_signal.map(effective_text), [Html.test_id("effective-servings"), Html.class_attr(note_class)]),
					Html.paragraph_s_attrs(note_signal, [Html.test_id("scale-note"), Html.class_attr(note_class)]),
					Html.paragraph_s_attrs(units.signal().map(unit_text), [Html.test_id("unit-system"), Html.class_attr(note_class)]),
					Html.paragraph_s_attrs(controls_signal, [Html.test_id("controls-summary"), Html.class_attr(note_class)]),
				],
			),
			Html.section_c(
				"Ingredients",
				panel_class,
				[
					Html.paragraph_s_attrs(recipe_signal.map(|recipe| recipe.title), [Html.test_id("recipe-title"), Html.class_attr("text-lg font-semibold text-zinc-950")]),
					Html.div(
						[Html.test_id("ingredient-rows"), Html.class_attr(rows_class)],
						[Ui.each_str(ingredients_signal, |item| item.slug, |key, item| ingredient_row(key, item, ctx))],
					),
				],
			),
			Html.section_c(
				"Shopping list",
				panel_class,
				[
					Html.div_c(controls_class, Recipes.catalogue.map(|recipe| include_checkbox(recipe, selected))),
					Html.paragraph_s_attrs(Signal.map2(selected.signal(), lines_signal, shopping_summary), [Html.test_id("shopping-count"), Html.class_attr(note_class)]),
					Ui.when(
						has_selection,
						|| Html.div(
							[Html.test_id("shopping-rows"), Html.class_attr(rows_class)],
							[Ui.each_str(lines_signal, |line| line.key, |key, item| shopping_row(key, item, ctx))],
						),
						|| Html.paragraph_attrs(
							"Shopping list is empty. Include a recipe to build one.",
							[Html.test_id("shopping-empty"), Html.class_attr(note_class)],
						),
					),
				],
			),
		],
	)
}
