(test "Data grid — inline editing"
  (steps
    ; Bring the page to the state this spec starts from.
    (mark-metrics)
    (click (role button :name "Sort by score"))
    (mark-metrics)
    (click (role button :name "Sort by score"))
    (click (role button :name "Sort by name"))
    (click (role button :name "Sort by name"))
    (click (role button :name "Sort by team"))
    (click (role button :name "Sort by id"))
    (mark-metrics)
    (click (role button :name "Next page"))
    (click (role button :name "Previous page"))
    (click (role button :name "First page"))

    ; Typing a note into a row.
    (mark-metrics)
    (fill (label "Note for Node-0003") "needs review")
    (expect-value (label "Note for Node-0003") "needs review")
    (expect-value (label "Note for Node-0002") "")
    (expect-value (label "Note for Node-0004") "")
    (expect-text (test-id "row-name-3") "Node-0003")
    (expect-text (test-id "row-score-3") "120")
    ; A note is a write of one row of the table. The view wakes that row
    ; and no other of the ten on the page; it compares no list of rows, so
    ; it counts none as reused.
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_reused 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta rows_moved 0)
    (expect-metric-delta rows_updated 1)
    (expect-metric-delta set_value 1)
    (expect-metric-delta dirty_source_roots 1)
    ; What the write evaluates: the summary's pass over the table, the
    ; written row's place in the view before and after, and that row's own
    ; readers.
    (expect-metric-delta-at-most derived_calls_into_roc 12)
    ; editing the last row on the page
    (mark-metrics)
    (fill (label "Note for Node-0009") "last on page")
    (expect-value (label "Note for Node-0009") "last on page")
    (expect-value (label "Note for Node-0008") "")
    (expect-value (label "Note for Node-0003") "needs review")
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_reused 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta rows_moved 0)
    (expect-metric-delta rows_updated 1)
    (expect-metric-delta set_value 1)
    ; notes survive paging away and back
    (click (role button :name "Next page"))
    (expect-value (label "Note for Node-0010") "")
    (click (role button :name "Previous page"))
    (expect-value (label "Note for Node-0003") "needs review")
    (expect-value (label "Note for Node-0009") "last on page")
  )
)
