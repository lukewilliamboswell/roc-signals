(test "Dependency scheduler — moving a leaf task changes only that leaf"
  (steps
    ; Given the state established by earlier scenarios
    (mark-metrics)
    (click (role button :name "Delay Write spec"))
    (click (role button :name "Pull in Write spec"))

    ; moving a leaf task changes only that leaf
    ;
    ; Write docs has no dependents and 7 days of slack, so delaying it cannot move
    ; the project end or any other task. The same 7 keyed rows survive and are
    ; compared, but exactly ONE text sink is patched: contrast set_text 1 here with
    ; set_text 9 for the head-of-chain move above.

    (mark-metrics)
    (click (role button :name "Delay Write docs"))
    (expect-metric-delta set_text 1)
    (expect-metric-delta set_checked 0)
    (expect-metric-delta create_element 0)
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_reused 7)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta scopes_created 0)
    (expect-metric-delta scopes_disposed 0)
    (expect-metric-delta-at-most patches_emitted 24)
    (expect-text (test-id "line-docs") "Write docs: day 3 to 4, 1 day, after spec, slack 6 days")
    (expect-text (test-id "line-spec") "Write spec: day 0 to 2, 2 days, after none, critical")
    (expect-text (test-id "line-qa") "QA pass: day 8 to 10, 2 days, after sync, critical")
    (expect-text (test-id "project-summary") "Project finishes on day 10 across 7 tasks")
    (click (role button :name "Pull in Write docs"))
    (expect-text (test-id "line-docs") "Write docs: day 2 to 3, 1 day, after spec, slack 7 days")
    ; A move that cannot go any earlier is a no-op all the way down the graph: the
    ; reducer returns an equal task list, the equality cutoff fires at the source,
    ; and nothing downstream is even asked to recompute.
    (mark-metrics)
    (click (role button :name "Pull in Write docs"))
    (expect-metric-delta set_text 0)
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_reused 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta scopes_created 0)
    (expect-metric-delta scopes_disposed 0)
    (expect-metric-delta-at-most patches_emitted 0)
    (expect-text (test-id "line-docs") "Write docs: day 2 to 3, 1 day, after spec, slack 7 days")
  )
)
