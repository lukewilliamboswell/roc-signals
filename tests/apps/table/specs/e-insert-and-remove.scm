(test "Table — a row inserted or removed costs its own placement and the one row that leaves or enters the window"
  (steps
    ; A new row with the lowest quantity: one placement in each list (it
    ; had no place before), it enters the main list at the top and the
    ; 30th row leaves. The count reads 1,001. Two cells written: the table
    ; and the next key.
    (mark-metrics)
    (click (role button :name "Add"))
    (expect-text (test-id "count") "Rows: 1001")
    (expect-text (label "Qty 1000") "-1000")
    (expect-metric-delta derived_calls_into_roc 18)
    (expect-metric-delta patches_emitted 13)
    (expect-metric-delta set_text 1)
    (expect-metric-delta set_value 1)
    (expect-metric-delta set_checked 1)
    (expect-metric-delta rows_created 1)
    (expect-metric-delta rows_removed 1)
    (expect-metric-delta rows_moved 0)
    (expect-metric-delta dirty_source_roots 2)
    (expect-text (test-id "main") "1000:-1000:0 0:0:0 358:2:0 716:4:0 74:6:0 432:8:0 790:10:0 148:12:0 506:14:0 864:16:0 222:18:0 580:20:0 938:22:0 296:24:0 654:26:0 12:28:0 370:30:0 728:32:0 86:34:0 444:36:0 802:38:0 160:40:0 518:42:0 876:44:0 234:46:0 592:48:0 950:50:0 308:52:0 666:54:0 24:56:0 ")
    ; That row removed: one placement in each list (it has no place
    ; after), and the row that left comes back in at the window's end.
    (mark-metrics)
    (click (label "Remove 1000"))
    (expect-text (test-id "count") "Rows: 1000")
    (expect-metric-delta derived_calls_into_roc 18)
    (expect-metric-delta patches_emitted 13)
    (expect-metric-delta set_text 1)
    (expect-metric-delta set_value 1)
    (expect-metric-delta set_checked 1)
    (expect-metric-delta rows_created 1)
    (expect-metric-delta rows_removed 1)
    (expect-metric-delta rows_moved 0)
    (expect-text (test-id "main") "0:0:0 358:2:0 716:4:0 74:6:0 432:8:0 790:10:0 148:12:0 506:14:0 864:16:0 222:18:0 580:20:0 938:22:0 296:24:0 654:26:0 12:28:0 370:30:0 728:32:0 86:34:0 444:36:0 802:38:0 160:40:0 518:42:0 876:44:0 234:46:0 592:48:0 950:50:0 308:52:0 666:54:0 24:56:0 382:58:0 ")
    ; Row 0 removed: the second reader shows it gone.
    (mark-metrics)
    (click (label "Remove 0"))
    (expect-text (test-id "row0") "Row 0: gone")
    (expect-metric-delta derived_calls_into_roc 18)
    (expect-metric-delta patches_emitted 14)
    (expect-metric-delta set_text 2)
    (expect-metric-delta set_value 1)
    (expect-metric-delta set_checked 1)
    (expect-metric-delta rows_created 1)
    (expect-metric-delta rows_removed 1)
    (expect-metric-delta rows_moved 0)
    (expect-text (test-id "main") "358:2:0 716:4:0 74:6:0 432:8:0 790:10:0 148:12:0 506:14:0 864:16:0 222:18:0 580:20:0 938:22:0 296:24:0 654:26:0 12:28:0 370:30:0 728:32:0 86:34:0 444:36:0 802:38:0 160:40:0 518:42:0 876:44:0 234:46:0 592:48:0 950:50:0 308:52:0 666:54:0 24:56:0 382:58:0 740:60:0 ")
  )
)
