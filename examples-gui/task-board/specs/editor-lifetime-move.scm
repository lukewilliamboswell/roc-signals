(test "Moving the edited task rebuilds only its movement controls"
  (steps
    (click (test-id "edit-task-1"))
    (fill (label "Task notes") "Keep this note and its history through the move.")

    ; Control: moving a card the detail panel is not editing costs three
    ; scopes, all of them card structure.
    (mark-metrics)
    (custom-event (test-id "column-Complete") "drop" "task-2")
    (expect-metric-delta scopes_created 3)
    (expect-metric-delta scopes_disposed 3)

    ; Moving the edited task costs exactly one more: the column-dependent
    ; movement controls. The text editors are not rebuilt, so the task keeps
    ; the inputs it was being edited in.
    (mark-metrics)
    (custom-event (test-id "column-Complete") "drop" "task-1")
    (expect-text (test-id "task-column") "Complete")
    (expect-value (label "Task notes") "Keep this note and its history through the move.")
    (expect-metric-delta scopes_created 4)
    (expect-metric-delta scopes_disposed 4)

    ; Reordering within a column changes neither.
    (mark-metrics)
    (click (role button :name "Move to top"))
    (expect-value (label "Task notes") "Keep this note and its history through the move.")
    (expect-metric-delta scopes_created 0)
    (expect-metric-delta scopes_disposed 0)))
