(test "a command and two Self results withhold the second old reaction within one drain"
  (steps
    (mark-metrics)
    (fill (label "Question") "redirect")
    (expect-current-location "/current/next")
    (expect-value (label "Question") "after")
    (expect-text (test-id "answers") "redirect:follow")
    (expect-pending-effects 1)
    (expect-metric-delta effects_delivered 2)
    (expect-metric-delta effects_cancelled 0)
    (stub-http "new question" :url "/current/after/0" :status 200 :body "current")
    (run-effect 1)
    (expect-text (test-id "answers") "redirect:follow|after:0:current")
    (expect-pending-effects 0)))
