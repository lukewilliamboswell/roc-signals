(test "Conduit — Feed error state renders in app"
  (setup
    (initial-location "/roc-signals/examples/conduit/#/")
  )
  (steps
    ; The feed fails independently of the still-queued tags effect.
    (expect-current-location "/roc-signals/examples/conduit/#/")
    (expect-pending-effects 2)
    (stub-http-reject "feed timeout" :kind timeout :detail "")
    (run-effect 1)
    (expect-visible (text "Request failed: Timeout"))
    (expect-pending-effects 1)
  )
)
