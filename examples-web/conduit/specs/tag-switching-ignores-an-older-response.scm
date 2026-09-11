(test "Conduit — two tag requests run independently and only the newest publishes"
  (setup
    (manual-effects)
    (initial-location "/roc-signals/examples-web/conduit/#/")
  )
  (steps
    (stub-http "tags" :url "/api/tags" :status 200 :body "{\"tags\":[\"signals\",\"roc\"]}")
    (run-effect 2)
    (stub-http "initial feed" :url "/api/articles?limit=20&offset=0" :status 200 :body "{\"articles\":[],\"articlesCount\":0}")
    (run-effect 1)

    (click (role link :name "signals"))
    (expect-current-location "/roc-signals/examples-web/conduit/#/?tag=signals")
    (expect-document-title "Conduit")
    (expect-visible (text "Tag: signals"))
    (expect-pending-effects 1)
    (click (role link :name "roc"))
    (expect-current-location "/roc-signals/examples-web/conduit/#/?tag=roc")
    (expect-pending-effects 2)

    ; The newer response wins even though the older request is still queued.
    (stub-http "roc feed" :url "/api/articles?limit=20&offset=0&tag=roc" :status 200 :body "{\"articles\":[{\"slug\":\"latest-wins-requests\",\"title\":\"Latest-wins request replacement\",\"description\":\"Only the newest request may land.\",\"tagList\":[\"performance\"],\"createdAt\":\"2026-06-03T08:00:00.000Z\",\"favorited\":false,\"favoritesCount\":1,\"author\":{\"username\":\"anna\",\"bio\":\"Signals platform notes.\",\"image\":\"https://example.test/avatars/anna.png\",\"following\":false}}],\"articlesCount\":1}")
    (run-effect 4)
    (expect-visible (text "Latest-wins request replacement"))
    (stub-http "older signals feed" :url "/api/articles?limit=20&offset=0&tag=signals" :status 200 :body "{\"articles\":[],\"articlesCount\":0}")
    (run-effect 3)
    (expect-pending-effects 0)
    (expect-current-location "/roc-signals/examples-web/conduit/#/?tag=roc")
    (expect-visible (text "Latest-wins request replacement"))
    (expect-absent (text "No articles here yet."))
  )
)
