(test "Conduit — editor load network failure"
  (setup
    (local-storage "conduit.jwt" "jwt.conduit.kim")
    (local-storage "conduit.username" "kim")
    (initial-location "/roc-signals/examples/conduit/#/editor/network-matrix")
  )
  (steps
    (expect-document-title "Edit article - Conduit")
    (stub-http-reject "editor article unavailable" :kind network :detail "offline")
    (run-effect 1)
    (expect-visible (text "Request failed: Network(\"offline\")"))
  )
)
