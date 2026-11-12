(test "Table — a view that draws every row creates the row that enters and removes the row that leaves, and no other"
  (steps
    ; The few list draws every row it keeps (`Engine.every_row`), however
    ; many that comes to.
    (click (role button :name "Show few list"))
    (expect-text (test-id "few") "0=Task 0 679=Task 679 358=Task 358 37=Task 37 716=Task 716 395=Task 395 74=Task 74 753=Task 753 432=Task 432 111=Task 111 ")
    ; A new row has the lowest quantity. It enters the few list at the top
    ; and every row that was drawn stays: one row created there, none
    ; removed. In the main list it enters at the top and the 30th row
    ; leaves, as ever.
    (mark-metrics)
    (click (role button :name "Add"))
    (expect-text (test-id "few") "1000=New 1000 0=Task 0 679=Task 679 358=Task 358 37=Task 37 716=Task 716 395=Task 395 74=Task 74 753=Task 753 432=Task 432 111=Task 111 ")
    (expect-metric-delta rows_created 2)
    (expect-metric-delta rows_removed 1)
    (expect-metric-delta rows_moved 0)
    (expect-metric-delta rows_updated 0)
    ; And another: the list grows by a row each time.
    (mark-metrics)
    (click (role button :name "Add"))
    (expect-text (test-id "few") "1001=New 1001 1000=New 1000 0=Task 0 679=Task 679 358=Task 358 37=Task 37 716=Task 716 395=Task 395 74=Task 74 753=Task 753 432=Task 432 111=Task 111 ")
    (expect-metric-delta rows_created 2)
    (expect-metric-delta rows_removed 1)
    (expect-metric-delta rows_moved 0)
    ; A row whose quantity rises past 10 leaves the few list: one row
    ; removed there. In the main list it moves down the window.
    (mark-metrics)
    (click (label "Later 0"))
    (expect-text (test-id "few") "1001=New 1001 1000=New 1000 679=Task 679 358=Task 358 37=Task 37 716=Task 716 395=Task 395 74=Task 74 753=Task 753 432=Task 432 111=Task 111 ")
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 1)
    (expect-metric-delta rows_moved 1)
    ; A row removed from the table leaves both lists; the main list draws
    ; the row that takes the freed place.
    (mark-metrics)
    (click (label "Remove 1001"))
    (expect-text (test-id "few") "1000=New 1000 679=Task 679 358=Task 358 37=Task 37 716=Task 716 395=Task 395 74=Task 74 753=Task 753 432=Task 432 111=Task 111 ")
    (expect-metric-delta rows_created 1)
    (expect-metric-delta rows_removed 2)
    (expect-metric-delta rows_moved 0)
    ; A whole rewrite puts back the rows the table started with. The few
    ; list keeps the nine rows it still draws, creates row 0, which comes
    ; back, and removes the added row, which is gone. The main list
    ; removes the added row too, moves row 0 back to the top and draws the
    ; row that takes the freed place at its end.
    (mark-metrics)
    (click (role button :name "Reset"))
    (expect-text (test-id "few") "0=Task 0 679=Task 679 358=Task 358 37=Task 37 716=Task 716 395=Task 395 74=Task 74 753=Task 753 432=Task 432 111=Task 111 ")
    (expect-metric-delta rows_created 2)
    (expect-metric-delta rows_removed 2)
    (expect-metric-delta rows_moved 1)
    (expect-metric-delta rows_updated 43)
  )
)
