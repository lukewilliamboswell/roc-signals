(test "Recipe scaler — Switching recipe: this IS structural"
  (steps
    ; Given the state established by earlier scenarios
    (check (label "Include Buttermilk Pancakes"))
    (check (label "Include Seeded Bread Loaf"))
    (check (label "Include Roasted Tomato Soup"))
    (mark-metrics)
    (fill (label "Target servings") "8")
    (fill (label "Target servings") "3")
    (fill (label "Target servings") "1")
    (fill (label "Target servings") "0")
    (fill (label "Target servings") "two")
    (fill (label "Target servings") "")
    (fill (label "Target servings") "999")
    (fill (label "Target servings") "4")
    (mark-metrics)
    (real-click (label "Imperial units"))
    (real-click (label "Metric units"))
    (real-click (label "Scale by pan size"))
    (select-option (label "Pan size") "tray30")
    (fill (label "Target servings") "20")
    (select-option (label "Pan size") "round20")
    (real-click (label "Scale by servings"))
    (select-option (label "Pan size") "recipe")
    (fill (label "Target servings") "2")

    ; Switching recipe: this IS structural

    ; Pancakes and soup share the keys "butter" and "salt", so those rows survive;
    ; the rest are created and removed.
    (mark-metrics)
    (select-option (label "Recipe") "soup")
    (expect-metric-delta rows_created 2)
    (expect-metric-delta rows_reused 2)
    (expect-metric-delta rows_removed 3)
    (expect-text (test-id "recipe-title") "Roasted Tomato Soup")
    (expect-text (test-id "controls-summary") "Controls: soup / servings / recipe / metric")
    (expect-text (test-id "scale-note") "Scaled from the recipe's 3 servings.")
    (expect-absent (test-id "ing-qty-flour"))
    (expect-absent (test-id "ing-qty-buttermilk"))
    (expect-absent (test-id "ing-qty-baking-powder"))
    (expect-text (test-id "ing-name-tomatoes") "Tomatoes")
    (expect-text (test-id "ing-qty-tomatoes") "600 g")
    ; 500 ml over 3 base servings scaled to 2 is a repeating fraction.
    (expect-text (test-id "ing-qty-stock") "333.33 ml")
    (expect-text (test-id "ing-qty-butter") "2 tsp")
    (expect-text (test-id "ing-qty-salt") "1.33 pinch")
    ; The shopping list is independent of which recipe is on screen.
    (expect-text (test-id "shopping-count") "Shopping list: 9 lines from 3 recipes")
    (expect-text (test-id "shop-qty-flour-g") "225 g")
  )
)
