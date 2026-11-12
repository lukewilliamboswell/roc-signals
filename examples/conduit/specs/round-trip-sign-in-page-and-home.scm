; A round trip back to the page it started from: the soak (`--soak`)
; repeats the steps after `mark-metrics`, answering each request as this
; run answered it, and requires them to leave nothing allocated.
(test "Conduit — round trip: the sign-in page and back home, its feed and tags answered"
  (setup
    (initial-location "/roc-signals/examples/conduit/#/")
  )
  (steps
    (stub-http "feed" :url "/api/articles?limit=20&offset=0" :status 200 :body "{\"articles\":[{\"slug\":\"soak-a\",\"title\":\"Soak A\",\"description\":\"d\",\"body\":\"# Hi\\nthere\",\"tagList\":[\"roc\"],\"createdAt\":\"2026-06-01T08:00:00.000Z\",\"favorited\":false,\"favoritesCount\":1,\"author\":{\"username\":\"anna\",\"bio\":\"\",\"image\":\"\",\"following\":false}}],\"articlesCount\":1}")
    (run-effect 1)
    (stub-http "tags" :url "/api/tags" :status 200 :body "{\"tags\":[\"roc\",\"signals\"]}")
    (run-effect 2)
    (mark-metrics)
    (click (role link :name "Sign in"))
    (expect-current-location "/roc-signals/examples/conduit/#/login")
    (click (role link :name "Home"))
    (expect-current-location "/roc-signals/examples/conduit/#/")
    (stub-http "feed" :url "/api/articles?limit=20&offset=0" :status 200 :body "{\"articles\":[{\"slug\":\"soak-a\",\"title\":\"Soak A\",\"description\":\"d\",\"body\":\"# Hi\\nthere\",\"tagList\":[\"roc\"],\"createdAt\":\"2026-06-01T08:00:00.000Z\",\"favorited\":false,\"favoritesCount\":1,\"author\":{\"username\":\"anna\",\"bio\":\"\",\"image\":\"\",\"following\":false}}],\"articlesCount\":1}")
    (run-effect 3)
    (stub-http "tags" :url "/api/tags" :status 200 :body "{\"tags\":[\"roc\",\"signals\"]}")
    (run-effect 4)
    (expect-visible (text "Soak A"))
    (expect-pending-effects 0)
  )
)
