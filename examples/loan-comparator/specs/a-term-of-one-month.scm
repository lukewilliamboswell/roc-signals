(test "Loan comparator — a term of one month"
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

    ; 7. a term of one month

    (fill (label "Scenario A term months") "1")
    (expect-text (test-id "a-payment") "$2400.00")
    (expect-text (test-id "a-payoff") "1 month")
    (expect-text (test-id "a-final-balance") "$0.00")
    (expect-text (test-id "a-month-1") "Month 1 | interest $0.00 | principal $2400.00 | balance $0.00")
    (expect-absent (test-id "a-month-2"))
    (expect-text (test-id "summary-a") "$2400.00 / mo, 1 month, $0.00 interest")
  )
)
