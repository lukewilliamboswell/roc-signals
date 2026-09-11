(test "Package explorer — B. navigating away retires panel state but not admitted effects"
  (setup
    (manual-effects)
    ; A. deep link

    (initial-location "/packages/roc-json")
  )
  (steps
    ; B. navigating away retires panel state but not admitted effects

    (click (role link :name "Back to search"))
    (expect-current-location "/")
    (expect-document-title "Package Explorer")
    (expect-absent (role region :name "Package detail"))
    (expect-absent (role region :name "Overview"))
    (expect-cleanup "package detail panels" 1)
    (expect-pending-effects 4)
    ; Search is occurrence 1; the three retired panels are occurrences 2–4.
    (mark-metrics)
    (stub-http "retired overview" :url "/api/packages/detail?q=%72%6f%63%2d%6a%73%6f%6e" :status 200 :body "roc-json|Late overview|MIT|1")
    (run-effect 2)
    (stub-http "retired versions" :url "/api/packages/versions?q=%72%6f%63%2d%6a%73%6f%6e" :status 200 :body "1.0.0|2026-01-01")
    (run-effect 3)
    (stub-http "retired dependencies" :url "/api/packages/deps?q=%72%6f%63%2d%6a%73%6f%6e" :status 200 :body "roc-bytes|1.0.0")
    (run-effect 4)
    (expect-metric-delta patches_emitted 0)
    (expect-pending-effects 1)
    (expect-visible (role region :name "Package search"))
    (expect-absent (role region :name "Package detail"))
  )
)
