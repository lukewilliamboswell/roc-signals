(test "Dependency scheduler — the critical path moves when a parallel branch grows long enough"
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

    ; the critical path moves when a parallel branch grows long enough

    (select-option (label "Focus task") "ui")
    (expect-text (test-id "focus-detail") "Earliest day 2 · latest day 3 · slack 1 day · moved 0 days")
    ; One day of growth exactly consumes Build UI's slack: the diamond now has two
    ; critical branches and the project end has not moved.
    (click (role button :name "Extend Build UI"))
    (expect-text (test-id "line-ui") "Day 2 → 6")
    (expect-text (test-id "duration-ui") "4 days")
    (expect-text (test-id "status-ui") "Critical")
    (expect-text (test-id "line-api") "Day 2 → 6")
    (expect-text (test-id "project-summary") "10 days")
    (expect-text (test-id "critical-path") "Write spec → Build API → Build UI → Integrate → QA pass → Launch")
    (expect-attr (test-id "row-ui") data-tone "critical")
    ; One more day and Build UI takes the critical path away from Build API.
    (click (role button :name "Extend Build UI"))
    (expect-text (test-id "line-ui") "Day 2 → 7")
    (expect-text (test-id "duration-ui") "5 days")
    (expect-text (test-id "line-api") "Day 2 → 6")
    (expect-text (test-id "slack-api") "1")
    (expect-text (test-id "status-api") "Has slack")
    (expect-text (test-id "line-sync") "Day 7 → 9")
    (expect-text (test-id "project-summary") "11 days")
    (expect-text (test-id "critical-path") "Write spec → Build UI → Integrate → QA pass → Launch")
    (expect-attr (test-id "row-ui") data-tone "critical")
    (expect-attr (test-id "row-api") data-tone "slack")
    (expect-text (test-id "focus-detail") "Earliest day 2 · latest day 2 · slack 0 days · moved 0 days")
    (click (role button :name "Shorten Build UI"))
    (click (role button :name "Shorten Build UI"))
    (expect-text (test-id "line-ui") "Day 2 → 5")
    (expect-text (test-id "slack-ui") "1")
    (expect-text (test-id "critical-path") "Write spec → Build API → Integrate → QA pass → Launch")
  )
)
