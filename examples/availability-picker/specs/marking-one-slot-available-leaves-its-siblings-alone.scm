(test "Availability picker — marking one slot available leaves its siblings alone"
  (steps
    ; marking one slot available leaves its siblings alone
    (mark-metrics)
    (click (role button :name "Mark review available"))
    (expect-text (test-id "status-review") "Available")
    (expect-text (test-id "summary") "Available 4h 0m across 5 slots, 0 conflicts")
    (expect-text (test-id "when-standup") "Mon 09:00-09:30")
    (expect-text (test-id "status-standup") "Busy")
    (expect-text (test-id "status-sunrise") "Available")
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta scopes_created 0)
    (expect-metric-delta scopes_disposed 0)
    (expect-metric-delta-at-most set_text 3)
    (expect-metric-delta-at-most patches_emitted 10)
  )
)
