(test "Table — an edit that flips the filter takes the row out of one list and into another"
  (steps
    ; Row 0 done: it leaves the main list (open rows), where the 31st row
    ; enters, and enters the list of done rows at its top, where the fifth
    ; row leaves. Two rows removed and two created (14 holes and 1).
    (expect-visible (label "Qty 0"))
    (mark-metrics)
    (click (label "Done 0"))
    (expect-absent (label "Qty 0"))
    (expect-metric-delta derived_calls_into_roc 21)
    (expect-metric-delta patches_emitted 14)
    (expect-metric-delta set_text 0)
    (expect-metric-delta set_value 1)
    (expect-metric-delta set_checked 1)
    (expect-metric-delta rows_created 2)
    (expect-metric-delta rows_removed 2)
    (expect-metric-delta rows_moved 0)
    (expect-text (test-id "main") "358:2:0 716:4:0 74:6:0 432:8:0 790:10:0 148:12:0 506:14:0 864:16:0 222:18:0 580:20:0 938:22:0 296:24:0 654:26:0 12:28:0 370:30:0 728:32:0 86:34:0 444:36:0 802:38:0 160:40:0 518:42:0 876:44:0 234:46:0 592:48:0 950:50:0 308:52:0 666:54:0 24:56:0 382:58:0 740:60:0 ")
    (expect-text (test-id "done") "0=Task 0 1=Task 1 3=Task 3 5=Task 5 7=Task 7 ")
    ; Row 12 done: it leaves the main list; in the list of done rows it is
    ; past the window of five, which is not touched.
    (mark-metrics)
    (click (label "Done 12"))
    (expect-metric-delta derived_calls_into_roc 20)
    (expect-metric-delta patches_emitted 12)
    (expect-metric-delta set_text 0)
    (expect-metric-delta set_value 1)
    (expect-metric-delta set_checked 1)
    (expect-metric-delta rows_created 1)
    (expect-metric-delta rows_removed 1)
    (expect-metric-delta rows_moved 0)
    (expect-text (test-id "main") "358:2:0 716:4:0 74:6:0 432:8:0 790:10:0 148:12:0 506:14:0 864:16:0 222:18:0 580:20:0 938:22:0 296:24:0 654:26:0 370:30:0 728:32:0 86:34:0 444:36:0 802:38:0 160:40:0 518:42:0 876:44:0 234:46:0 592:48:0 950:50:0 308:52:0 666:54:0 24:56:0 382:58:0 740:60:0 98:62:0 ")
    (expect-text (test-id "done") "0=Task 0 1=Task 1 3=Task 3 5=Task 5 7=Task 7 ")
  )
)
