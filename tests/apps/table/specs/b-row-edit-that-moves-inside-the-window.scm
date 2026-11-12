(test "Table — an edit that moves a row inside the window moves that row"
  (steps
    ; Row 0 is first, with quantity 0. Raised by 25 it passes twelve rows:
    ; one row moved, and its quantity's text. The 29 other rows of the
    ; window are not evaluated, compared or touched.
    (mark-metrics)
    (click (label "Later 0"))
    (expect-text (label "Qty 0") "25")
    (expect-metric-delta derived_calls_into_roc 9)
    (expect-metric-delta patches_emitted 2)
    (expect-metric-delta set_text 1)
    (expect-metric-delta set_value 0)
    (expect-metric-delta set_checked 0)
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta rows_moved 1)
    (expect-text (test-id "main") "358:2:0 716:4:0 74:6:0 432:8:0 790:10:0 148:12:0 506:14:0 864:16:0 222:18:0 580:20:0 938:22:0 296:24:0 0:25:0 654:26:0 12:28:0 370:30:0 728:32:0 86:34:0 444:36:0 802:38:0 160:40:0 518:42:0 876:44:0 234:46:0 592:48:0 950:50:0 308:52:0 666:54:0 24:56:0 382:58:0 ")
    ; A row in the middle of the window moved further down it.
    (mark-metrics)
    (click (label "Later 12"))
    (expect-metric-delta derived_calls_into_roc 9)
    (expect-metric-delta patches_emitted 2)
    (expect-metric-delta set_text 1)
    (expect-metric-delta set_value 0)
    (expect-metric-delta set_checked 0)
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta rows_moved 1)
    (expect-text (test-id "main") "358:2:0 716:4:0 74:6:0 432:8:0 790:10:0 148:12:0 506:14:0 864:16:0 222:18:0 580:20:0 938:22:0 296:24:0 0:25:0 654:26:0 370:30:0 728:32:0 86:34:0 444:36:0 802:38:0 160:40:0 518:42:0 876:44:0 234:46:0 592:48:0 950:50:0 308:52:0 12:53:0 666:54:0 24:56:0 382:58:0 ")
  )
)
