(test "Conduit — profile network failure"
  (setup
    (manual-effects)
    (local-storage "conduit.jwt" "jwt.conduit.kim")
    (local-storage "conduit.username" "kim")
    (initial-location "/roc-signals/examples-web/conduit/#/profile/profile-network-failure")
  )
  (steps
    (stub-http-reject "profile unavailable" :kind network :detail "offline")
    (run-effect 1)
    (expect-visible (text "Request failed: Network(\"offline\")"))
  )
)
