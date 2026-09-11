(test "Conduit — editor load network failure"
  (setup
    (manual-effects)
    (local-storage "conduit.jwt" "jwt.conduit.kim")
    (local-storage "conduit.username" "kim")
    (initial-location "/roc-signals/examples-web/conduit/#/editor/network-matrix")
  )
  (steps
    (expect-document-title "Edit article - Conduit")
    (stub-http-reject "editor article unavailable" :kind network :detail "offline")
    (run-effect 1)
    (expect-visible (text "Request failed: Network(\"offline\")"))
  )
)
