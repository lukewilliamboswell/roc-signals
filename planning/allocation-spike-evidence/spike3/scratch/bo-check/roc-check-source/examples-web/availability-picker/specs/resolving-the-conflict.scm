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
    (expect-text (test-id "conflict-review") "")
    (expect-text (test-id "conflict-standup") "")
    (expect-text (test-id "conflict-banner") "")
    (expect-text (test-id "summary") "4h 0m")
    (expect-text (test-id "stat-slots") "5")
    (expect-text (test-id "stat-conflicts") "0")
  )
)
