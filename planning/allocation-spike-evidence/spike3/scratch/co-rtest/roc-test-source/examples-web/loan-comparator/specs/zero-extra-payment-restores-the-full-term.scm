(test "Loan comparator — zero extra payment restores the full term"
  (steps
    ; Given the state established by earlier scenarios
    (select-option (label "Comparison pair") "ac")
    (select-option (label "Comparison pair") "bc")
    (select-option (label "Comparison pair") "ac")
    (mark-metrics)
    (fill (label "Scenario A annual rate") "3")
    (mark-metrics)
    (fill (label "Scenario A extra payment") "50")

    ; 5. zero extra payment restores the full term

    (mark-metrics)
    (fill (label "Scenario A extra payment") "0")
    (expect-text (test-id "a-payment") "$203.27")
    (expect-text (test-id "a-payoff") "12 months")
    (expect-text (test-id "a-month-12") "Month 12 | interest $0.50 | principal $202.65 | balance $0.00")
    (expect-metric-delta rows_created 2)
  )
)
