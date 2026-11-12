(test "an accepted order is counted and starts the basket again; a refused one keeps it"
  (steps
    ; Nothing in the cart: the decision returns no write and nothing is sent.
    (click (role button :name "Check out"))
    (expect-pending-effects 0)
    (expect-text (test-id "notice") "Welcome.")
    (click (role button :name "Add Tea"))
    (click (role button :name "Add Jam"))
    (click (role button :name "Cart (2)"))
    (fill (label "Note for the courier") "Leave it by the door")
    (expect-text (test-id "total") "Total 9")
    ; The server refuses the first order.
    (click (role button :name "Check out"))
    (expect-text (test-id "notice") "Sending your order.")
    (expect-pending-effects 1)
    (stub-http "refused" :url "/api/orders" :status 503 :body "")
    (run-effect 1)
    (expect-text (test-id "notice") "The order was not placed. Your cart is as it was.")
    (expect-text (test-id "orders") "Orders placed: 0")
    (expect-visible (role button :name "Cart (2)"))
    ; Sending the same total again is a second request, and it is accepted.
    (click (role button :name "Check out"))
    (stub-http "placed" :url "/api/orders" :status 201 :body "")
    (run-effect 2)
    (expect-text (test-id "notice") "Order placed for 9.")
    (expect-text (test-id "orders") "Orders placed: 1")
    (expect-visible (role button :name "Cart (0)"))
    (expect-text (label "Tea in cart") "0 in cart")
    ; The note started again with the cart: one reset wrote both.
    (expect-value (label "Note for the courier") "")))
