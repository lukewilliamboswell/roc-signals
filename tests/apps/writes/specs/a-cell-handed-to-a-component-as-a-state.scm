(test "Writes — a component that takes a State is handed a cell: a write through the handle is a write of the cell, and wakes the cell's readers in the component and at the root"
  (steps
    (expect-text (test-id "name") "name=kim")
    (mark-metrics)
    (click (role button :name "Rename"))
    (expect-metric-delta derived_calls_into_roc 2)
    (expect-text (test-id "name") "name=lee")
    (expect-text (test-id "visits") "visits=1")
  ))
