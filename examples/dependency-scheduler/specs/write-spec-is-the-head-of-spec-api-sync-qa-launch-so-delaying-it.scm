(test "Dependency scheduler — Write spec is the head of spec > api > sync > qa > launch, so delaying it"
  (steps
    ; Write spec is the head of spec > api > sync > qa > launch, so delaying it
    ; by a day moves every row. `set_text` counts the DOM text writes the engine
    ; actually made. No row is torn down and rebuilt to do it.

    (mark-metrics)
    (click (role button :name "Delay Write spec"))
    ; 11 writes: the 7 task windows, the project-span stat, the focus readout,
    ; the "Day 11" end of the timeline axis, and the "+1d" lag readout on the
    ; row that was actually dragged. The two beyond the old count of 9 are the
    ; axis label and the lag readout, both new in the timeline layout. Every
    ; slack figure is unchanged - shifting the head moves the whole plan without
    ; consuming anyone's float - so those 7 sinks stay quiet.
    (expect-metric-delta set_text 11)
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_reused 7)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta scopes_created 0)
    (expect-metric-delta scopes_disposed 0)
    ; Raised from 80. Every row now also carries a Gantt bar whose `style`
    ; attribute is a percentage of the project span, and the span itself grew
    ; from 10 to 11 days, so all 7 bars are repositioned as well as relabelled.
    (expect-metric-delta-at-most patches_emitted 88)
    (expect-text (test-id "line-spec") "Day 1 → 3")
    (expect-text (test-id "line-api") "Day 3 → 7")
    (expect-text (test-id "line-ui") "Day 3 → 6")
    (expect-text (test-id "line-docs") "Day 3 → 4")
    (expect-text (test-id "slack-docs") "7")
    (expect-text (test-id "line-sync") "Day 7 → 9")
    (expect-text (test-id "line-qa") "Day 9 → 11")
    (expect-text (test-id "line-launch") "Day 11 → 11")
    (expect-text (test-id "project-summary") "11 days")
    (click (role button :name "Pull in Write spec"))
    (expect-text (test-id "line-spec") "Day 0 → 2")
    (expect-text (test-id "project-summary") "10 days")
  )
)
