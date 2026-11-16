(test "Table — a request whose key left and came back reads the new row"
  (setup (initial-location "/?n=3&draws=saves"))
  (steps
    ; Row 0 leaves the table and comes back as it was: a new row lifetime,
    ; which issues 7 and 8, while the first row's 1 and 2 are orphans.
    (click (label "Remove 0"))
    (click (role button :name "Restore 0"))
    (expect-text (test-id "saves") "0=Task 0 1=Task 1 ")
    (expect-pending-effects 8)
    ; The old save is still current: the row the table holds is the one it
    ; saved.
    (stub-http "save" :url "/save" :status 200 :body "ok")
    (run-effect 1)
    (expect-text (test-id "saved") "saved:Task 0 ")))
