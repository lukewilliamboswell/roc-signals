(test "Live task edits survive filtering and use sparse row updates"
  (steps
    (expect-visible (role heading :name "Launch Board"))
    (expect-value (label "Task title") "Sketch the welcome screen")
    (mark-metrics)
    (fill (label "Task title") "Welcome prototype")
    (expect-text (test-id "title-task-1") "Welcome prototype")
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta scopes_created 0)
    (expect-metric-delta stream_nodes_scanned 0)
    (expect-metric-delta active_graph_records_rebuilt 0)
    ; One edit updates the column summary, selected card title and its
    ; priority-tinted metadata style, the detail fields, the shared
    ; priority-selection key, and the reactive document-status style.
    (expect-metric-delta-at-most derived_calls_into_roc 35)
    (fill (label "Filter tasks") "KEYBOARD")
    (expect-absent (test-id "task-1"))
    (expect-visible (test-id "task-3"))
    (expect-value (label "Task title") "Welcome prototype")
    (fill (label "Task notes") "The editor remains open while its card is filtered out.\nKeep a second line for the next review.")
    (fill (label "Filter tasks") "")
    (expect-visible (test-id "task-1"))
    (click (test-id "edit-task-2"))
    (click (test-id "edit-task-1"))
    (expect-value (label "Task title") "Welcome prototype")
    (expect-value (label "Task notes") "The editor remains open while its card is filtered out.\nKeep a second line for the next review.")))
