(test "Conduit — comments failure leaves the article visible"
  (setup
    (manual-effects)
    (local-storage "conduit.jwt" "jwt.conduit.kim")
    (local-storage "conduit.username" "kim")
    (initial-location "/roc-signals/examples-web/conduit/#/article/network-matrix")
  )
  (steps
    (expect-pending-effects 2)
    (stub-http "article" :url "/api/articles/network-matrix" :status 200 :body "{\"article\":{\"slug\":\"network-matrix\",\"title\":\"Network matrix\",\"description\":\"Failure coverage.\",\"body\":\"Network body.\",\"tagList\":[\"signals\"],\"createdAt\":\"2026-07-02T08:00:00.000Z\",\"favorited\":false,\"favoritesCount\":0,\"author\":{\"username\":\"anna\",\"bio\":\"Signals platform notes.\",\"image\":\"https://example.test/avatars/anna.png\",\"following\":false}}}")
    (run-effect 1)
    (expect-visible (text "Network matrix"))
    (stub-http-reject "comments unavailable" :kind network :detail "offline")
    (run-effect 2)
    (expect-visible (text "Request failed: Network(\"offline\")"))
    (expect-visible (text "Network matrix"))
  )
)
