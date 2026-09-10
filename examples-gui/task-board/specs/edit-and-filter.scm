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
    ; priority-selection key, the reactive document-status style, and the
    ; card and detail avatar selectors derived from the task's assignee.
    ; The card meta line is two text nodes (tinted priority word, muted
    ; assignee), so each row change re-derives one extra text signal: +1.
    ; The window title is derived from the same document context, so an edit
    ; that dirties the board re-derives the title string once more: +1.
    (expect-metric-delta-at-most derived_calls_into_roc 39)
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
