(test "The executor cap remembers refusal and admits a later operation"
  (steps
    (mark-metrics)
    ; The engine admits 64 requests; this separate executor limit is 32.
    (click (role button :name "Random batch 33"))
    (expect-pending-effects 33)
    (expect-metric-delta effects_issued 33)
    (expect-metric-delta effects_refused 0)
    (run-effect 1)
    (expect-text (test-id "result") "random 1")
    (expect-pending-effects 32)
    ; Completing the first operation does not retry the refused 33rd one.
    (run-effect 33)
    (expect-text (test-id "result") "failed Refused")
    (expect-pending-effects 31)
    (expect-metric-delta effects_refused 0)
    (click (role button :name "Random zero"))
    (expect-pending-effects 32)
    (run-effect 34)
    (expect-text (test-id "result") "random 0")
    (expect-pending-effects 31)
    (expect-metric-delta effects_issued 34)
    (expect-metric-delta effects_delivered 3)
    (expect-metric-delta effects_refused 0)))
