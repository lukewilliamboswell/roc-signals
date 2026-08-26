(test "Availability picker — marking one slot available leaves its siblings alone"
  (steps
    ; marking one slot available leaves its siblings alone
    (mark-metrics)
    (click (role button :name "Mark review available"))
    (expect-text (test-id "status-review") "Available")
    (expect-text (test-id "summary") "4h 0m")
    (expect-text (test-id "stat-slots") "5")
    (expect-text (test-id "stat-conflicts") "0")
    (expect-text (test-id "when-standup") "Mon 09:00-09:30")
    (expect-text (test-id "status-standup") "Busy")
    (expect-text (test-id "status-sunrise") "Available")
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta scopes_created 0)
    (expect-metric-delta scopes_disposed 0)
    (expect-metric-delta-at-most set_text 3)
    ; two more patches than the plain-text version: the status badge and the
    ; block's own tint are class sinks off the same row signal, so marking one
    ; slot repaints exactly that block's two classes as well as its text.
    (expect-metric-delta-at-most patches_emitted 12)
  )
)
