(test "Recipe scaler — The unit system toggle changes every convertible quantity"
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

    ; The unit system toggle changes every convertible quantity

    ; Same shape as the servings fan-out, but the equality cutoff shows through:
    ; observed patches_emitted 13, not 17, because the tsp and pinch sinks
    ; recompute to the same string and are never patched.
    (mark-metrics)
    (real-click (label "Imperial units"))
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_reused 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta scopes_created 0)
    (expect-metric-delta scopes_disposed 0)
    (expect-metric-delta-at-most dirty_source_roots 4)
    (expect-metric-delta-at-most patches_emitted 20)
    (expect-checked (label "Imperial units") true)
    (expect-checked (label "Metric units") false)
    (expect-text (test-id "unit-system") "Units: imperial (tsp and pinch are unchanged)")
    (expect-text (test-id "controls-summary") "Controls: pancakes / servings / recipe / imperial")
    (expect-text (test-id "ing-qty-flour") "7.05 oz")
    (expect-text (test-id "ing-qty-buttermilk") "10.14 fl oz")
    (expect-text (test-id "ing-qty-butter") "1.76 oz")
    ; tsp and pinch have no imperial counterpart, so they do not convert.
    (expect-text (test-id "ing-qty-baking-powder") "2 tsp")
    (expect-text (test-id "ing-qty-salt") "1 pinch")
    (expect-text (test-id "shop-qty-flour-g") "15.87 oz")
    (expect-text (test-id "shop-qty-tomatoes-g") "42.33 oz")
    (expect-text (test-id "shop-qty-stock-ml") "22.54 fl oz")
    (expect-text (test-id "shop-qty-butter-tsp") "4 tsp")
    (real-click (label "Metric units"))
    (expect-checked (label "Metric units") true)
    (expect-text (test-id "unit-system") "Units: metric (tsp and pinch are unchanged)")
    (expect-text (test-id "ing-qty-flour") "200 g")
    (expect-text (test-id "shop-qty-stock-ml") "666.67 ml")
  )
)
