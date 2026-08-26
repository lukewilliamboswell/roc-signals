(test "Dependency scheduler — Write spec is the head of spec > api > sync > qa > launch, so delaying it"
  (steps
    ; Write spec is the head of spec > api > sync > qa > launch, so delaying it
    ; by a day moves every row. `set_text` counts the DOM text writes the engine
    ; actually made: 7 task lines plus the project summary and the focus readout.
    ; No row is torn down and rebuilt to do it.

    (mark-metrics)
    (click (role button :name "Delay Write spec"))
    (expect-metric-delta set_text 9)
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_reused 7)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta scopes_created 0)
    (expect-metric-delta scopes_disposed 0)
    (expect-metric-delta-at-most patches_emitted 80)
    (expect-text (test-id "line-spec") "Write spec: day 1 to 3, 2 days, after none, critical")
    (expect-text (test-id "line-api") "Build API: day 3 to 7, 4 days, after spec, critical")
    (expect-text (test-id "line-ui") "Build UI: day 3 to 6, 3 days, after spec, slack 1 day")
    (expect-text (test-id "line-docs") "Write docs: day 3 to 4, 1 day, after spec, slack 7 days")
    (expect-text (test-id "line-sync") "Integrate: day 7 to 9, 2 days, after api+ui, critical")
    (expect-text (test-id "line-qa") "QA pass: day 9 to 11, 2 days, after sync, critical")
    (expect-text (test-id "line-launch") "Launch: day 11 to 11, milestone, after qa, critical")
    (expect-text (test-id "project-summary") "Project finishes on day 11 across 7 tasks")
    (click (role button :name "Pull in Write spec"))
    (expect-text (test-id "line-spec") "Write spec: day 0 to 2, 2 days, after none, critical")
    (expect-text (test-id "project-summary") "Project finishes on day 10 across 7 tasks")
  )
)
