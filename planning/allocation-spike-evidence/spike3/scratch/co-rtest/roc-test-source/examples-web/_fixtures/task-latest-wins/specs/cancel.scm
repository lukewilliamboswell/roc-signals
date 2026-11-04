(test "Ignoring a result is terminal until the next refresh"
  (setup (manual-effects))
  (steps
    (expect-pending-effects 1)
    (click (role button :name "Ignore result"))
    (expect-pending-effects 1)
    (expect-text (test-id "status") "Result ignored")
    (mark-metrics)
    (click (role button :name "Ignore result"))
    (expect-metric-delta set_text 0)

    ; Ignoring publication does not cancel the admitted HTTP effect.
    (stub-http "ignored request" :url "/api/latest/0" :status 200 :body "late result")
    (run-effect 1)
    (expect-pending-effects 0)
    (expect-text (test-id "status") "Result ignored")
    (click (role button :name "Refresh"))
    (expect-text (test-id "status") "Loading")
    (stub-http "fresh request" :url "/api/latest/1" :status 200 :body "fresh result")
    (run-effect 2)
    (expect-pending-effects 0)
    (expect-text (test-id "status") "Done: fresh result")
  )
)
