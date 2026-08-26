(test "Recipe scaler — Building the shopping list"
  (steps
    ; Building the shopping list

    ; One recipe: every line comes from a single source.
    (check (label "Include Buttermilk Pancakes"))
    (expect-checked (label "Include Buttermilk Pancakes") true)
    (expect-visible (test-id "shopping-rows"))
    (expect-absent (test-id "shopping-empty"))
    (expect-text (test-id "shopping-count") "Shopping list: 5 lines from 1 recipes")
    (expect-text (test-id "shop-name-flour-g") "Plain flour")
    (expect-text (test-id "shop-qty-flour-g") "200 g")
    (expect-text (test-id "shop-name-butter-g") "Butter")
    (expect-text (test-id "shop-qty-butter-g") "50 g")
    (expect-text (test-id "shop-qty-salt-pinch") "1 pinch")
    ; A second recipe: shared ingredients in the same unit aggregate into one line.
    (check (label "Include Seeded Bread Loaf"))
    (expect-text (test-id "shopping-count") "Shopping list: 6 lines from 2 recipes")
    (expect-text (test-id "shop-name-flour-g") "Plain flour (2 recipes)")
    (expect-text (test-id "shop-qty-flour-g") "450 g")
    (expect-text (test-id "shop-name-butter-g") "Butter (2 recipes)")
    (expect-text (test-id "shop-qty-butter-g") "60 g")
    (expect-text (test-id "shop-name-salt-pinch") "Salt (2 recipes)")
    (expect-text (test-id "shop-qty-salt-pinch") "1.5 pinch")
    (expect-text (test-id "shop-qty-water-ml") "160 ml")
    ; Unshared lines are untouched by the new recipe.
    (expect-text (test-id "shop-name-buttermilk-ml") "Buttermilk")
    (expect-text (test-id "shop-qty-buttermilk-ml") "300 ml")
    ; A third recipe brings Butter in teaspoons. Two recipes sharing an ingredient
    ; in different units must NOT aggregate: butter-g and butter-tsp stay separate.
    (check (label "Include Roasted Tomato Soup"))
    (expect-text (test-id "shopping-count") "Shopping list: 9 lines from 3 recipes")
    (expect-text (test-id "shop-name-butter-g") "Butter (2 recipes)")
    (expect-text (test-id "shop-qty-butter-g") "60 g")
    (expect-text (test-id "shop-name-butter-tsp") "Butter")
    (expect-text (test-id "shop-qty-butter-tsp") "4 tsp")
    (expect-text (test-id "shop-name-salt-pinch") "Salt (3 recipes)")
    (expect-text (test-id "shop-qty-salt-pinch") "4.17 pinch")
    (expect-text (test-id "shop-qty-tomatoes-g") "1200 g")
    ; Aggregating three per-serving amounts and rounding to hundredths.
    (expect-text (test-id "shop-qty-stock-ml") "666.67 ml")
  )
)
