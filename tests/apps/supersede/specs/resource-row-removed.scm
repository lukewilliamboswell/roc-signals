(test "Supersede — a removed row's late answer writes nothing"
  (steps
    (click (role button :name "Load rows"))
    (expect-visible (test-id "row a"))
    (click (role button :name "Drop a"))
    (expect-absent (test-id "row a"))
    ; Its admitted request reparents to the each site and still completes.
    (expect-pending-effects 2)
    (stub-http "a0" :url "/row/a/0" :status 200 :body "late")
    (mark-metrics)
    (run-effect 1)
    (expect-metric-delta patches_emitted 0)
    (expect-absent (test-id "row a"))
    (expect-text (test-id "row b") "loading b/0")
  )
)
