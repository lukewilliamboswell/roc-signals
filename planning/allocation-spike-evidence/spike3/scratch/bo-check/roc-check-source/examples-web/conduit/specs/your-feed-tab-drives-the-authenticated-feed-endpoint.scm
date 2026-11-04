(test "Conduit — Your Feed tab drives the authenticated feed endpoint"
  (setup
    (manual-effects)
    (local-storage "conduit.jwt" "jwt.conduit.kim")
    (local-storage "conduit.username" "kim")
    (initial-location "/roc-signals/examples-web/conduit/#/")
  )
  (steps
    (stub-http "tags" :url "/api/tags" :status 200 :body "{\"tags\":[]}")
    (run-effect 2)
    (stub-http "global feed" :url "/api/articles?limit=20&offset=0" :status 200 :body "{\"articles\":[],\"articlesCount\":0}")
    (run-effect 1)
    ; Your Feed tab drives the authenticated feed endpoint
    (click (role link :name "Your Feed"))
    (expect-current-location "/roc-signals/examples-web/conduit/#/?feed=yours")
    (expect-visible (role link :name "Your Feed"))
    (expect-pending-effects 1)
    (stub-http "feed response" :url "/api/articles/feed?limit=20&offset=0" :status 200 :body "{\"articles\":[{\"slug\":\"keyed-lists-without-tears\",\"title\":\"Keyed lists without tears\",\"description\":\"Field notes on stable row identity.\",\"tagList\":[\"signals\",\"webdev\"],\"createdAt\":\"2026-06-01T08:00:00.000Z\",\"favorited\":false,\"favoritesCount\":2,\"author\":{\"username\":\"anna\",\"bio\":\"Signals platform notes.\",\"image\":\"https://example.test/avatars/anna.png\",\"following\":false}},{\"slug\":\"latest-wins-requests\",\"title\":\"Latest-wins request replacement\",\"description\":\"Only the newest request may land.\",\"tagList\":[\"performance\"],\"createdAt\":\"2026-06-03T08:00:00.000Z\",\"favorited\":false,\"favoritesCount\":1,\"author\":{\"username\":\"anna\",\"bio\":\"Signals platform notes.\",\"image\":\"https://example.test/avatars/anna.png\",\"following\":false}}],\"articlesCount\":2}")
    (run-effect 3)
    (expect-visible (text "Keyed lists without tears"))
  )
)
