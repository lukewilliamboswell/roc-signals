(test "Loan comparator — editing scenario A's rate: derived figures follow, siblings do not"
  (steps
    ; Given the state established by earlier scenarios
    (select-option (label "Comparison pair") "ac")
    (select-option (label "Comparison pair") "bc")
    (select-option (label "Comparison pair") "ac")

    ; 3. editing scenario A's rate: derived figures follow, siblings do not
    ;
    ; The schedule for A is one derived signal read by the payment, interest, paid,
    ; payoff, final-balance, row-list and comparison sinks. Editing A's rate must
    ; recompute A's schedule once and must not recompute B's or C's schedules at all.

    (mark-metrics)
    (fill (label "Scenario A annual rate") "3")
    (expect-text (test-id "a-rate") "Scenario A rate: 3.00%")
    (expect-text (test-id "a-payment") "Scenario A monthly payment: $203.27")
    (expect-text (test-id "a-total-interest") "Scenario A total interest: $39.12")
    (expect-text (test-id "a-total-paid") "Scenario A total paid: $2439.12")
    (expect-text (test-id "a-payoff") "Scenario A payoff: 12 months")
    (expect-text (test-id "a-final-balance") "Scenario A final balance: $0.00")
    (expect-text (test-id "a-month-1") "Scenario A month 1: interest $6.00, principal $197.27, balance $2202.73")
    (expect-text (test-id "a-month-12") "Scenario A month 12: interest $0.50, principal $202.65, balance $0.00")
    ; B and C are untouched by A's edit.
    (expect-text (test-id "b-payment") "Scenario B monthly payment: $213.24")
    (expect-text (test-id "b-month-1") "Scenario B month 1: interest $24.00, principal $189.24, balance $2210.76")
    (expect-text (test-id "c-month-1") "Scenario C month 1: interest $12.00, principal $94.37, balance $2305.63")
    ; A keeps 12 rows, so no row is created or removed anywhere, and only A's 12
    ; schedule rows plus the 3 summary rows are re-synced.
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta rows_reused 15)
    (expect-metric-delta scopes_created 0)
    (expect-metric-delta scopes_disposed 0)
    (expect-metric-delta dirty_source_roots 1)
    ; 38 derived transforms run: scenario A's whole chain (draft -> parsed ->
    ; params -> schedule -> summary), A's five figure sinks, A's twelve row texts,
    ; and the four cross-scenario nodes. Scenario B's and C's schedules are NOT
    ; among them - recomputing them too would cost roughly forty more calls.
    (expect-metric-delta derived_calls_into_roc 37)
    (expect-metric-delta-at-most patches_emitted 21)
    ; The break-even month moves because A's rate changed.
    (expect-text (test-id "break-even") "Break-even (Scenario A vs Scenario C): month 23")
    (expect-text (test-id "cheapest") "Cheapest: Scenario A at $39.12 total interest")
    (expect-text (test-id "interest-spread") "Interest spread: $119.66")
  )
)
