(test "Conduit — Pagination: 23 articles > two pages; page switch swaps the list"
  (setup
    (manual-effects)
    (local-storage "conduit.jwt" "jwt.conduit.kim")
    (local-storage "conduit.username" "kim")
    (initial-location "/roc-signals/examples-web/conduit/#/")
  )
  (steps
    (stub-http "tags" :url "/api/tags" :status 200 :body "{\"tags\":[]}")
    (run-effect 2)
    (stub-http "feed response" :url "/api/articles?limit=20&offset=0" :status 200 :body "{\"articles\":[{\"slug\":\"keyed-lists-without-tears\",\"title\":\"Keyed lists without tears\",\"description\":\"Field notes on stable row identity.\",\"tagList\":[\"signals\",\"webdev\"],\"createdAt\":\"2026-06-01T08:00:00.000Z\",\"favorited\":false,\"favoritesCount\":2,\"author\":{\"username\":\"anna\",\"bio\":\"Signals platform notes.\",\"image\":\"https://example.test/avatars/anna.png\",\"following\":false}},{\"slug\":\"budgeting-patches\",\"title\":\"Budgeting patches per interaction\",\"description\":\"Counting the work each click does.\",\"tagList\":[\"roc\"],\"createdAt\":\"2026-06-02T08:00:00.000Z\",\"favorited\":false,\"favoritesCount\":0,\"author\":{\"username\":\"max\",\"bio\":\"Queues and latency.\",\"image\":\"https://example.test/avatars/max.png\",\"following\":false}},{\"slug\":\"latest-wins-requests\",\"title\":\"Latest-wins request replacement\",\"description\":\"Only the newest request may land.\",\"tagList\":[\"performance\"],\"createdAt\":\"2026-06-03T08:00:00.000Z\",\"favorited\":false,\"favoritesCount\":1,\"author\":{\"username\":\"anna\",\"bio\":\"Signals platform notes.\",\"image\":\"https://example.test/avatars/anna.png\",\"following\":false}}],\"articlesCount\":23}")
    (run-effect 1)
    ; Pagination: 23 articles > two pages; page switch swaps the list
    (expect-visible (role link :name "2"))
    (mark-metrics)
    (click (role link :name "2"))
    (expect-current-location "/roc-signals/examples-web/conduit/#/?page=2")
    (expect-pending-effects 1)
    (stub-http "feed response" :url "/api/articles?limit=20&offset=20" :status 200 :body "{\"articles\":[{\"slug\":\"deep-links-that-survive\",\"title\":\"Deep links that survive reloads\",\"description\":\"Routing that owns its URLs.\",\"tagList\":[\"release\"],\"createdAt\":\"2026-06-04T08:00:00.000Z\",\"favorited\":false,\"favoritesCount\":3,\"author\":{\"username\":\"max\",\"bio\":\"Queues and latency.\",\"image\":\"https://example.test/avatars/max.png\",\"following\":false}}],\"articlesCount\":23}")
    (run-effect 3)
    (expect-visible (text "Deep links that survive reloads"))
    (expect-metric-delta-at-most active_graph_records_rebuilt 24)
  )
)
