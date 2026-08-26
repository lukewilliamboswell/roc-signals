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
    (expect-text (test-id "focus-detail") "Focus Build UI: earliest start day 2, latest start day 3, slack 1 day, moved 0 days")
    ; One day of growth exactly consumes Build UI's slack: the diamond now has two
    ; critical branches and the project end has not moved.
    (click (role button :name "Extend Build UI"))
    (expect-text (test-id "line-ui") "Build UI: day 2 to 6, 4 days, after spec, critical")
    (expect-text (test-id "line-api") "Build API: day 2 to 6, 4 days, after spec, critical")
    (expect-text (test-id "project-summary") "Project finishes on day 10 across 7 tasks")
    (expect-text (test-id "critical-path") "Critical path: Write spec -> Build API -> Build UI -> Integrate -> QA pass -> Launch")
    (expect-attr (test-id "row-ui") data-tone "critical")
    ; One more day and Build UI takes the critical path away from Build API.
    (click (role button :name "Extend Build UI"))
    (expect-text (test-id "line-ui") "Build UI: day 2 to 7, 5 days, after spec, critical")
    (expect-text (test-id "line-api") "Build API: day 2 to 6, 4 days, after spec, slack 1 day")
    (expect-text (test-id "line-sync") "Integrate: day 7 to 9, 2 days, after api+ui, critical")
    (expect-text (test-id "project-summary") "Project finishes on day 11 across 7 tasks")
    (expect-text (test-id "critical-path") "Critical path: Write spec -> Build UI -> Integrate -> QA pass -> Launch")
    (expect-attr (test-id "row-ui") data-tone "critical")
    (expect-attr (test-id "row-api") data-tone "slack")
    (expect-text (test-id "focus-detail") "Focus Build UI: earliest start day 2, latest start day 2, slack 0 days, moved 0 days")
    (click (role button :name "Shorten Build UI"))
    (click (role button :name "Shorten Build UI"))
    (expect-text (test-id "line-ui") "Build UI: day 2 to 5, 3 days, after spec, slack 1 day")
    (expect-text (test-id "critical-path") "Critical path: Write spec -> Build API -> Integrate -> QA pass -> Launch")
  )
)
