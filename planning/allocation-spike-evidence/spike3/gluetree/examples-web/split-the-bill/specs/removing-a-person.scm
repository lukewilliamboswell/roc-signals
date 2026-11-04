(test "Split the bill — removing a person"
  (steps
    ; Given the state established by earlier scenarios
    (mark-metrics)
    (fill (label "Dinner amount") "90.00")
    (fill (label "Dinner amount") "0.10")
    (fill (label "Dinner amount") "12.345")
    (fill (label "Dinner amount") "-5")
    (fill (label "Dinner amount") "")
    (fill (label "Dinner amount") "0")
    (fill (label "Dinner amount") "62.50")
    (uncheck (label "Cabin includes Chloe"))
    (check (label "Cabin includes Chloe"))
    (uncheck (label "Taxi includes Ben"))
    (uncheck (label "Taxi includes Chloe"))
    (check (label "Taxi includes Ben"))
    (check (label "Taxi includes Chloe"))
    (fill (label "New person name") "Ana")
    (fill (label "New person name") " Di ")
    (mark-metrics)
    (click (role button :name "Add person"))

    ; removing a person

    (expect-disabled (role button :name "Remove Di") false)
    (click (role button :name "Remove Di"))
    (expect-absent (role region :name "Di"))
    (expect-text (test-id "trip-people-count") "3")
    (expect-text (test-id "expense-Cabin-shares") "Ana $100.00, Ben $100.00, Chloe $100.00")
    (expect-text (test-id "expense-Taxi-shares") "Ben $12.00, Chloe $12.00")
    (expect-text (test-id "trip-balances-check") "$0.00")
    (expect-text (test-id "settlement-summary") "2 transfers")
  )
)
