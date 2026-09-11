(test "Conduit — article-list failure leaves the profile visible"
  (setup
    (manual-effects)
    (local-storage "conduit.jwt" "jwt.conduit.kim")
    (local-storage "conduit.username" "kim")
    (initial-location "/roc-signals/examples-web/conduit/#/profile/anna")
  )
  (steps
    (stub-http "profile" :url "/api/profiles/anna" :status 200 :body "{\"profile\":{\"username\":\"anna\",\"bio\":\"Signals platform notes.\",\"image\":\"https://example.test/avatars/anna.png\",\"following\":false}}")
    (run-effect 1)
    (expect-visible (text "@anna"))
    (stub-http-reject "profile articles unavailable" :kind network :detail "offline")
    (run-effect 2)
    (expect-visible (text "Request failed: Network(\"offline\")"))
    (expect-visible (text "@anna"))
  )
)
