(test "emptying the cart closes its panel in the same event"
  (steps
    (click (role button :name "Add Tea"))
    (click (role button :name "Add Tea"))
    (click (role button :name "Add Bread"))
    (click (role button :name "Cart (3)"))
    (expect-text (test-id "total") "Total 11")
    ; A line's button writes the cart from inside a row of the panel.
    (click (role button :name "Remove Bread"))
    (expect-text (test-id "total") "Total 8")
    (expect-text (label "Bread in cart") "0 in cart")
    ; One click, two writes: the panel's own state and the cart's cell.
    (click (role button :name "Empty cart"))
    (expect-absent (test-id "total"))
    (expect-visible (role button :name "Cart (0)"))
    (expect-text (label "Tea in cart") "0 in cart")))
