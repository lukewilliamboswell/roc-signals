(test "Loan comparator — switching the compared pair"
  (steps
    ; 2. switching the compared pair

    (select-option (label "Comparison pair") "ac")
    (expect-value (label "Comparison pair") "ac")
    (expect-text (test-id "break-even") "Break-even (Scenario A vs Scenario C): month 24")
    (select-option (label "Comparison pair") "bc")
    (expect-text (test-id "break-even") "Break-even (Scenario B vs Scenario C): none")
    (select-option (label "Comparison pair") "ac")
    (expect-text (test-id "break-even") "Break-even (Scenario A vs Scenario C): month 24")
  )
)
