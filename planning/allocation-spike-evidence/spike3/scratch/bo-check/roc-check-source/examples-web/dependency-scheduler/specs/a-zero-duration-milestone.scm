(test "Dependency scheduler — a zero duration milestone"
  (steps
    ; Given the state established by earlier scenarios
    (mark-metrics)
    (click (role button :name "Delay Write spec"))
    (click (role button :name "Pull in Write spec"))
    (mark-metrics)
    (click (role button :name "Delay Write docs"))
    (click (role button :name "Pull in Write docs"))
    (mark-metrics)
    (click (role button :name "Pull in Write docs"))
    (select-option (label "Focus task") "ui")
    (click (role button :name "Extend Build UI"))
    (click (role button :name "Extend Build UI"))
    (click (role button :name "Shorten Build UI"))
    (click (role button :name "Shorten Build UI"))

    ; a zero duration milestone

    (expect-text (test-id "line-launch") "Day 10 → 10")
    (expect-text (test-id "duration-launch") "milestone")
    (click (role button :name "Extend Launch"))
    (expect-text (test-id "line-launch") "Day 10 → 11")
    (expect-text (test-id "duration-launch") "1 day")
    (expect-text (test-id "project-summary") "11 days")
    (click (role button :name "Shorten Launch"))
    (expect-text (test-id "line-launch") "Day 10 → 10")
    (expect-text (test-id "duration-launch") "milestone")
    ; Duration is clamped at zero, so a second shorten is a no-op.
    (click (role button :name "Shorten Launch"))
    (expect-text (test-id "line-launch") "Day 10 → 10")
    (expect-text (test-id "duration-launch") "milestone")
  )
)
