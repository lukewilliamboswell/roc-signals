(test "Availability picker — marking it busy creates an overlapping commitment conflict"
  (steps
    ; Given the state established by earlier scenarios
    (mark-metrics)
    (click (role button :name "Mark review available"))

    ; marking it busy creates an overlapping commitment conflict
    (click (role button :name "Mark review busy"))
    (expect-text (test-id "status-review") "Busy")
    (expect-text (test-id "conflict-review") "Clashes with Standup")
    (expect-text (test-id "conflict-standup") "Clashes with Design review")
    (expect-text (test-id "conflict-banner") "2 overlapping commitments: Standup, Design review")
    (expect-text (test-id "conflict-sunrise") "")
    (expect-text (test-id "conflict-focus") "")
    (expect-text (test-id "summary") "3h 0m")
    (expect-text (test-id "stat-slots") "5")
    (expect-text (test-id "stat-conflicts") "2")
  )
)
