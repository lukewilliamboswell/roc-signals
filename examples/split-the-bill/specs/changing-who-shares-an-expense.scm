(test "Split the bill — changing who shares an expense"
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

    ; changing who shares an expense

    (uncheck (label "Cabin includes Cy"))
    (expect-checked (label "Cabin includes Cy") false)
    (expect-text (test-id "expense-Cabin-status") "Status: $300.00 paid by Ana, split 2 ways")
    (expect-text (test-id "expense-Cabin-shares") "Shares: Ana $150.00, Bo $150.00")
    (expect-text (test-id "person-Cy-totals") "Totals: paid $24.00, owes $32.83")
    (expect-text (test-id "trip-balances-check") "Balances check: $0.00")
    (expect-text (test-id "transfer-Bo>Ana") "Bo owes Ana $120.33")
    (expect-text (test-id "transfer-Cy>Ana") "Cy owes Ana $8.83")
    (check (label "Cabin includes Cy"))
    (expect-checked (label "Cabin includes Cy") true)
    (expect-text (test-id "expense-Cabin-shares") "Shares: Ana $100.00, Bo $100.00, Cy $100.00")
    ; An expense nobody shares is excluded entirely, payer included, so the plan
    ; still balances.
    (uncheck (label "Taxi includes Bo"))
    (uncheck (label "Taxi includes Cy"))
    (expect-text (test-id "expense-Taxi-status") "Status: nobody is sharing it, excluded")
    (expect-text (test-id "expense-Taxi-shares") "Shares: none")
    (expect-text (test-id "trip-total") "Trip total: $362.50")
    (expect-text (test-id "trip-balances-check") "Balances check: $0.00")
    (expect-text (test-id "person-Cy-totals") "Totals: paid $0.00, owes $120.83")
    ; Cy no longer pays for anything, so Cy may now leave the trip.
    (expect-text (test-id "person-Cy-removal") "Removal: allowed")
    (expect-disabled (role button :name "Remove Cy") false)
    (expect-text (test-id "transfer-Cy>Ana") "Cy owes Ana $120.83")
    (expect-text (test-id "transfer-Bo>Ana") "Bo owes Ana $58.33")
    (check (label "Taxi includes Bo"))
    (check (label "Taxi includes Cy"))
    (expect-text (test-id "expense-Taxi-shares") "Shares: Bo $12.00, Cy $12.00")
    (expect-text (test-id "person-Cy-removal") "Removal: blocked, payer on 1 expense")
    (expect-text (test-id "trip-total") "Trip total: $386.50")
  )
)
