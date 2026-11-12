(test "Services — a request beyond the in-flight cap is refused, counted and answered Refused"
  (steps
    ; The program allows 8 awaited requests in flight; the page's
    ; subscriptions hold 3 of them, so the sixth timer finds the table full.
    (mark-metrics)
    (click (role button :name "Delay"))
    (click (role button :name "Delay"))
    (click (role button :name "Delay"))
    (click (role button :name "Delay"))
    (click (role button :name "Delay"))
    (expect-metric-delta effects_issued 5)
    (expect-metric-delta effects_refused 0)
    (expect-pending-effects 5)
    (click (role button :name "Delay"))
    ; Not issued: no FX command, a Refused result in a follow-up turn.
    (expect-metric-delta effects_issued 5)
    (expect-metric-delta effects_refused 1)
    (expect-pending-effects 5)
    (expect-text (test-id "delayed") "Refused")
    ; Freeing a slot lets the next one through.
    (run-effect 1)
    (expect-text (test-id "delayed") "Fired")
    (click (role button :name "Delay"))
    (expect-metric-delta effects_issued 6)
    (expect-metric-delta effects_refused 1)
    ; Delivered: the Refused follow-up and the fired timer.
    (expect-metric-delta effects_delivered 2)
    (expect-metric-delta effects_stale 0)
    (expect-metric-delta effects_cancelled 0)
    (expect-pending-effects 5)
  )
)
