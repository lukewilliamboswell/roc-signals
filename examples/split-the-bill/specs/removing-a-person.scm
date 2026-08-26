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
    (uncheck (label "Cabin includes Cy"))
    (check (label "Cabin includes Cy"))
    (uncheck (label "Taxi includes Bo"))
    (uncheck (label "Taxi includes Cy"))
    (check (label "Taxi includes Bo"))
    (check (label "Taxi includes Cy"))
    (fill (label "New person name") "Ana")
    (fill (label "New person name") " Di ")
    (mark-metrics)
    (click (role button :name "Add person"))

    ; removing a person

    (expect-disabled (role button :name "Remove Di") false)
    (click (role button :name "Remove Di"))
    (expect-absent (role region :name "Di"))
    (expect-text (test-id "trip-people-count") "People on the trip: 3")
    (expect-text (test-id "expense-Cabin-shares") "Shares: Ana $100.00, Bo $100.00, Cy $100.00")
    (expect-text (test-id "expense-Taxi-shares") "Shares: Bo $12.00, Cy $12.00")
    (expect-text (test-id "trip-balances-check") "Balances check: $0.00")
    (expect-text (test-id "settlement-summary") "Settlement: 2 transfers")
  )
)
