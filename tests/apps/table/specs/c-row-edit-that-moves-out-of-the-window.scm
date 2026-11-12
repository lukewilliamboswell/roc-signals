(test "Table — an edit that moves a row out of the window removes it and draws the row that enters"
  (steps
    ; Row 0 goes to the end of the 500 open rows: it leaves the window and
    ; the 31st row enters at its end. One row removed, one created with
    ; its 14 holes (11 in the row, 3 in the state nested in it, whose block
    ; is 10 commands).
    (mark-metrics)
    (click (label "Last 0"))
    (expect-absent (label "Qty 0"))
    (expect-text (label "Qty 740") "60")
    (expect-metric-delta derived_calls_into_roc 20)
    (expect-metric-delta patches_emitted 12)
    (expect-metric-delta set_text 0)
    (expect-metric-delta set_value 1)
    (expect-metric-delta set_checked 1)
    (expect-metric-delta rows_created 1)
    (expect-metric-delta rows_removed 1)
    (expect-metric-delta rows_moved 0)
    (expect-text (test-id "main") "358:2:0 716:4:0 74:6:0 432:8:0 790:10:0 148:12:0 506:14:0 864:16:0 222:18:0 580:20:0 938:22:0 296:24:0 654:26:0 12:28:0 370:30:0 728:32:0 86:34:0 444:36:0 802:38:0 160:40:0 518:42:0 876:44:0 234:46:0 592:48:0 950:50:0 308:52:0 666:54:0 24:56:0 382:58:0 740:60:0 ")
  )
)
