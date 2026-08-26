(test "Loan comparator — switching the compared pair"
  (steps
    ; 2. switching the compared pair

    (select-option (label "Comparison pair") "ac")
    (expect-value (label "Comparison pair") "ac")
    (expect-text (test-id "break-even") "Month 24")
    (select-option (label "Comparison pair") "bc")
    (expect-text (test-id "break-even") "Never")
    (select-option (label "Comparison pair") "ac")
    (expect-text (test-id "break-even") "Month 24")
  )
)
