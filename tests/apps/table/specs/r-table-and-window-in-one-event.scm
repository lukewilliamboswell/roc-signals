(test "Table — an event that writes the table and the window changes the rows drawn once"
  (steps
    ; A mark on the first row and on the last, each a state of the row's
    ; own: what a row loses if it is ever removed and created again.
    (click (label "Mark 0"))
    (click (label "Mark 382"))
    (expect-text (test-id "main") "0:0:1 358:2:0 716:4:0 74:6:0 432:8:0 790:10:0 148:12:0 506:14:0 864:16:0 222:18:0 580:20:0 938:22:0 296:24:0 654:26:0 12:28:0 370:30:0 728:32:0 86:34:0 444:36:0 802:38:0 160:40:0 518:42:0 876:44:0 234:46:0 592:48:0 950:50:0 308:52:0 666:54:0 24:56:0 382:58:1 ")
    ; One event adds a row above the window and moves the window down by
    ; one: three cells written, the table, the next key and the window.
    ; The window holds the same 30 rows before and after, so no row is
    ; created, removed or moved, and the marks stay. Taken one after the
    ; other, the table's write would push the last row out for the new
    ; one, and the window's would then swap them back.
    (mark-metrics)
    (click (role button :name "Add above"))
    (expect-text (test-id "count") "Rows: 1001")
    (expect-text (test-id "main") "0:0:1 358:2:0 716:4:0 74:6:0 432:8:0 790:10:0 148:12:0 506:14:0 864:16:0 222:18:0 580:20:0 938:22:0 296:24:0 654:26:0 12:28:0 370:30:0 728:32:0 86:34:0 444:36:0 802:38:0 160:40:0 518:42:0 876:44:0 234:46:0 592:48:0 950:50:0 308:52:0 666:54:0 24:56:0 382:58:1 ")
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta rows_moved 0)
    (expect-metric-delta rows_updated 0)
    (expect-metric-delta dirty_source_roots 3)
    (expect-metric-delta derived_calls_into_roc 5)
    (expect-metric-delta patches_emitted 1)
    ; The new row is there, one row up.
    (click (role button :name "Up 1"))
    (expect-text (label "Qty 1000") "-1000")
    (expect-text (label "Marks 0") "1")
    (expect-absent (label "Marks 382"))
  )
)
