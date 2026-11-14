(test "Conduit URL — tag with ampersand"
  (setup (initial-location "/roc-signals/examples/conduit/#/?tag=c%26c"))
  (steps
    (expect-visible (text "Tag: c&c"))
    (stub-http "exact tag" :url "/api/articles?limit=20&offset=0&tag=c%26c" :status 200 :body "{\"articles\":[],\"articlesCount\":0}")
    (run-effect 1)
    (expect-visible (text "No articles are here... yet."))
  )
)
