(test "current request round trip releases its reader and current-id index"
  (steps
    (expect-text (test-id "answers") "no results")
    (fill (label "Question") "A")
    (stub-http "A" :url "/current/A/0" :status 200 :body "answer")
    (run-effect 1)
    (expect-text (test-id "answers") "A:0:answer")
    (expect-pending-effects 0)
    (click (role button :name "Reset"))
    (expect-text (test-id "answers") "no results")
    (expect-text (test-id "progress") "none")
    (expect-text (test-id "site-status") "shown")
    (expect-text (test-id "local-status") "closed")
    (expect-pending-effects 0)))
