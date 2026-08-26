(test "Availability picker — half hour offset zone"
  (steps
    ; Given the state established by earlier scenarios
    (mark-metrics)
    (click (role button :name "Mark review available"))
    (click (role button :name "Mark review busy"))
    (mark-metrics)
    (select-option (label "Timezone") "auckland")
    (click (role button :name "Mark review available"))

    ; half hour offset zone
    (select-option (label "Timezone") "kolkata")
    (expect-text (test-id "zone-label") "Timezone: Kolkata UTC+05:30")
    (expect-text (test-id "when-sunrise") "Mon 05:30-06:30")
    (expect-text (test-id "when-standup") "Mon 14:30-15:00")
    (expect-text (test-id "when-review") "Mon 14:45-15:45")
    (expect-text (test-id "when-midnight") "Tue 05:00-05:30")
    (expect-text (test-id "when-focus") "Wed 17:30-19:30")
    (expect-text (test-id "free-days") "Tue, Thu, Fri, Sat, Sun")
  )
)
