(test "Table — a window in local state, read directly or through a derive, and the table written with it change the rows drawn once"
  (steps
    ; Two lists of the few rows whose quantity is below 10. One shows
    ; three of them from the second, through a window it keeps in a state
    ; of its own; the other the first two of those, through a derive of
    ; that window.
    (click (role button :name "Show paged list"))
    (expect-text (test-id "paged") "679=Task 679 358=Task 358 37=Task 37 ")
    (expect-text (test-id "narrow") "679=Task 679 358=Task 358 ")
    ; One event moves the window down by one, a local write, and adds a
    ; row above it, a decision. One pass settles both, from the root: the
    ; window's state joins it at its own site, the derive of the window
    ; follows, and each list meets the table and its window together. Each
    ; holds the same rows before and after, and creates and removes none.
    ; The main list takes the new row at its top and lets its last row go,
    ; which is the one row created and the one removed. A local state and
    ; two cells were written.
    (mark-metrics)
    (click (role button :name "Add and page down"))
    (expect-text (test-id "count") "Rows: 1001")
    (expect-text (test-id "paged") "679=Task 679 358=Task 358 37=Task 37 ")
    (expect-text (test-id "narrow") "679=Task 679 358=Task 358 ")
    (expect-metric-delta rows_created 1)
    (expect-metric-delta rows_removed 1)
    (expect-metric-delta rows_moved 0)
    (expect-metric-delta rows_updated 0)
    (expect-metric-delta dirty_source_roots 3)
    ; And again: the windows follow the rows down.
    (mark-metrics)
    (click (role button :name "Add and page down"))
    (expect-text (test-id "paged") "679=Task 679 358=Task 358 37=Task 37 ")
    (expect-text (test-id "narrow") "679=Task 679 358=Task 358 ")
    (expect-metric-delta rows_created 1)
    (expect-metric-delta rows_removed 1)
    (expect-metric-delta rows_moved 0)
    ; A plain add leaves the windows where they are: the rows shift under
    ; them, and in each list one row leaves at the end and one enters at
    ; the start.
    (mark-metrics)
    (click (role button :name "Add"))
    (expect-text (test-id "paged") "0=Task 0 679=Task 679 358=Task 358 ")
    (expect-text (test-id "narrow") "0=Task 0 679=Task 679 ")
    (expect-metric-delta rows_created 3)
    (expect-metric-delta rows_removed 3)
  )
)
