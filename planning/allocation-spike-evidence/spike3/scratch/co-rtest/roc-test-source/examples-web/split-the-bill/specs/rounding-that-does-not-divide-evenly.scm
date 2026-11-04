(test "Split the bill — rounding that does not divide evenly"
  (steps
    ; Given the state established by earlier scenarios
    (mark-metrics)
    (fill (label "Dinner amount") "90.00")

    ; rounding that does not divide evenly

    (fill (label "Dinner amount") "0.10")
    (expect-text (test-id "expense-Dinner-status") "$0.10 paid by Ben, split 3 ways")
    (expect-text (test-id "expense-Dinner-shares") "Ana $0.04, Ben $0.03, Chloe $0.03")
    (expect-text (test-id "trip-total") "$324.10")
    (expect-text (test-id "trip-balances-check") "$0.00")
    (expect-text (test-id "transfer-Ben>Ana") "Ben pays Ana")
    (expect-text (test-id "transfer-Ben>Ana-amount") "$111.93")
    (expect-text (test-id "transfer-Chloe>Ana") "Chloe pays Ana")
    (expect-text (test-id "transfer-Chloe>Ana-amount") "$88.03")
  )
)
