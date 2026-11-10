(test "Supersede — closing the panel with a request in flight disposes its layer"
  (steps
    (click (role button :name "Open panel"))
    (expect-pending-effects 2)
    (mark-metrics)
    (click (role button :name "Close panel"))
    (expect-absent (test-id "panel"))
    (expect-metric-delta scopes_disposed 2)
    ; The slow-answer timer stopped; the admitted request reparents and
    ; still completes, writing nothing.
    (expect-pending-effects 1)
    (stub-http "one" :url "/item/1" :status 200 :body "late")
    (mark-metrics)
    (run-effect 1)
    (expect-metric-delta patches_emitted 0)
    (expect-absent (test-id "panel"))
    (click (role button :name "Open panel"))
    (expect-text (test-id "panel") "loading 1; showing none; before none")
    (expect-pending-effects 2)
  )
)
