(test "Event actions use snapshots and preserve occurrences"
  (setup (manual-effects))
  (steps
    (expect-text (test-id "result") "waiting")
    (expect-pending-effects 0)
    (fill (label "Source") "beta")
    (expect-text (test-id "result") "waiting")
    (expect-pending-effects 0)

    ; The second event sees the settled write from the first event, together
    ; with the independent source value. Read changes never invoke actions.
    (click (role button :name "Append snapshot"))
    (expect-text (test-id "result") "waiting|beta")
    (click (role button :name "Append snapshot"))
    (expect-text (test-id "result") "waiting|beta|beta")

    ; Identical reads and identical payloads still start two requests.
    (click (role button :name "Ping"))
    (expect-pending-effects 1)
    (click (role button :name "Ping"))
    (expect-pending-effects 2)
    (fill (label "Source") "gamma")
    (expect-pending-effects 2)

    ; The action scope retires, but both admitted effects retain their snapshots.
    (click (role button :name "Toggle actions"))
    (expect-absent (role button :name "Ping"))
    (expect-pending-effects 2)
    (fill (label "Source") "delta")
    (click (role button :name "Toggle actions"))
    (click (role button :name "Append snapshot"))
    (expect-text (test-id "result") "waiting|beta|beta|delta")

    (stub-http "first ping" :url "/api/action-ping" :status 200 :body "first")
    (run-effect 1)
    (expect-text (test-id "status") "first")
    (stub-http "second ping" :url "/api/action-ping" :status 200 :body "second")
    (run-effect 2)
    (expect-text (test-id "status") "second")
    (expect-pending-effects 0)

    ; Warm scope-slot reuse and its preflight capacity (the scope table grows
    ; from four to eight entries), then require exact ownership plateaus.
    (click (role button :name "Toggle actions"))
    (click (role button :name "Toggle actions"))
    (click (role button :name "Toggle actions"))
    (click (role button :name "Toggle actions"))
    (mark-metrics)
    (click (role button :name "Toggle actions"))
    (click (role button :name "Toggle actions"))
    (expect-metric-delta retained_alloc_delta 0)
    (expect-metric-delta host_retained_bytes_delta 0)
    (expect-pending-effects 0)
    (mark-metrics)
    (click (role button :name "Toggle actions"))
    (click (role button :name "Toggle actions"))
    (expect-metric-delta retained_alloc_delta 0)
    (expect-metric-delta host_retained_bytes_delta 0)
  )
)
