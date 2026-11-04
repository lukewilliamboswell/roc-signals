(test "Conduit — article network failure"
  (setup
    (manual-effects)
    (local-storage "conduit.jwt" "jwt.conduit.kim")
    (local-storage "conduit.username" "kim")
    (initial-location "/roc-signals/examples-web/conduit/#/article/article-network-failure")
  )
  (steps
    (stub-http-reject "article unavailable" :kind network :detail "offline")
    (run-effect 1)
    (expect-visible (text "Request failed: Network(\"offline\")"))
  )
)
