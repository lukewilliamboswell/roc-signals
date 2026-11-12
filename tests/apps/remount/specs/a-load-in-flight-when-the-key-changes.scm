(test "Remount — a load in flight when the key changes is kept and its write skipped; the timer is cancelled"
  (steps
    ; Message a's load (1) and the pane's timer (2) are in flight.
    (expect-pending-effects 2)
    (expect-text (test-id "body") "loading")
    (mark-metrics)
    (click (role button :name "Open b"))
    (expect-metric-delta effects_reparented 1)
    (expect-metric-delta effects_cancelled 1)
    (expect-metric-delta effects_issued 2)
    ; a's load, b's load (3) and b's timer (4).
    (expect-pending-effects 3)
    (expect-text (test-id "body") "loading")
    ; a's answer reaches the remount site; the pane it would write is gone.
    (stub-http "a" :url "/messages/a" :status 200 :body "hello from a")
    (mark-metrics)
    (run-effect 1)
    (expect-metric-delta effects_delivered 1)
    (expect-metric-delta effects_skipped 1)
    (expect-metric-delta set_text 0)
    (expect-text (test-id "body") "loading")
    (stub-http "b" :url "/messages/b" :status 200 :body "hello from b")
    (run-effect 3)
    (expect-text (test-id "body") "b:hello from b")
    (expect-pending-effects 1)
  ))
