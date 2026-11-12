(test "adding from a row reaches every reader of the cart, and no one else"
  (steps
    (expect-text (test-id "notice") "Welcome.")
    (expect-text (label "Tea in cart") "0 in cart")
    (click (role button :name "Add Tea"))
    (click (role button :name "Add Bread"))
    ; One more Tea: the cart's button and Tea's own count change, and the
    ; notice goes back to Tea. Bread's and Jam's rows read the cart too,
    ; are evaluated and come out equal, so nothing is written for them.
    (mark-metrics)
    (click (role button :name "Add Tea"))
    (expect-metric-delta set_text 3)
    (expect-metric-delta create_element 0)
    (expect-text (test-id "notice") "Added Tea.")
    (expect-text (label "Tea in cart") "2 in cart")
    (expect-text (label "Bread in cart") "1 in cart")
    (expect-text (label "Jam in cart") "0 in cart")
    (expect-visible (role button :name "Cart (3)"))
    ; The count of orders reads neither cell: it is not evaluated at all.
    (expect-updates (test-id "orders") 1)))
