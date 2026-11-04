(test "Status page — Empty incident feed disposes the timeline"
  (setup (manual-effects))
  (steps
    ; The initial incident effect is fifth; service checks stay queued.
    (stub-http "two incidents with five updates" :url "/api/status/incidents" :status 200 :body "inc-42~major~Elevated API error rate~10:02@Investigating elevated 5xx responses^10:20@Identified a bad deploy^10:45@Monitoring after rollback#inc-51~major~Delayed notification delivery~11:10@Investigating a backlog^11:40@Identified queue saturation")
    (run-effect 5)
    (expect-text (test-id "open-incident-count") "2")
    (expect-visible (role region :name "Incident inc-42"))
    (expect-visible (role region :name "Incident inc-51"))

    ; Refreshing to an empty feed disposes the list scope and its descendants.
    (tick-interval 5000)
    (stub-http "empty incident feed" :url "/api/status/incidents" :status 200 :body "")
    (mark-metrics)
    (run-effect 10)
    (expect-metric-delta rows_removed 0)
    (expect-metric-delta rows_created 0)
    (expect-metric-delta scopes_disposed 8)
    (expect-text (test-id "open-incident-count") "0")
    (expect-visible (text "No incidents reported in the last 90 days."))
    (expect-absent (role region :name "Incident inc-42"))
    (expect-absent (role region :name "Incident inc-51"))
  )
)
