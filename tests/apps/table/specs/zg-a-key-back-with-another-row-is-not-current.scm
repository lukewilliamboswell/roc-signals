(test "Table — a request whose key came back with another row is not current"
  (setup (initial-location "/?n=3&draws=saves"))
  (steps
    (click (label "Remove 0"))
    (click (role button :name "Restore 0 retitled"))
    (expect-text (test-id "saves") "0=Again 1=Task 1 ")
    (expect-pending-effects 8)
    ; The old save was issued for another row and writes nothing; the old
    ; read reads the new row.
    (mark-metrics)
    (stub-http "save" :url "/save" :status 200 :body "ok")
    (run-effect 1)
    (stub-http "read" :url "/read" :status 200 :body "ok")
    (run-effect 2)
    (expect-text (test-id "saved") "read:Again ")
    (expect-metric-delta effects_delivered 2)
    (expect-metric-delta effects_skipped 0)))
