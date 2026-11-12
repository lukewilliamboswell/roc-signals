(test "Table — many rows written in one event are absorbed in one refresh, or rebuilt from when they are many"
  (steps
    ; The first 20 keys raised by one in one event: 20 keyed writes, one
    ; refresh. Each list places each written key before and after (80).
    ; Rows 0 and 12 are in the main window (3 holes each) and rows 1 to 9
    ; in the list of done rows (1 hole each); the two readers.
    (mark-metrics)
    (click (role button :name "Edit 20"))
    (expect-text (label "Qty 0") "1")
    (expect-text (label "Qty 12") "29")
    (expect-metric-delta derived_calls_into_roc 93)
    (expect-metric-delta rows_updated 7)
    (expect-metric-delta patches_emitted 2)
    (expect-metric-delta set_text 2)
    (expect-metric-delta set_value 0)
    (expect-metric-delta set_checked 0)
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta rows_moved 0)
    (expect-text (test-id "main") "0:1:0 358:2:0 716:4:0 74:6:0 432:8:0 790:10:0 148:12:0 506:14:0 864:16:0 222:18:0 580:20:0 938:22:0 296:24:0 654:26:0 12:29:0 370:30:0 728:32:0 86:34:0 444:36:0 802:38:0 160:40:0 518:42:0 876:44:0 234:46:0 592:48:0 950:50:0 308:52:0 666:54:0 24:56:0 382:58:0 ")
    ; The first 100 keys in one event. A record is weighed against the
    ; table, which is what a rebuild costs: 100 keys of 1,000 rows are
    ; absorbed too, each list placing each key before and after (400). The
    ; five rows of the main window among the 100 re-evaluate their holes
    ; (15), and the five done rows theirs (5); the two readers.
    (mark-metrics)
    (click (role button :name "Edit 100"))
    (expect-text (label "Qty 0") "2")
    (expect-metric-delta derived_calls_into_roc 422)
    (expect-metric-delta rows_updated 10)
    (expect-metric-delta patches_emitted 5)
    (expect-metric-delta set_text 5)
    (expect-metric-delta set_value 0)
    (expect-metric-delta set_checked 0)
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta rows_moved 0)
    (expect-text (test-id "main") "0:2:0 358:2:0 716:4:0 74:7:0 432:8:0 790:10:0 148:12:0 506:14:0 864:16:0 222:18:0 580:20:0 938:22:0 296:24:0 654:26:0 12:30:0 370:30:0 728:32:0 86:35:0 444:36:0 802:38:0 160:40:0 518:42:0 876:44:0 234:46:0 592:48:0 950:50:0 308:52:0 666:54:0 24:57:0 382:58:0 ")
    ; Every key in one event. A record of more than an eighth of the
    ; table's rows is not absorbed: each list builds its ordered keys
    ; again from the table (1,000 placements each) and compares its two
    ; windows, which hold the same rows. Every row drawn was written: the
    ; 30 of the main window re-evaluate their holes (90), the five done
    ; rows theirs (5); the two readers.
    (mark-metrics)
    (click (role button :name "Edit 1000"))
    (expect-text (label "Qty 0") "3")
    (expect-metric-delta derived_calls_into_roc 2097)
    (expect-metric-delta rows_updated 35)
    (expect-metric-delta patches_emitted 30)
    (expect-metric-delta set_text 30)
    (expect-metric-delta set_value 0)
    (expect-metric-delta set_checked 0)
    (expect-metric-delta rows_created 0)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta rows_moved 0)
    (expect-text (test-id "main") "0:3:0 358:3:0 716:5:0 74:8:0 432:9:0 790:11:0 148:13:0 506:15:0 864:17:0 222:19:0 580:21:0 938:23:0 296:25:0 654:27:0 12:31:0 370:31:0 728:33:0 86:36:0 444:37:0 802:39:0 160:41:0 518:43:0 876:45:0 234:47:0 592:49:0 950:51:0 308:53:0 666:55:0 24:58:0 382:59:0 ")
  )
)
