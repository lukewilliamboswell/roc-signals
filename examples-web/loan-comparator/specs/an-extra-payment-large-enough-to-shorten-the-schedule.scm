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
    (expect-text (test-id "a-payment") "$253.27")
    (expect-text (test-id "a-total-interest") "$31.97")
    (expect-text (test-id "a-payoff") "10 months")
    (expect-text (test-id "a-final-balance") "$0.00")
    (expect-text (test-id "a-month-10") "Month 10 | interest $0.38 | principal $152.16 | balance $0.00")
    (expect-absent (test-id "a-month-11"))
    (expect-text (test-id "summary-a") "$253.27 / mo, 10 months, $31.97 interest")
    (expect-text (test-id "break-even") "Month 23")
    (expect-metric-delta rows_removed 2)
    (expect-metric-delta rows_created 0)
    ; B's and C's rows are untouched.
    (expect-text (test-id "b-month-12") "Month 12 | interest $2.11 | principal $211.03 | balance $0.00")
    (expect-text (test-id "c-month-24") "Month 24 | interest $0.52 | principal $105.68 | balance $0.00")
  )
)
