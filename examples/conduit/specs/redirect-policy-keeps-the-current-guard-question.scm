(test "Conduit — protected routes still follow the current guard question"
  (setup
    (initial-location "/roc-signals/examples/conduit/#/login")
  )
  (steps
    ; Self answers drain atomically inside each turn; their ordering property
    ; is tested by the command-and-Self sequence model, not interleaved here.
    (expect-visible (role heading :name "Sign in"))
    (mark-metrics)
    (navigate "/roc-signals/examples/conduit/#/settings")
    (expect-current-location "/roc-signals/examples/conduit/#/login")
    (expect-visible (role heading :name "Sign in"))
    (navigate "/roc-signals/examples/conduit/#/editor")
    (expect-current-location "/roc-signals/examples/conduit/#/login")
    (expect-visible (role heading :name "Sign in"))
    (expect-pending-effects 0)
    (expect-metric-delta effects_cancelled 0)
  ))
