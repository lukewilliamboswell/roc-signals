(test "Table — a request whose key left and came back reads the new row"
  (setup (initial-location "/?n=3&draws=saves"))
  (steps
    (click (label "Remove 0"))
    (click (role button :name "Restore 0"))
    (expect-text (test-id "saves") "0=Task 0 1=Task 1 ")
    ; The new row 0 issued 7 and 8; the first row 0's requests are orphans.
    ; Its save is still current: the row the table holds is the one it saved.
    (stub-http "save" :url "/save" :status 200 :body "ok")
    (run-effect 1)
    (expect-text (test-id "saved") "saved:Task 0 ")
    (click (label "Remove 0"))
    (click (role button :name "Restore 0 retitled"))
    (expect-text (test-id "saves") "0=Again 1=Task 1 ")
    ; Retitled, the old save is no longer current and writes nothing, while
    ; the old read reads the new row.
    (mark-metrics)
    (stub-http "save again" :url "/save" :status 200 :body "ok")
    (run-effect 7)
    (stub-http "read" :url "/read" :status 200 :body "ok")
    (run-effect 2)
    (expect-text (test-id "saved") "saved:Task 0 read:Again ")
    (expect-metric-delta effects_delivered 2)
    (expect-metric-delta effects_skipped 0)))
