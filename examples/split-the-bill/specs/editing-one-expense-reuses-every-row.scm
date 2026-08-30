(test "Split the bill — editing one expense reuses every row"
  (steps
    ; editing one expense reuses every row

    (mark-metrics)
    (fill (label "Dinner amount") "90.00")
    (expect-value (label "Dinner amount") "90.00")
    (expect-text (test-id "expense-Dinner-status") "$90.00 paid by Ben, split 3 ways")
    (expect-text (test-id "expense-Dinner-shares") "Ana $30.00, Ben $30.00, Chloe $30.00")
    ; Sibling rows keep their own values and identity.
    (expect-value (label "Cabin amount") "300.00")
    (expect-text (test-id "expense-Cabin-shares") "Ana $100.00, Ben $100.00, Chloe $100.00")
    (expect-value (label "Taxi amount") "24.00")
    (expect-text (test-id "expense-Taxi-shares") "Ben $12.00, Chloe $12.00")
    (expect-text (test-id "person-Ana-net") "+$170.00")
    (expect-text (test-id "person-Ben-net") "-$52.00")
    (expect-text (test-id "person-Chloe-net") "-$118.00")
    (expect-text (test-id "trip-total") "$414.00")
    (expect-text (test-id "trip-balances-check") "$0.00")
    (expect-text (test-id "transfer-Chloe>Ana") "Chloe pays Ana")
    (expect-text (test-id "transfer-Chloe>Ana-amount") "$118.00")
    (expect-text (test-id "transfer-Ben>Ana") "Ben pays Ana")
    (expect-text (test-id "transfer-Ben>Ana-amount") "$52.00")
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
    ; One more patch than before the totals were laid out as a stat grid: the new
    ; "Per person" figure is derived from the same trip signal as the bill total,
    ; so editing an amount now repaints one extra numeric sink.
  )
)
