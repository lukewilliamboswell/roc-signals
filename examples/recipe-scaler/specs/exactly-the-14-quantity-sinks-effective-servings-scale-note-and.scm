(test "Recipe scaler — exactly the 14 quantity sinks, effective servings, scale note, and the"
  (steps
    ; Given the state established by earlier scenarios
    (check (label "Include Buttermilk Pancakes"))
    (check (label "Include Seeded Bread Loaf"))
    (check (label "Include Roasted Tomato Soup"))

    ; exactly the 14 quantity sinks, effective servings, scale note, and the
    ; servings input value. Nothing structural.
    (mark-metrics)
    (fill (label "Target servings") "8")
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_reused 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta scopes_created 0)
    (expect-metric-delta scopes_disposed 0)
    (expect-metric-delta-at-most dirty_source_roots 4)
    (expect-metric-delta-at-most patches_emitted 20)
    (expect-text (test-id "effective-servings") "Effective servings: 8")
    (expect-text (test-id "scale-note") "Scaled from the recipe's 4 servings.")
    (expect-text (test-id "ing-qty-flour") "400 g")
    (expect-text (test-id "ing-qty-buttermilk") "600 ml")
    (expect-text (test-id "ing-qty-butter") "100 g")
    (expect-text (test-id "ing-qty-baking-powder") "4 tsp")
    (expect-text (test-id "ing-qty-salt") "2 pinch")
    (expect-text (test-id "shop-qty-flour-g") "900 g")
    (expect-text (test-id "shop-qty-stock-ml") "1333.33 ml")
    (expect-text (test-id "shop-qty-salt-pinch") "8.33 pinch")
    ; Structure is unchanged: the same nine lines, same count.
    (expect-text (test-id "shopping-count") "Shopping list: 9 lines from 3 recipes")
  )
)
