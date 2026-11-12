(test "Table — a view mounted after the table has changed is built from the table as it is"
  (steps
    ; The table changes while the third list is not mounted.
    (click (role button :name "Add"))
    (fill (label "Title 1000") "Newest")
    (click (label "Remove 0"))
    (expect-absent (test-id "late"))
    ; Mounted now, it is built from the table as it is: the condition, the
    ; query, the window, 1,000 placements and five rows.
    (mark-metrics)
    (click (role button :name "Show late list"))
    (expect-metric-delta derived_calls_into_roc 1008)
    (expect-metric-delta patches_emitted 9)
    (expect-metric-delta set_text 0)
    (expect-metric-delta set_value 0)
    (expect-metric-delta set_checked 0)
    (expect-metric-delta rows_created 5)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta rows_moved 0)
    (expect-text (test-id "late") "1000=Newest 999=Task 999 998=Task 998 997=Task 997 996=Task 996 ")
    ; From then on it absorbs the table's changes like the others: a new
    ; row is placed once in each of the three lists, and enters two.
    (mark-metrics)
    (click (role button :name "Add"))
    (expect-metric-delta derived_calls_into_roc 20)
    (expect-metric-delta patches_emitted 15)
    (expect-metric-delta set_text 1)
    (expect-metric-delta set_value 1)
    (expect-metric-delta set_checked 1)
    (expect-metric-delta rows_created 2)
    (expect-metric-delta rows_removed 2)
    (expect-metric-delta rows_moved 0)
    (expect-text (test-id "late") "1001=New 1001 1000=Newest 999=Task 999 998=Task 998 997=Task 997 ")
    (expect-text (test-id "main") "1001:-1001:0 1000:-1000:0 358:2:0 716:4:0 74:6:0 432:8:0 790:10:0 148:12:0 506:14:0 864:16:0 222:18:0 580:20:0 938:22:0 296:24:0 654:26:0 12:28:0 370:30:0 728:32:0 86:34:0 444:36:0 802:38:0 160:40:0 518:42:0 876:44:0 234:46:0 592:48:0 950:50:0 308:52:0 666:54:0 24:56:0 ")
    ; Hidden, its rows go with it; shown again, it is built again.
    (click (role button :name "Hide late list"))
    (expect-absent (test-id "late"))
    (click (label "Remove 1001"))
    (click (role button :name "Show late list"))
    (expect-text (test-id "late") "1000=Newest 999=Task 999 998=Task 998 997=Task 997 996=Task 996 ")
  )
)
