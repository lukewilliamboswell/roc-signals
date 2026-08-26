(test "Split the bill — rounding that does not divide evenly"
  (steps
    ; Given the state established by earlier scenarios
    (mark-metrics)
    (fill (label "Dinner amount") "90.00")

    ; rounding that does not divide evenly

    (fill (label "Dinner amount") "0.10")
    (expect-text (test-id "expense-Dinner-status") "Status: $0.10 paid by Bo, split 3 ways")
    (expect-text (test-id "expense-Dinner-shares") "Shares: Ana $0.04, Bo $0.03, Cy $0.03")
    (expect-text (test-id "trip-total") "Trip total: $324.10")
    (expect-text (test-id "trip-balances-check") "Balances check: $0.00")
    (expect-text (test-id "transfer-Bo>Ana") "Bo owes Ana $111.93")
    (expect-text (test-id "transfer-Cy>Ana") "Cy owes Ana $88.03")
  )
)
