(test "Split the bill — invalid amounts"
  (steps
    ; Given the state established by earlier scenarios
    (mark-metrics)
    (fill (label "Dinner amount") "90.00")
    (fill (label "Dinner amount") "0.10")

    ; invalid amounts

    (fill (label "Dinner amount") "12.345")
    (expect-text (test-id "expense-Dinner-status") "Amount not recognised, counted as $0.00")
    (expect-text (test-id "expense-Dinner-shares") "Ana $0.00, Ben $0.00, Chloe $0.00")
    (expect-text (test-id "trip-total") "$324.00")
    (expect-text (test-id "trip-balances-check") "$0.00")
    (expect-text (test-id "transfer-Ben>Ana") "Ben pays Ana")
    (expect-text (test-id "transfer-Ben>Ana-amount") "$112.00")
    (expect-text (test-id "transfer-Chloe>Ana") "Chloe pays Ana")
    (expect-text (test-id "transfer-Chloe>Ana-amount") "$88.00")
    (fill (label "Dinner amount") "-5")
    (expect-text (test-id "expense-Dinner-status") "Amount not recognised, counted as $0.00")
    (fill (label "Dinner amount") "")
    (expect-text (test-id "expense-Dinner-status") "Amount not recognised, counted as $0.00")
    ; A zero amount is valid, not an error.
    (fill (label "Dinner amount") "0")
    (expect-text (test-id "expense-Dinner-status") "$0.00 paid by Ben, split 3 ways")
    (expect-text (test-id "expense-Dinner-shares") "Ana $0.00, Ben $0.00, Chloe $0.00")
    (expect-text (test-id "trip-total") "$324.00")
    (expect-text (test-id "trip-balances-check") "$0.00")
    (fill (label "Dinner amount") "62.50")
    (expect-text (test-id "expense-Dinner-shares") "Ana $20.84, Ben $20.83, Chloe $20.83")
    (expect-text (test-id "trip-total") "$386.50")
  )
)
