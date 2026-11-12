(test "the list shows all, open or done todos"
  (setup (local-storage "todos" "+Buy milk\n-Call home"))
  (steps
    (expect-visible (label "Done: Buy milk"))
    (expect-visible (label "Done: Call home"))
    (click (role button :name "Show open"))
    (expect-absent (label "Done: Buy milk"))
    (expect-visible (label "Done: Call home"))
    ; Checking a todo off takes its row out of the open ones, so the step is
    ; a click: `check` would look for the box afterwards. The row was
    ; written, not the list compared: one row is removed and none is built.
    (mark-metrics)
    (click (label "Done: Call home"))
    (expect-absent (label "Done: Call home"))
    (expect-metric-delta rows_removed 1)
    (expect-metric-delta rows_created 0)
    (expect-text (test-id "remaining") "0 items left")
    (click (role button :name "Show done"))
    (expect-checked (label "Done: Buy milk") true)
    (expect-checked (label "Done: Call home") true)
    (click (role button :name "Show all"))
    (expect-local-storage "todos" "+Buy milk\n+Call home")))
