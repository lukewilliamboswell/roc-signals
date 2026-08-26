(test "Loan comparator — a rate of zero"
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

    ; 6. a rate of zero

    (fill (label "Scenario A annual rate") "0")
    (expect-text (test-id "a-rate") "Scenario A rate: 0.00%")
    (expect-text (test-id "a-payment") "Scenario A monthly payment: $200.00")
    (expect-text (test-id "a-total-interest") "Scenario A total interest: $0.00")
    (expect-text (test-id "a-total-paid") "Scenario A total paid: $2400.00")
    (expect-text (test-id "a-payoff") "Scenario A payoff: 12 months")
    (expect-text (test-id "a-final-balance") "Scenario A final balance: $0.00")
    (expect-text (test-id "a-month-1") "Scenario A month 1: interest $0.00, principal $200.00, balance $2200.00")
    (expect-text (test-id "a-month-12") "Scenario A month 12: interest $0.00, principal $200.00, balance $0.00")
    (expect-text (test-id "schedule-invariant") "Schedule invariant: all final balances are $0.00")
  )
)
