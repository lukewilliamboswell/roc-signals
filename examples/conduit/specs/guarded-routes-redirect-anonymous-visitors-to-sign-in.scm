(test "Conduit — guarded routes redirect anonymous visitors to sign in"
  (setup
    (manual-effects)
    (initial-location "/roc-signals/examples/conduit/#/login")
  )
  (steps
    (navigate "/roc-signals/examples/conduit/#/settings")
    (expect-current-location "/roc-signals/examples/conduit/#/login")
    (navigate "/roc-signals/examples/conduit/#/editor")
    (expect-current-location "/roc-signals/examples/conduit/#/login")
    (expect-pending-effects 0)
  )
)
