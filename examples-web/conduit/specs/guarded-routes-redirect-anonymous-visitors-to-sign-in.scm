(test "Conduit — guarded routes redirect anonymous visitors to sign in"
  (setup
    (manual-effects)
    (initial-location "/roc-signals/examples-web/conduit/#/login")
  )
  (steps
    (navigate "/roc-signals/examples-web/conduit/#/settings")
    (expect-current-location "/roc-signals/examples-web/conduit/#/login")
    (navigate "/roc-signals/examples-web/conduit/#/editor")
    (expect-current-location "/roc-signals/examples-web/conduit/#/login")
    (expect-pending-effects 0)
  )
)
