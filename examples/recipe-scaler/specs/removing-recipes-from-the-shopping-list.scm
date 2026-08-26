(test "Recipe scaler — Removing recipes from the shopping list"
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
    (mark-metrics)
    (select-option (label "Recipe") "soup")

    ; Removing recipes from the shopping list

    ; Removing one recipe rewrites only the lines it contributed to; sibling lines
    ; that it never touched keep their exact values.
    (uncheck (label "Include Seeded Bread Loaf"))
    (expect-checked (label "Include Seeded Bread Loaf") false)
    (expect-text (test-id "shopping-count") "Shopping list: 8 lines from 2 recipes")
    (expect-absent (test-id "shop-qty-water-ml"))
    (expect-text (test-id "shop-name-flour-g") "Plain flour")
    (expect-text (test-id "shop-qty-flour-g") "100 g")
    (expect-text (test-id "shop-name-butter-g") "Butter")
    (expect-text (test-id "shop-qty-butter-g") "25 g")
    ; Untouched siblings.
    (expect-text (test-id "shop-qty-buttermilk-ml") "150 ml")
    (expect-text (test-id "shop-qty-tomatoes-g") "600 g")
    (expect-text (test-id "shop-qty-butter-tsp") "2 tsp")
    (uncheck (label "Include Roasted Tomato Soup"))
    (expect-text (test-id "shopping-count") "Shopping list: 5 lines from 1 recipes")
    (expect-absent (test-id "shop-qty-butter-tsp"))
    (expect-absent (test-id "shop-qty-tomatoes-g"))
    (expect-text (test-id "shop-qty-flour-g") "100 g")
    ; Back to an empty list. The Ui.when branch flips, so the whole rows subtree is
    ; disposed as scopes rather than as row removals: scopes_disposed 6 is the
    ; each_str scope plus its five row scopes, and rows_removed stays 0.
    (mark-metrics)
    (uncheck (label "Include Buttermilk Pancakes"))
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_reused 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta scopes_created 1)
    (expect-metric-delta scopes_disposed 6)
    (expect-text (test-id "shopping-count") "Shopping list: 0 lines from 0 recipes")
    (expect-visible (test-id "shopping-empty"))
    (expect-absent (test-id "shopping-rows"))
    ; The ingredient panel is untouched by shopping-list churn.
    (expect-text (test-id "recipe-title") "Roasted Tomato Soup")
    (expect-text (test-id "ing-qty-tomatoes") "600 g")
    (expect-text (test-id "ing-qty-stock") "333.33 ml")
  )
)
