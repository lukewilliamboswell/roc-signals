(test "Supersede — one turn may refuse thousands of requests: the breadth bound does not count a turn's own follow-ups"
  ; The page offers the deluge only at this address.
  (setup (initial-location "/?offers=deluge"))
  (steps
    (mark-metrics)
    (click (role button :name "Deluge"))
    ; 5000 rows fetch at mount: 32 are admitted, and each of the other 4968
    ; is answered with Refused in a follow-up turn of its own. That is more
    ; follow-up turns than the breadth bound allows one call (4096 with 32
    ; in-flight slots), but the click's own turn queued every one of them,
    ; so their number is the rows that turn drew. The bound counts only the
    ; follow-ups that follow-ups queue.
    (expect-text (test-id "deluge") "refused 4968, answered 0")
    (expect-metric-delta rows_created 5000)
    (expect-metric-delta effects_issued 32)
    (expect-metric-delta effects_refused 4968)
    (expect-metric-delta effects_delivered 4968)
    (expect-pending-effects 32)
    ; The instance is live: an admitted request is answered as usual.
    (stub-http "first" :url "/deluge/f0" :status 200 :body "ok")
    (run-effect 1)
    (expect-text (test-id "deluge") "refused 4968, answered 1")
  )
)
