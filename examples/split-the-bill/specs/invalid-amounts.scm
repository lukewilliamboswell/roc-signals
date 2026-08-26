(test "Split the bill — invalid amounts"
  (steps
    ; Given the state established by earlier scenarios
    (mark-metrics)
    (fill (label "Dinner amount") "90.00")
    (fill (label "Dinner amount") "0.10")

    ; invalid amounts

    (fill (label "Dinner amount") "12.345")
    (expect-text (test-id "expense-Dinner-status") "Status: amount not recognised, treated as $0.00")
    (expect-text (test-id "expense-Dinner-shares") "Shares: Ana $0.00, Bo $0.00, Cy $0.00")
    (expect-text (test-id "trip-total") "Trip total: $324.00")
    (expect-text (test-id "trip-balances-check") "Balances check: $0.00")
    (expect-text (test-id "transfer-Bo>Ana") "Bo owes Ana $112.00")
    (expect-text (test-id "transfer-Cy>Ana") "Cy owes Ana $88.00")
    (fill (label "Dinner amount") "-5")
    (expect-text (test-id "expense-Dinner-status") "Status: amount not recognised, treated as $0.00")
    (fill (label "Dinner amount") "")
    (expect-text (test-id "expense-Dinner-status") "Status: amount not recognised, treated as $0.00")
    ; A zero amount is valid, not an error.
    (fill (label "Dinner amount") "0")
    (expect-text (test-id "expense-Dinner-status") "Status: $0.00 paid by Bo, split 3 ways")
    (expect-text (test-id "expense-Dinner-shares") "Shares: Ana $0.00, Bo $0.00, Cy $0.00")
    (expect-text (test-id "trip-total") "Trip total: $324.00")
    (expect-text (test-id "trip-balances-check") "Balances check: $0.00")
    (fill (label "Dinner amount") "62.50")
    (expect-text (test-id "expense-Dinner-shares") "Shares: Ana $20.84, Bo $20.83, Cy $20.83")
    (expect-text (test-id "trip-total") "Trip total: $386.50")
  )
)
