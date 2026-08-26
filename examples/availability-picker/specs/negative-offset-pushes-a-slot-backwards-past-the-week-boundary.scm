(test "Availability picker — negative offset pushes a slot backwards past the week boundary"
  (steps
    ; Given the state established by earlier scenarios
    (mark-metrics)
    (click (role button :name "Mark review available"))
    (click (role button :name "Mark review busy"))
    (mark-metrics)
    (select-option (label "Timezone") "auckland")
    (click (role button :name "Mark review available"))
    (select-option (label "Timezone") "kolkata")

    ; negative offset pushes a slot backwards past the week boundary
    (select-option (label "Timezone") "nyc")
    (expect-text (test-id "zone-label") "Timezone: New York UTC-05:00")
    (expect-text (test-id "when-sunrise") "Sun 19:00-20:00")
    (expect-text (test-id "when-standup") "Mon 04:00-04:30")
    (expect-text (test-id "when-review") "Mon 04:15-05:15")
    (expect-text (test-id "when-midnight") "Mon 18:30-19:00")
    (expect-text (test-id "when-focus") "Wed 07:00-09:00")
    (expect-text (test-id "free-days") "Tue, Thu, Fri, Sat")
  )
)
