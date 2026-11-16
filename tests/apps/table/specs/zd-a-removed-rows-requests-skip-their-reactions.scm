(test "Table — a request whose row left the table counts as delivered and runs no reaction"
  (setup (initial-location "/?n=3&draws=saves"))
  (steps
    (expect-text (test-id "saves") "0=Task 0 1=Task 1 ")
    (expect-pending-effects 4)
    ; Row 0 leaves the table while its save (1) and its read (2) are in
    ; flight. Both reparent to the list; row 2 enters and issues 5 and 6.
    (mark-metrics)
    (click (label "Remove 0"))
    (expect-text (test-id "saves") "1=Task 1 2=Task 2 ")
    (expect-pending-effects 6)
    (expect-metric-delta effects_reparented 2)
    ; Progress, the save's answer and the read's answer: none can read
    ; the row, so each is skipped, and the instance goes on.
    (mark-metrics)
    (progress-effect 1 receiving 4 unknown)
    (stub-http "save" :url "/save" :status 200 :body "ok")
    (run-effect 1)
    (stub-http "read" :url "/read" :status 200 :body "ok")
    (run-effect 2)
    (expect-text (test-id "saved") "")
    (expect-pending-effects 4)
    (expect-metric-delta effects_progress 1)
    (expect-metric-delta effects_delivered 2)
    (expect-metric-delta effects_skipped 3)
    (expect-metric-delta patches_emitted 0)
    ; The rows still drawn answer as ever.
    (stub-http "save again" :url "/save" :status 200 :body "ok")
    (run-effect 3)
    (expect-text (test-id "saved") "saved:Task 1 ")))
