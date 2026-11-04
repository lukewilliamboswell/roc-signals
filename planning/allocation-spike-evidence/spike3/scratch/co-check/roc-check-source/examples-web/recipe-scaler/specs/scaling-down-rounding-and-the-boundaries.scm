(test "Recipe scaler — Scaling down, rounding, and the boundaries"
  (steps
    ; Given the state established by earlier scenarios
    (check (label "Include Buttermilk Pancakes"))
    (check (label "Include Seeded Bread Loaf"))
    (check (label "Include Roasted Tomato Soup"))
    (mark-metrics)
    (fill (label "Target servings") "8")

    ; Scaling down, rounding, and the boundaries

    (fill (label "Target servings") "3")
    (expect-text (test-id "effective-servings") "3")
    (expect-text (test-id "ing-qty-flour") "150 g")
    (expect-text (test-id "ing-qty-buttermilk") "225 ml")
    ; Fractional results are rounded to hundredths, trailing zeros trimmed.
    (expect-text (test-id "ing-qty-butter") "37.5 g")
    (expect-text (test-id "ing-qty-baking-powder") "1.5 tsp")
    (expect-text (test-id "ing-qty-salt") "0.75 pinch")
    (fill (label "Target servings") "1")
    (expect-text (test-id "effective-servings") "1")
    (expect-text (test-id "scale-note") "Scaled from the recipe's 4 servings.")
    (expect-text (test-id "ing-qty-flour") "50 g")
    (expect-text (test-id "ing-qty-buttermilk") "75 ml")
    (expect-text (test-id "ing-qty-butter") "12.5 g")
    (expect-text (test-id "ing-qty-baking-powder") "0.5 tsp")
    (expect-text (test-id "ing-qty-salt") "0.25 pinch")
    ; Zero servings is a valid target, not an error: every quantity becomes zero,
    ; the units are still shown, and no row disappears.
    (fill (label "Target servings") "0")
    (expect-text (test-id "effective-servings") "0")
    (expect-text (test-id "scale-note") "Nothing to make at 0 servings: every quantity is 0.")
    (expect-text (test-id "ing-qty-flour") "0 g")
    (expect-text (test-id "ing-qty-buttermilk") "0 ml")
    (expect-text (test-id "ing-qty-butter") "0 g")
    (expect-text (test-id "ing-qty-baking-powder") "0 tsp")
    (expect-text (test-id "ing-qty-salt") "0 pinch")
    (expect-text (test-id "shop-qty-flour-g") "0 g")
    (expect-text (test-id "shop-qty-stock-ml") "0 ml")
    (expect-text (test-id "shopping-count") "9 lines from 3 recipes")
    ; Invalid drafts keep the draft in the box but fall back to the recipe's own
    ; serving count so the page still shows a usable recipe.
    (fill (label "Target servings") "two")
    (expect-value (label "Target servings") "two")
    (expect-text (test-id "effective-servings") "4")
    (expect-text (test-id "scale-note") "Servings must be a whole number from 0 to 96. Showing the recipe's own 4 servings.")
    (expect-text (test-id "ing-qty-flour") "200 g")
    (fill (label "Target servings") "")
    (expect-text (test-id "effective-servings") "4")
    (expect-text (test-id "scale-note") "Servings must be a whole number from 0 to 96. Showing the recipe's own 4 servings.")
    (fill (label "Target servings") "999")
    (expect-text (test-id "effective-servings") "4")
    (expect-text (test-id "scale-note") "Servings must be a whole number from 0 to 96. Showing the recipe's own 4 servings.")
    (fill (label "Target servings") "4")
    (expect-text (test-id "effective-servings") "4")
    (expect-text (test-id "scale-note") "Unscaled: this is the recipe as printed.")
    (expect-text (test-id "ing-qty-flour") "200 g")
  )
)
