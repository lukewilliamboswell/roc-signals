(test "Loan comparator — back to the baseline scenario A"
  (steps
    ; Given the state established by earlier scenarios
    (select-option (label "Comparison pair") "ac")
    (select-option (label "Comparison pair") "bc")
    (select-option (label "Comparison pair") "ac")
    (mark-metrics)
    (fill (label "Scenario A annual rate") "3")
    (mark-metrics)
    (fill (label "Scenario A extra payment") "50")
    (mark-metrics)
    (fill (label "Scenario A extra payment") "0")
    (fill (label "Scenario A annual rate") "0")
    (fill (label "Scenario A term months") "1")
    (fill (label "Scenario A principal") "0")

    ; 9. back to the baseline scenario A

    (fill (label "Scenario A principal") "2400")
    (fill (label "Scenario A term months") "12")
    (fill (label "Scenario A annual rate") "6")
    (expect-text (test-id "a-payment") "Scenario A monthly payment: $206.56")
    (expect-text (test-id "a-total-interest") "Scenario A total interest: $78.62")
    (expect-text (test-id "a-month-12") "Scenario A month 12: interest $1.02, principal $205.44, balance $0.00")
    (expect-text (test-id "break-even") "Break-even (Scenario A vs Scenario C): month 24")
  )
)
