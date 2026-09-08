(test "Event actions use snapshots and preserve occurrences"
  (steps
    (expect-text (test-id "result") "waiting")
    (expect-pending-task "action-ping" 0)
    (fill (label "Source") "beta")
    (expect-text (test-id "result") "waiting")
    (expect-pending-task "action-ping" 0)

    ; The second event sees the settled write from the first event, together
    ; with the independent source value. Read changes never invoke actions.
    (click (role button :name "Append snapshot"))
    (expect-text (test-id "result") "waiting|beta")
    (click (role button :name "Append snapshot"))
    (expect-text (test-id "result") "waiting|beta|beta")

    ; Identical reads and identical payloads still start two requests.
    (click (role button :name "Ping"))
    (expect-pending-task "action-ping" 1)
    (expect-canceled-task "action-ping" 0)
    (click (role button :name "Ping"))
    (expect-pending-task "action-ping" 1)
    (expect-canceled-task "action-ping" 1)
    (fill (label "Source") "gamma")
    (expect-pending-task "action-ping" 1)
    (expect-canceled-task "action-ping" 1)

    ; The action's scope owns the started request as well as its read graph.
    (click (role button :name "Toggle actions"))
    (expect-absent (role button :name "Ping"))
    (expect-pending-task "action-ping" 0)
    (expect-canceled-task "action-ping" 2)
    (fill (label "Source") "delta")
    (click (role button :name "Toggle actions"))
    (click (role button :name "Append snapshot"))
    (expect-text (test-id "result") "waiting|beta|beta|delta")

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
    (expect-pending-task "action-ping" 0)
    (mark-metrics)
    (click (role button :name "Toggle actions"))
    (click (role button :name "Toggle actions"))
    (expect-metric-delta retained_alloc_delta 0)
    (expect-metric-delta host_retained_bytes_delta 0)
  )
)
