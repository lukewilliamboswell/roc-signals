(test "Native editors belong to one task and never cross to another"
  (steps
    ; Two tasks with identical field values. Nothing about their text can tell
    ; them apart, so only an explicit lifetime can keep their editors separate.
    (fill (label "New task title") "Duplicate")
    (click (role button :name "Add task"))
    (fill (label "New task title") "Duplicate")
    (click (role button :name "Add task"))
    (expect-value (label "Task title") "Duplicate")

    ; Re-selecting the task already open is the same document: its native
    ; inputs keep their caret, selection and undo history.
    (mark-metrics)
    (click (test-id "edit-task-8"))
    (expect-value (label "Task title") "Duplicate")
    (expect-metric-delta scopes_created 0)
    (expect-metric-delta scopes_disposed 0)

    ; Selecting the other, equal-valued task in the same column replaces the
    ; detail editors instead of handing the new task the previous one's inputs.
    (mark-metrics)
    (click (test-id "edit-task-7"))
    (expect-value (label "Task title") "Duplicate")
    (expect-metric-delta scopes_created 4)
    (expect-metric-delta scopes_disposed 4)

    ; Typing into the selected task is an edit, not a replacement.
    (mark-metrics)
    (fill (label "Task notes") "private")
    (fill (label "Task notes") "")
    (expect-metric-delta scopes_created 0)
    (expect-metric-delta scopes_disposed 0)

    ; Filtering rebuilds cards as the query narrows and widens; every one of
    ; these scopes is card structure. The detail editors keep their lifetime,
    ; so an unfinished edit and its history survive being filtered out.
    ; Rebuilding them would cost four more, the figure established above.
    (mark-metrics)
    (fill (label "Filter tasks") "welcome")
    (expect-absent (test-id "task-7"))
    (expect-value (label "Task title") "Duplicate")
    (fill (label "Filter tasks") "")
    (expect-visible (test-id "task-7"))
    (expect-value (label "Task title") "Duplicate")
    (expect-metric-delta scopes_created 25)
    (expect-metric-delta scopes_disposed 25)))
