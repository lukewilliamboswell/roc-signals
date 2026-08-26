(test "Availability picker — resolving the conflict"
  (steps
    ; Given the state established by earlier scenarios
    (mark-metrics)
    (click (role button :name "Mark review available"))
    (click (role button :name "Mark review busy"))
    (mark-metrics)
    (select-option (label "Timezone") "auckland")

    ; resolving the conflict
    (click (role button :name "Mark review available"))
    (expect-text (test-id "status-review") "Available")
    (expect-text (test-id "conflict-review") "Clear")
    (expect-text (test-id "conflict-standup") "Clear")
    (expect-text (test-id "summary") "Available 4h 0m across 5 slots, 0 conflicts")
  )
)
