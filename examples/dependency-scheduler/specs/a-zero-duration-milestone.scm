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

    (expect-text (test-id "line-launch") "Launch: day 10 to 10, milestone, after qa, critical")
    (click (role button :name "Extend Launch"))
    (expect-text (test-id "line-launch") "Launch: day 10 to 11, 1 day, after qa, critical")
    (expect-text (test-id "project-summary") "Project finishes on day 11 across 7 tasks")
    (click (role button :name "Shorten Launch"))
    (expect-text (test-id "line-launch") "Launch: day 10 to 10, milestone, after qa, critical")
    ; Duration is clamped at zero, so a second shorten is a no-op.
    (click (role button :name "Shorten Launch"))
    (expect-text (test-id "line-launch") "Launch: day 10 to 10, milestone, after qa, critical")
  )
)
