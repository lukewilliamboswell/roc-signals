(test "Loan comparator — an extra payment large enough to shorten the schedule"
  (steps
    ; Given the state established by earlier scenarios
    (select-option (label "Comparison pair") "ac")
    (select-option (label "Comparison pair") "bc")
    (select-option (label "Comparison pair") "ac")
    (mark-metrics)
    (fill (label "Scenario A annual rate") "3")

    ; 4. an extra payment large enough to shorten the schedule

    (mark-metrics)
    (fill (label "Scenario A extra payment") "50")
    (expect-text (test-id "a-payment") "Scenario A monthly payment: $253.27")
    (expect-text (test-id "a-total-interest") "Scenario A total interest: $31.97")
    (expect-text (test-id "a-payoff") "Scenario A payoff: 10 months")
    (expect-text (test-id "a-final-balance") "Scenario A final balance: $0.00")
    (expect-text (test-id "a-month-10") "Scenario A month 10: interest $0.38, principal $152.16, balance $0.00")
    (expect-absent (test-id "a-month-11"))
    (expect-text (test-id "summary-a") "Scenario A summary: $253.27 per month for 10 months, interest $31.97")
    (expect-text (test-id "break-even") "Break-even (Scenario A vs Scenario C): month 23")
    (expect-metric-delta rows_removed 2)
    (expect-metric-delta rows_created 0)
    ; B's and C's rows are untouched.
    (expect-text (test-id "b-month-12") "Scenario B month 12: interest $2.11, principal $211.03, balance $0.00")
    (expect-text (test-id "c-month-24") "Scenario C month 24: interest $0.52, principal $105.68, balance $0.00")
  )
)
