(test "Availability picker — marking it busy creates an overlapping commitment conflict"
  (steps
    ; Given the state established by earlier scenarios
    (mark-metrics)
    (click (role button :name "Mark review available"))

    ; marking it busy creates an overlapping commitment conflict
    (click (role button :name "Mark review busy"))
    (expect-text (test-id "status-review") "Busy")
    (expect-text (test-id "conflict-review") "Conflict")
    (expect-text (test-id "conflict-standup") "Conflict")
    (expect-text (test-id "conflict-sunrise") "Clear")
    (expect-text (test-id "conflict-focus") "Clear")
    (expect-text (test-id "summary") "Available 3h 0m across 5 slots, 2 conflicts")
  )
)
