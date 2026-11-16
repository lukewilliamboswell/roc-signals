(test "Conduit URL — an author named dot dot has no page"
  (setup (initial-location "/roc-signals/examples/conduit/#/"))
  (steps
    (stub-http "feed" :url "/api/articles?limit=20&offset=0" :status 200 :body "{\"articles\":[{\"slug\":\"safe\",\"title\":\"Exact reserved slug\",\"description\":\"Reserved description\",\"tagList\":[],\"createdAt\":\"2026-06-01T08:00:00.000Z\",\"favorited\":false,\"favoritesCount\":0,\"author\":{\"username\":\"..\",\"bio\":\"\",\"image\":\"\",\"following\":false}}],\"articlesCount\":1}")
    (run-effect 1)
    (stub-http "tags" :url "/api/tags" :status 200 :body "{\"tags\":[]}")
    (run-effect 2)
    (click (role link :name ".."))
    (expect-current-location "/roc-signals/examples/conduit/#/not-found")
    (expect-document-title "Page not found - Conduit")
    (expect-pending-effects 0)
  )
)
