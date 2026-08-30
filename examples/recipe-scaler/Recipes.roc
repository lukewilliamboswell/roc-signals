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
	## The canonical unit an ingredient is measured in. `unit_code` renders the
	## wire code (`"g"`, `"ml"`, `"tsp"`, `"pinch"`) that shopping-list keys and
	## metric labels are built from.
	Unit := [Grams, Millilitres, Teaspoons, Pinches].{
		is_eq : Recipes.Unit, Recipes.Unit -> Bool
		is_eq = |left, right|
			match left {
				Grams => match right {
					Grams => True
					_ => False
				}
				Millilitres => match right {
					Millilitres => True
					_ => False
				}
				Teaspoons => match right {
					Teaspoons => True
					_ => False
				}
				Pinches => match right {
					Pinches => True
					_ => False
				}
			}
	}

	## The unit system the quantities are displayed in.
	UnitSystem := [Metric, Imperial].{
		is_eq : Recipes.UnitSystem, Recipes.UnitSystem -> Bool
		is_eq = |left, right|
			match left {
				Metric => match right {
					Metric => True
					_ => False
				}
				Imperial => match right {
					Imperial => True
					_ => False
				}
			}
	}

	## Which control the target scale is taken from.
	ScaleMode := [ByServings, ByPan].{
		is_eq : Recipes.ScaleMode, Recipes.ScaleMode -> Bool
		is_eq = |left, right|
			match left {
				ByServings => match right {
					ByServings => True
					_ => False
				}
				ByPan => match right {
					ByPan => True
					_ => False
				}
			}
	}

	## The tin the finished dish is going into. `OwnTin` is the recipe's own,
	## which is the identity ratio rather than an area of its own.
	Pan := [OwnTin, Round20, Round24, Tray30].{
		is_eq : Recipes.Pan, Recipes.Pan -> Bool
		is_eq = |left, right|
			match left {
				OwnTin => match right {
					OwnTin => True
					_ => False
				}
				Round20 => match right {
					Round20 => True
					_ => False
				}
				Round24 => match right {
					Round24 => True
					_ => False
				}
				Tray30 => match right {
					Tray30 => True
					_ => False
				}
			}
	}

	## The wire code for a unit, as it appears in shopping-list keys and as the
	## metric display label.
	unit_code : Recipes.Unit -> Str
	unit_code = |unit|
		match unit {
			Grams => "g"
			Millilitres => "ml"
			Teaspoons => "tsp"
			Pinches => "pinch"
		}

	## Decode the unit-system radio value. This and `pan_from_str` /
	## `mode_from_str` are the only places a control's `Str` becomes a tag.
	system_from_str : Str -> Recipes.UnitSystem
	system_from_str = |value|
		if value == "imperial" {
			Imperial
		} else {
			Metric
		}

	## Decode the scale-mode radio value.
	mode_from_str : Str -> Recipes.ScaleMode
	mode_from_str = |value|
		if value == "pan" {
			ByPan
		} else {
			ByServings
		}

	## Decode the pan-size select value.
	pan_from_str : Str -> Recipes.Pan
	pan_from_str = |value|
		if value == "round20" {
			Round20
		} else if value == "round24" {
			Round24
		} else if value == "tray30" {
			Tray30
		} else {
			OwnTin
		}

	## An ingredient line, normalised to a per-serving amount so that the value
	## is independent of the current target servings.
	Ingredient : {
		slug : Str,
		name : Str,
		unit : Recipes.Unit,
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

	## An aggregated shopping-list line. `key` is `"<slug>-<unit code>"`, so the
	## same ingredient in two different units stays on two separate lines.
	ShoppingLine : {
		key : Str,
		name : Str,
		unit : Recipes.Unit,
		per_serving : U64,
		sources : U64,
	}

	## Build a per-serving ingredient from a printed amount in whole canonical
	## units and the recipe's own base serving count.
	ingredient : Str, Str, Recipes.Unit, U64, U64 -> Ingredient
	ingredient = |slug, name, unit, amount, base_servings| {
		micro : U64
		micro = amount * 1_000_000
		{ slug, name, unit, per_serving: micro / base_servings }
	}

	pancakes : Recipe
	pancakes = {
		id: "pancakes",
		title: "Buttermilk Pancakes",
		base_servings: 4,
		base_area: 452,
		ingredients: [
			ingredient("flour", "Plain flour", Grams, 200, 4),
			ingredient("buttermilk", "Buttermilk", Millilitres, 300, 4),
			ingredient("butter", "Butter", Grams, 50, 4),
			ingredient("baking-powder", "Baking powder", Teaspoons, 2, 4),
			ingredient("salt", "Salt", Pinches, 1, 4),
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
			ingredient("tomatoes", "Tomatoes", Grams, 900, 3),
			ingredient("stock", "Vegetable stock", Millilitres, 500, 3),
			ingredient("butter", "Butter", Teaspoons, 3, 3),
			ingredient("salt", "Salt", Pinches, 2, 3),
		],
	}

	bread : Recipe
	bread = {
		id: "bread",
		title: "Seeded Bread Loaf",
		base_servings: 8,
		base_area: 600,
		ingredients: [
			ingredient("flour", "Plain flour", Grams, 500, 8),
			ingredient("water", "Water", Millilitres, 320, 8),
			ingredient("butter", "Butter", Grams, 20, 8),
			ingredient("salt", "Salt", Pinches, 1, 8),
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

	## Area in cm^2 of the tin a pan-size option names. `OwnTin` has no area of
	## its own: it is whatever the recipe was printed for.
	pan_area : Recipes.Pan -> Try(U64, [OwnTin])
	pan_area = |pan|
		match pan {
			Round20 => Ok(314)
			Round24 => Ok(452)
			Tray30 => Ok(600)
			OwnTin => Err(OwnTin)
		}

	## Human label for a pan size, phrased for the summary note.
	pan_label : Recipes.Pan -> Str
	pan_label = |pan|
		match pan {
			Round20 => "a 20 cm round tin"
			Round24 => "a 24 cm round tin"
			Tray30 => "a 30x20 cm tray"
			OwnTin => "the recipe's own tin"
		}

	## Parse the servings draft. `Err(Invalid)` means the draft is not a whole
	## number in the supported range; the caller decides what to show instead.
	##
	## The digit and length checks come first so that the only strings reaching
	## `U64.from_str` are the ones this app calls a serving count: no sign, no
	## whitespace inside, at most three digits.
	parse_servings : Str -> Try(U64, [Invalid])
	parse_servings = |draft| {
		trimmed = draft.trim()
		digits = trimmed.to_utf8()
		if digits.is_empty() or digits.len() > 3 or !digits.all(|byte| byte >= 48 and byte <= 57) {
			Err(Invalid)
		} else {
			servings = U64.from_str(trimmed).map_err(|_| Invalid)?
			if servings <= 96 {
				Ok(servings)
			} else {
				Err(Invalid)
			}
		}
	}

	# The draft box is deliberately strict: only 1-3 ASCII digits, and only up
	# to the 96-serving ceiling the hint promises.

	## A bare run of digits is the ordinary accepted draft.
	expect parse_servings("4") == Ok(4)

	## Surrounding whitespace is trimmed away before the digits are read.
	expect parse_servings(" 12 ") == Ok(12)

	## Leading zeros are padding, not a different number.
	expect parse_servings("007") == Ok(7)

	## Zero servings is a valid request, not a parse failure.
	expect parse_servings("0") == Ok(0)

	## The 96-serving ceiling the hint promises is itself accepted.
	expect parse_servings("96") == Ok(96)

	## One serving past the ceiling is rejected rather than clamped.
	expect parse_servings("97") == Err(Invalid)

	## An empty draft is not a serving count.
	expect parse_servings("") == Err(Invalid)

	## A word is rejected outright instead of reading as zero.
	expect parse_servings("two") == Err(Invalid)

	## A single trailing non-digit rejects the whole draft.
	expect parse_servings("1x") == Err(Invalid)

	## Three digits still fail once the value is past the ceiling.
	expect parse_servings("999") == Err(Invalid)

	## Four digits are rejected on length before the value is even read.
	expect parse_servings("1000") == Err(Invalid)

	## Target scale in milli-servings.
	##
	## In `ByServings` mode this is the parsed servings box; when the draft is
	## not a whole number the recipe's own base servings are used instead so the
	## page keeps showing a usable recipe while the warning is visible.
	## In `ByPan` mode the servings box is ignored and the scale comes from the
	## ratio between the chosen tin area and the recipe's own tin area.
	scale_milli : Recipe, Recipes.ScaleMode, Str, Recipes.Pan -> U64
	scale_milli = |recipe, mode, draft, pan| {
		base = recipe.base_servings * 1000
		match mode {
			ByPan => match pan_area(pan) {
				Ok(area) => base * area / recipe.base_area
				Err(OwnTin) => base
			}
			ByServings => parse_servings(draft).map_ok(|servings| servings * 1000) ?? base
		}
	}

	## Scaled amount in milli-units of the ingredient's canonical unit.
	scaled_milli : U64, U64 -> U64
	scaled_milli = |per_serving, scale| per_serving * scale / 1_000_000

	## Convert a canonical milli-amount into the displayed unit system.
	## `tsp` and `pinch` are the same in both systems and are returned unchanged.
	convert : Recipes.Unit, Recipes.UnitSystem, U64 -> { amount : U64, label : Str }
	convert = |unit, system, milli|
		match system {
			Imperial => match unit {
				Grams => { amount: milli * 1000 / 28350, label: "oz" }
				Millilitres => { amount: milli * 1000 / 29574, label: "fl oz" }
				Teaspoons => { amount: milli, label: "tsp" }
				Pinches => { amount: milli, label: "pinch" }
			}
			Metric => { amount: milli, label: unit_code(unit) }
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

	## A whole amount renders with no decimal point at all.
	expect format_amount(200_000) == "200"

	## A trailing zero in the hundredths is dropped rather than printed.
	expect format_amount(37_500) == "37.5"

	## A repeating fraction is rounded to hundredths, not truncated.
	expect format_amount(666_666) == "666.67"

	## Zero renders bare, so an empty scale reads as "0" and not "0.00".
	expect format_amount(0) == "0"

	## A hundredths value below ten keeps its leading zero.
	expect format_amount(1_050) == "1.05"

	## The full display string for one ingredient line.
	quantity_text : U64, Recipes.Unit, U64, Recipes.UnitSystem -> Str
	quantity_text = |per_serving, unit, scale, system| {
		converted = convert(unit, system, scaled_milli(per_serving, scale))
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

	## At the recipe's own servings a metric line reproduces the printed amount.
	expect quantity_text(50_000_000, Grams, 4000, Metric) == "200 g"

	## The same line in imperial converts grams to ounces and relabels it.
	expect quantity_text(50_000_000, Grams, 4000, Imperial) == "7.05 oz"

	## Teaspoons are shared by both systems, so imperial leaves them alone.
	expect quantity_text(500_000, Teaspoons, 4000, Imperial) == "2 tsp"

	## Pan scaling is an area ratio, so it can land between whole servings.
	expect scale_milli(pancakes, ByPan, "20", Tray30) == 5309

	## The recipe's own tin is the identity ratio, not an area of its own.
	expect scale_milli(pancakes, ByPan, "20", OwnTin) == 4000

	## An unparseable servings draft falls back to the recipe's base servings.
	expect scale_milli(pancakes, ByServings, "two", OwnTin) == 4000

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
							key: "${item.slug}-${unit_code(item.unit)}",
							name: item.name,
							unit: item.unit,
							per_serving: item.per_serving,
							sources: 1,
						},
					),
			)
			.join()

		contributions.fold([], merge_line)
	}
}
