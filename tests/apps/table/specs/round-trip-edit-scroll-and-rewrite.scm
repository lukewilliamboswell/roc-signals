(test "Table — round trip: edits, a filter there and back, adds, scrolls, rewrites and a late list return to the first list"
  (steps
    (expect-text (test-id "main") "0:0:0 358:2:0 716:4:0 74:6:0 432:8:0 790:10:0 148:12:0 506:14:0 864:16:0 222:18:0 580:20:0 938:22:0 296:24:0 654:26:0 12:28:0 370:30:0 728:32:0 86:34:0 444:36:0 802:38:0 160:40:0 518:42:0 876:44:0 234:46:0 592:48:0 950:50:0 308:52:0 666:54:0 24:56:0 382:58:0 ")
    (mark-metrics)
    ; A title, there and back.
    (fill (label "Title 12") "Twelve")
    (fill (label "Title 12") "Task 12")
    ; A row done and open again, through the list it went to.
    (click (label "Done 0"))
    (click (role button :name "Show done"))
    (click (role button :name "By key"))
    (click (label "Done 0"))
    (click (role button :name "Show open"))
    (click (role button :name "By qty"))
    ; A row added and removed.
    (click (role button :name "Add"))
    (click (role button :name "Add"))
    (click (role button :name "Down 1"))
    (click (role button :name "Up 1"))
    (click (role button :name "Down page"))
    (click (role button :name "Up page"))
    ; Every row toggled twice.
    (click (role button :name "Toggle all"))
    (click (role button :name "Toggle all"))
    ; The third list shown and hidden.
    (click (role button :name "Show late list"))
    (click (role button :name "Hide late list"))
    (click (role button :name "Edit 20"))
    (click (role button :name "Reset"))
    (expect-text (test-id "main") "0:0:0 358:2:0 716:4:0 74:6:0 432:8:0 790:10:0 148:12:0 506:14:0 864:16:0 222:18:0 580:20:0 938:22:0 296:24:0 654:26:0 12:28:0 370:30:0 728:32:0 86:34:0 444:36:0 802:38:0 160:40:0 518:42:0 876:44:0 234:46:0 592:48:0 950:50:0 308:52:0 666:54:0 24:56:0 382:58:0 ")
    (expect-text (test-id "done") "1=Task 1 3=Task 3 5=Task 5 7=Task 7 9=Task 9 ")
    (expect-text (test-id "count") "Rows: 1000")
  )
)
