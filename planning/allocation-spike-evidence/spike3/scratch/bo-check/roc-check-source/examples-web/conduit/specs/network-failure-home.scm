(test "Conduit — home feed and tags fail independently"
  (setup
    (manual-effects)
    (local-storage "conduit.jwt" "jwt.conduit.kim")
    (local-storage "conduit.username" "kim")
    (initial-location "/roc-signals/examples-web/conduit/#/")
  )
  (steps
    (expect-pending-effects 2)
    (stub-http-reject "tags unavailable" :kind network :detail "offline")
    (run-effect 2)
    (expect-visible (text "Tags are unavailable."))
    (expect-visible (text "Loading articles..."))
    (stub-http-reject "feed unavailable" :kind network :detail "offline")
    (run-effect 1)
    (expect-visible (text "Request failed: Network(\"offline\")"))
  )
)
