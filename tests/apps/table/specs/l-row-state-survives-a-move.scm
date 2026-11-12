(test "Table — a row keeps its own state across a move in the window, and loses it on leaving"
  (steps
    ; Each row keeps a count of marks in a state of its own.
    (mark-metrics)
    (click (label "Mark 0"))
    (click (label "Mark 0"))
    (expect-text (label "Marks 0") "2")
    (expect-metric-delta derived_calls_into_roc 2)
    (expect-metric-delta patches_emitted 2)
    (expect-metric-delta set_text 2)
    (expect-metric-delta set_value 0)
    (expect-metric-delta set_checked 0)
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta rows_moved 0)
    ; Row 0 moved inside the window: the same row, with its state.
    (click (label "Later 0"))
    (expect-text (label "Marks 0") "2")
    (expect-text (test-id "main") "358:2:0 716:4:0 74:6:0 432:8:0 790:10:0 148:12:0 506:14:0 864:16:0 222:18:0 580:20:0 938:22:0 296:24:0 0:25:2 654:26:0 12:28:0 370:30:0 728:32:0 86:34:0 444:36:0 802:38:0 160:40:0 518:42:0 876:44:0 234:46:0 592:48:0 950:50:0 308:52:0 666:54:0 24:56:0 382:58:0 ")
    ; The window scrolled under it: still the same row.
    (click (role button :name "Down 1"))
    (click (label "Mark 716"))
    (expect-text (label "Marks 0") "2")
    (expect-text (test-id "main") "716:4:1 74:6:0 432:8:0 790:10:0 148:12:0 506:14:0 864:16:0 222:18:0 580:20:0 938:22:0 296:24:0 0:25:2 654:26:0 12:28:0 370:30:0 728:32:0 86:34:0 444:36:0 802:38:0 160:40:0 518:42:0 876:44:0 234:46:0 592:48:0 950:50:0 308:52:0 666:54:0 24:56:0 382:58:0 740:60:0 ")
    ; A row that leaves the window is disposed with its state: when it
    ; comes back it is a new row.
    (click (role button :name "Down page"))
    (expect-absent (label "Marks 0"))
    (click (role button :name "Up page"))
    (expect-text (label "Marks 0") "0")
    (expect-text (test-id "main") "716:4:0 74:6:0 432:8:0 790:10:0 148:12:0 506:14:0 864:16:0 222:18:0 580:20:0 938:22:0 296:24:0 0:25:0 654:26:0 12:28:0 370:30:0 728:32:0 86:34:0 444:36:0 802:38:0 160:40:0 518:42:0 876:44:0 234:46:0 592:48:0 950:50:0 308:52:0 666:54:0 24:56:0 382:58:0 740:60:0 ")
  )
)
