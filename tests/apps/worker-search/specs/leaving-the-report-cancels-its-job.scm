(test "Worker search — leaving the report cancels its job"
  (steps
    (click (role button :name "Report"))
    (expect-text (test-id "summary") "Computing…")
    (expect-pending-work "test.roc-signals/search/summarise" 1)
    (mark-metrics)
    (click (role button :name "Report"))
    (expect-absent (test-id "summary"))
    ; Work is scoped: disposing the report's site cancels its job.
    (expect-metric-delta effects_cancelled 1)
    (expect-metric-delta scopes_disposed 1)
    (expect-pending-effects 0)
    ; Coming back starts a fresh job, which runs to completion.
    (click (role button :name "Report"))
    (expect-metric-delta effects_issued 1)
    (run-effect 2)
    (expect-text (test-id "summary") "8 entries, longest basic-webserver")
  )
)
