(test "Supersede — one turn may refuse far more than 64 requests at the in-flight bound"
  (steps
    (mark-metrics)
    (click (role button :name "Flood"))
    ; 100 rows fetch at mount: 32 are admitted, and each of the other 68 is
    ; answered with Refused in a follow-up turn of its own. None of those
    ; turns queues another, so the follow-up chain is one deep.
    (expect-text (test-id "flood") "refused 68, answered 0")
    (expect-metric-delta effects_issued 32)
    (expect-metric-delta effects_refused 68)
    (expect-metric-delta effects_delivered 68)
    (expect-pending-effects 32)
    (stub-http "first" :url "/flood/f0" :status 200 :body "ok")
    (run-effect 1)
    (expect-text (test-id "flood") "refused 68, answered 1")
  )
)
