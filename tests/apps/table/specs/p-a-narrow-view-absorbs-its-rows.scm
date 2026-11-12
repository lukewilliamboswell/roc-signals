(test "Table — a view that keeps few rows of a large table absorbs a write of every row it keeps"
  (steps
    ; A fourth list, mounted on request: the 10 rows of 1,000 whose
    ; quantity is below 10, in the order of their quantities, every one of
    ; them drawn.
    (click (role button :name "Show few list"))
    (expect-text (test-id "few") "0=Task 0 679=Task 679 358=Task 358 37=Task 37 716=Task 716 395=Task 395 74=Task 74 753=Task 753 432=Task 432 111=Task 111 ")
    ; Those 10 rows written in one event, each by its key. What a rebuild
    ; costs is the table, 1,000 rows here, however few of them a list
    ; keeps, so a record of 10 keys is absorbed by every list: each of the
    ; three places each written key before and after (60). The rows drawn
    ; that were written re-evaluate their holes that read the row: the five
    ; in the main window (3 holes each) and the ten of the few list (1
    ; each). The first five done rows are not among them. The two readers.
    (mark-metrics)
    (click (role button :name "Retitle few"))
    (expect-text (test-id "few") "0=Task 0! 679=Task 679! 358=Task 358! 37=Task 37! 716=Task 716! 395=Task 395! 74=Task 74! 753=Task 753! 432=Task 432! 111=Task 111! ")
    (expect-value (label "Title 358") "Task 358!")
    (expect-text (test-id "row0") "Row 0: Task 0!")
    (expect-metric-delta derived_calls_into_roc 87)
    (expect-metric-delta rows_updated 15)
    (expect-metric-delta patches_emitted 16)
    (expect-metric-delta set_text 11)
    (expect-metric-delta set_value 5)
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta rows_moved 0)
    ; One of them again, by its own row: two placements in each list, the
    ; row's holes in the two lists that draw it, and the two readers.
    (mark-metrics)
    (fill (label "Title 358") "Second")
    (expect-text (test-id "few") "0=Task 0! 679=Task 679! 358=Second 37=Task 37! 716=Task 716! 395=Task 395! 74=Task 74! 753=Task 753! 432=Task 432! 111=Task 111! ")
    (expect-metric-delta derived_calls_into_roc 12)
    (expect-metric-delta rows_updated 2)
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta rows_moved 0)
  )
)
