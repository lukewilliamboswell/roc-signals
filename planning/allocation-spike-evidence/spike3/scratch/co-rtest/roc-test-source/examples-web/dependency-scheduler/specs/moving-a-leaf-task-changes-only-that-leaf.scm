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
    ; compared, but only ONE row is patched: contrast set_text 3 here with
    ; set_text 11 for the head-of-chain move above.

    (mark-metrics)
    (click (role button :name "Delay Write docs"))
    ; Three text sinks, all inside the Write docs row: its scheduled window, its
    ; slack figure, and the "+Nd" readout between its two start buttons. The
    ; timeline row splits what used to be one sentence into separate cells, so a
    ; move that changes start and slack now writes two of them plus the lag.
    (expect-metric-delta set_text 3)
    (expect-metric-delta set_checked 0)
    (expect-metric-delta create_element 0)
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_reused 7)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta scopes_created 0)
    (expect-metric-delta scopes_disposed 0)
    (expect-text (test-id "line-docs") "Day 3 → 4")
    (expect-text (test-id "slack-docs") "6")
    (expect-text (test-id "line-spec") "Day 0 → 2")
    (expect-text (test-id "line-qa") "Day 8 → 10")
    (expect-text (test-id "deps-qa") "After Integrate")
    (expect-text (test-id "project-summary") "10 days")
    (click (role button :name "Pull in Write docs"))
    (expect-text (test-id "line-docs") "Day 2 → 3")
    (expect-text (test-id "slack-docs") "7")
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
    (expect-text (test-id "line-docs") "Day 2 → 3")
    (expect-text (test-id "slack-docs") "7")
  )
)
