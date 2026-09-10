(test "A new task with equal field values needs a distinct native editor lifetime"
  (steps
    (fill (label "New task title") "Duplicate")
    (click (role button :name "Add task"))
    (fill (label "New task title") "Duplicate")
    (click (role button :name "Add task"))
    (mark-metrics)
    (click (test-id "edit-task-7"))
    (expect-metric-delta scopes_created 1)))
