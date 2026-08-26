(test "Split the bill — editing one expense reuses every row"
  (steps
    ; editing one expense reuses every row

    (mark-metrics)
    (fill (label "Dinner amount") "90.00")
    (expect-value (label "Dinner amount") "90.00")
    (expect-text (test-id "expense-Dinner-status") "Status: $90.00 paid by Bo, split 3 ways")
    (expect-text (test-id "expense-Dinner-shares") "Shares: Ana $30.00, Bo $30.00, Cy $30.00")
    ; Sibling rows keep their own values and identity.
    (expect-value (label "Cabin amount") "300.00")
    (expect-text (test-id "expense-Cabin-shares") "Shares: Ana $100.00, Bo $100.00, Cy $100.00")
    (expect-value (label "Taxi amount") "24.00")
    (expect-text (test-id "expense-Taxi-shares") "Shares: Bo $12.00, Cy $12.00")
    (expect-text (test-id "person-Ana-net") "Net: is owed $170.00")
    (expect-text (test-id "person-Bo-net") "Net: owes $52.00")
    (expect-text (test-id "person-Cy-net") "Net: owes $118.00")
    (expect-text (test-id "trip-total") "Trip total: $414.00")
    (expect-text (test-id "trip-balances-check") "Balances check: $0.00")
    (expect-text (test-id "transfer-Cy>Ana") "Cy owes Ana $118.00")
    (expect-text (test-id "transfer-Bo>Ana") "Bo owes Ana $52.00")
    ; Nothing structural happens: no row is created, removed, or re-scoped. The 11
    ; reused rows are the three expense rows, the three person rows, the two
    ; settlement rows, and the three participation checkboxes belonging to the one
    ; expense whose display record changed. Cabin's and Taxi's checkbox lists are
    ; not re-diffed at all, because their row values are unchanged.
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta scopes_created 0)
    (expect-metric-delta scopes_disposed 0)
    (expect-metric-delta rows_reused 11)
    (expect-metric-delta dirty_source_roots 1)
    (expect-metric-delta-at-most patches_emitted 27)
  )
)
