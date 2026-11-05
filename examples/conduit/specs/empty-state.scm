(test "Conduit — Empty tag feed"
  (setup
    (initial-location "/roc-signals/examples/conduit/#/")
  )
  (steps
    ; Settle the initial feed and expose the tag link.
    (stub-http "initial feed" :url "/api/articles?limit=20&offset=0" :status 200 :body "{\"articles\":[],\"articlesCount\":0}")
    (run-effect 1)
    (stub-http "popular tags" :url "/api/tags" :status 200 :body "{\"tags\":[\"webdev\"]}")
    (run-effect 2)
    (click (role link :name "webdev"))
    (expect-current-location "/roc-signals/examples/conduit/#/?tag=webdev")
    (expect-pending-effects 1)
    (stub-http "empty webdev feed" :url "/api/articles?limit=20&offset=0&tag=webdev" :status 200 :body "{\"articles\":[],\"articlesCount\":0}")
    (run-effect 3)
    (expect-visible (text "No articles are here... yet."))
    (expect-pending-effects 0)
  )
)
