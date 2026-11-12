(test "Table — two views of one table with different queries each follow a write"
  (steps
    ; Two lists over one table: the open rows by quantity, and the first
    ; five done rows by key.
    (expect-text (test-id "main") "0:0:0 358:2:0 716:4:0 74:6:0 432:8:0 790:10:0 148:12:0 506:14:0 864:16:0 222:18:0 580:20:0 938:22:0 296:24:0 654:26:0 12:28:0 370:30:0 728:32:0 86:34:0 444:36:0 802:38:0 160:40:0 518:42:0 876:44:0 234:46:0 592:48:0 950:50:0 308:52:0 666:54:0 24:56:0 382:58:0 ")
    (expect-text (test-id "done") "1=Task 1 3=Task 3 5=Task 5 7=Task 7 9=Task 9 ")
    ; Rows 0 and 358 done: both leave the first list. Row 0 enters the
    ; second at its top; row 358 is past its window.
    (click (label "Done 0"))
    (mark-metrics)
    (click (label "Done 358"))
    (expect-metric-delta derived_calls_into_roc 20)
    (expect-metric-delta rows_updated 0)
    (expect-metric-delta patches_emitted 12)
    (expect-metric-delta set_text 0)
    (expect-metric-delta set_value 1)
    (expect-metric-delta set_checked 1)
    (expect-metric-delta rows_created 1)
    (expect-metric-delta rows_removed 1)
    (expect-metric-delta rows_moved 0)
    (expect-text (test-id "main") "716:4:0 74:6:0 432:8:0 790:10:0 148:12:0 506:14:0 864:16:0 222:18:0 580:20:0 938:22:0 296:24:0 654:26:0 12:28:0 370:30:0 728:32:0 86:34:0 444:36:0 802:38:0 160:40:0 518:42:0 876:44:0 234:46:0 592:48:0 950:50:0 308:52:0 666:54:0 24:56:0 382:58:0 740:60:0 98:62:0 ")
    (expect-text (test-id "done") "0=Task 0 1=Task 1 3=Task 3 5=Task 5 7=Task 7 ")
    ; The first list asked for the done rows by key: both lists now show
    ; the same rows, each with its own row elements.
    (click (role button :name "Show done"))
    (click (role button :name "By key"))
    (expect-text (test-id "main") "0:0:0 1:919:0 3:757:0 5:595:0 7:433:0 9:271:0 11:109:0 13:947:0 15:785:0 17:623:0 19:461:0 21:299:0 23:137:0 25:975:0 27:813:0 29:651:0 31:489:0 33:327:0 35:165:0 37:3:0 39:841:0 41:679:0 43:517:0 45:355:0 47:193:0 49:31:0 51:869:0 53:707:0 55:545:0 57:383:0 ")
    (expect-text (test-id "done") "0=Task 0 1=Task 1 3=Task 3 5=Task 5 7=Task 7 ")
    ; A title edited through the first list's row is drawn in the second
    ; list's row of the same key.
    (mark-metrics)
    (fill (label "Title 1") "One")
    (expect-metric-delta derived_calls_into_roc 10)
    (expect-metric-delta rows_updated 2)
    (expect-metric-delta patches_emitted 2)
    (expect-metric-delta set_text 1)
    (expect-metric-delta set_value 1)
    (expect-metric-delta set_checked 0)
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta rows_moved 0)
    (expect-text (test-id "done") "0=Task 0 1=One 3=Task 3 5=Task 5 7=Task 7 ")
  )
)
