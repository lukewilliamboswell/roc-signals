# Domain module for the Recipe Scaler example.
#
# Quantities are integers in a fixed-point unit so every derived value is
# deterministic on every host. There are three scales in play:
#
#   * `per_serving`  - micro-units of the ingredient's canonical (metric) unit
#                      for exactly one serving. `200 g` over `4` servings is
#                      `200 * 1000 * 1000 / 4 = 50_000_000` micro-grams.
#   * `scale`        - milli-servings. `4` servings is `4000`; pan-size scaling
#                      can land between whole servings, which is why the target
#                      is kept in thousandths.
#   * `milli`        - milli-units of the displayed unit, the value that is
#                      rounded to hundredths for display.
#
# Every numeric literal here is annotated (directly or through a signature) so
# nothing silently infers as `Frac`.

Recipes := [].{
	## An ingredient line, normalised to a per-serving amount so that the value
	## is independent of the current target servings. `unit_code` is one of
	## `"g"`, `"ml"`, `"tsp"`, `"pinch"`.
	Ingredient : {
		slug : Str,
		name : Str,
		unit_code : Str,
		per_serving : U64,
	}

	## One recipe in the catalogue. `base_area` is the area in cm^2 of the tin
	## or pan the printed recipe assumes, used by pan-size scaling.
	Recipe : {
		id : Str,
		title : Str,
		base_servings : U64,
		base_area : U64,
		ingredients : List(Ingredient),
	}

	## An aggregated shopping-list line. `key` is `"<slug>-<unit_code>"`, so the
	## same ingredient in two different units stays on two separate lines.
	ShoppingLine : {
		key : Str,
		name : Str,
		unit_code : Str,
		per_serving : U64,
		sources : U64,
	}

	## Build a per-serving ingredient from a printed amount in whole canonical
	## units and the recipe's own base serving count.
	ingredient : Str, Str, Str, U64, U64 -> Ingredient
	ingredient = |slug, name, unit_code, amount, base_servings| {
		micro : U64
		micro = amount * 1_000_000
		{ slug, name, unit_code, per_serving: micro / base_servings }
	}

	pancakes : Recipe
	pancakes = {
		id: "pancakes",
		title: "Buttermilk Pancakes",
		base_servings: 4,
		base_area: 452,
		ingredients: [
			ingredient("flour", "Plain flour", "g", 200, 4),
			ingredient("buttermilk", "Buttermilk", "ml", 300, 4),
			ingredient("butter", "Butter", "g", 50, 4),
			ingredient("baking-powder", "Baking powder", "tsp", 2, 4),
			ingredient("salt", "Salt", "pinch", 1, 4),
		],
	}

	# Base servings of 3 is deliberate: scaling it to 2 servings produces a
	# repeating fraction that has to be rounded for display.
	soup : Recipe
	soup = {
		id: "soup",
		title: "Roasted Tomato Soup",
		base_servings: 3,
		base_area: 452,
		ingredients: [
			ingredient("tomatoes", "Tomatoes", "g", 900, 3),
			ingredient("stock", "Vegetable stock", "ml", 500, 3),
			ingredient("butter", "Butter", "tsp", 3, 3),
			ingredient("salt", "Salt", "pinch", 2, 3),
		],
	}

	bread : Recipe
	bread = {
		id: "bread",
		title: "Seeded Bread Loaf",
		base_servings: 8,
		base_area: 600,
		ingredients: [
			ingredient("flour", "Plain flour", "g", 500, 8),
			ingredient("water", "Water", "ml", 320, 8),
			ingredient("butter", "Butter", "g", 20, 8),
			ingredient("salt", "Salt", "pinch", 1, 8),
		],
	}

	catalogue : List(Recipe)
	catalogue = [pancakes, soup, bread]

	## Look a recipe up by id, falling back to the first catalogue entry.
	find : Str -> Recipe
	find = |id|
		match catalogue.find_first(|recipe| recipe.id == id) {
			Ok(recipe) => recipe
			Err(_) => pancakes
		}

	## Area in cm^2 for a pan-size option value.
	pan_area : Str -> U64
	pan_area = |pan|
		if pan == "round20" {
			314
		} else if pan == "round24" {
			452
		} else if pan == "tray30" {
			600
		} else {
			0
		}

	## Human label for a pan-size option value, phrased for the summary note.
	pan_label : Str -> Str
	pan_label = |pan|
		if pan == "round20" {
			"a 20 cm round tin"
		} else if pan == "round24" {
			"a 24 cm round tin"
		} else if pan == "tray30" {
			"a 30x20 cm tray"
		} else {
			"the recipe's own tin"
		}

	## Parse the servings draft. `Err` means the draft is not a whole number in
	## the supported range; the caller decides what to show instead.
	parse_servings : Str -> Try(U64, [Invalid])
	parse_servings = |draft| {
		digits = draft.trim().to_utf8()
		if digits.is_empty() or digits.len() > 3 {
			Err(Invalid)
		} else {
			folded =
				digits.fold(
					{ ok: True, value: 0 },
					|acc, byte|
						if !acc.ok {
							acc
						} else if byte >= 48 and byte <= 57 {
							{ ok: True, value: acc.value * 10 + byte.to_u64() - 48 }
						} else {
							{ ok: False, value: 0 }
						},
				)

			if folded.ok and folded.value <= 96 {
				Ok(folded.value)
			} else {
				Err(Invalid)
			}
		}
	}

	## Target scale in milli-servings.
	##
	## In `"servings"` mode this is the parsed servings box; when the draft is
	## not a whole number the recipe's own base servings are used instead so the
	## page keeps showing a usable recipe while the warning is visible.
	## In `"pan"` mode the servings box is ignored and the scale comes from the
	## ratio between the chosen tin area and the recipe's own tin area.
	scale_milli : Recipe, Str, Str, Str -> U64
	scale_milli = |recipe, mode, draft, pan|
		if mode == "pan" {
			area = pan_area(pan)
			if area == 0 {
				recipe.base_servings * 1000
			} else {
				recipe.base_servings * 1000 * area / recipe.base_area
			}
		} else {
			match parse_servings(draft) {
				Ok(value) => value * 1000
				Err(_) => recipe.base_servings * 1000
			}
		}

	## Scaled amount in milli-units of the ingredient's canonical unit.
	scaled_milli : U64, U64 -> U64
	scaled_milli = |per_serving, scale| per_serving * scale / 1_000_000

	## Convert a canonical milli-amount into the displayed unit system.
	## `tsp` and `pinch` are the same in both systems and are returned unchanged.
	convert : Str, Str, U64 -> { amount : U64, label : Str }
	convert = |unit_code, system, milli|
		if system == "imperial" {
			if unit_code == "g" {
				{ amount: milli * 1000 / 28350, label: "oz" }
			} else if unit_code == "ml" {
				{ amount: milli * 1000 / 29574, label: "fl oz" }
			} else if unit_code == "tsp" {
				{ amount: milli, label: "tsp" }
			} else {
				{ amount: milli, label: "pinch" }
			}
		} else if unit_code == "g" {
			{ amount: milli, label: "g" }
		} else if unit_code == "ml" {
			{ amount: milli, label: "ml" }
		} else if unit_code == "tsp" {
			{ amount: milli, label: "tsp" }
		} else {
			{ amount: milli, label: "pinch" }
		}

	pad2 : U64 -> Str
	pad2 = |value|
		if value < 10 {
			"0${value.to_str()}"
		} else {
			value.to_str()
		}

	## Round a milli-amount to hundredths and render it without trailing zeros.
	format_amount : U64 -> Str
	format_amount = |milli| {
		hundredths : U64
		hundredths = (milli + 5) / 10
		whole = hundredths / 100
		frac = hundredths % 100
		if frac == 0 {
			whole.to_str()
		} else if frac % 10 == 0 {
			"${whole.to_str()}.${(frac / 10).to_str()}"
		} else {
			"${whole.to_str()}.${pad2(frac)}"
		}
	}

	## The full display string for one ingredient line.
	quantity_text : U64, Str, U64, Str -> Str
	quantity_text = |per_serving, unit_code, scale, system| {
		converted = convert(unit_code, system, scaled_milli(per_serving, scale))
		"${format_amount(converted.amount)} ${converted.label}"
	}

	merge_line : List(ShoppingLine), ShoppingLine -> List(ShoppingLine)
	merge_line = |acc, line|
		match acc.find_first(|row| row.key == line.key) {
			Ok(_) =>
				acc.map(
					|row|
						if row.key == line.key {
							{ ..row, per_serving: row.per_serving + line.per_serving, sources: row.sources + 1 }
						} else {
							row
						},
				)

			Err(_) => acc.append(line)
		}

	## Aggregate the ingredients of every selected recipe. Lines are keyed by
	## slug *and* unit, so `Butter` in grams and `Butter` in teaspoons stay
	## separate. The result depends only on the selection, never on the target
	## servings, so changing servings cannot disturb list structure.
	shopping_lines : List(Str) -> List(ShoppingLine)
	shopping_lines = |selected| {
		contributions : List(ShoppingLine)
		contributions =
			catalogue
			.drop_if(|recipe| !selected.contains(recipe.id))
			.map(
				|recipe|
					recipe.ingredients.map(
						|item| {
							key: "${item.slug}-${item.unit_code}",
							name: item.name,
							unit_code: item.unit_code,
							per_serving: item.per_serving,
							sources: 1,
						},
					),
			)
			.join()

		contributions.fold([], merge_line)
	}
}
