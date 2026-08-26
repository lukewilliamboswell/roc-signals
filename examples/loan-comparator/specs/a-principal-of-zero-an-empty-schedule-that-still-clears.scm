(test "Loan comparator — a principal of zero: an empty schedule that still clears"
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

    ; 8. a principal of zero: an empty schedule that still clears

    (fill (label "Scenario A principal") "0")
    (expect-text (test-id "a-inputs") "Scenario A inputs: inputs ok")
    (expect-text (test-id "a-payment") "Scenario A monthly payment: $0.00")
    (expect-text (test-id "a-total-interest") "Scenario A total interest: $0.00")
    (expect-text (test-id "a-total-paid") "Scenario A total paid: $0.00")
    (expect-text (test-id "a-payoff") "Scenario A payoff: 0 months")
    (expect-text (test-id "a-final-balance") "Scenario A final balance: $0.00")
    (expect-visible (role region :name "Scenario A schedule"))
    (expect-absent (test-id "a-month-1"))
    (expect-text (test-id "schedule-invariant") "Schedule invariant: all final balances are $0.00")
    (expect-text (test-id "break-even") "Break-even (Scenario A vs Scenario C): none")
    (expect-text (test-id "cheapest") "Cheapest: Scenario A at $0.00 total interest")
  )
)
