(test "Conduit — a filtered cold entry waits for its own feed"
  (setup
    (initial-location "/roc-signals/examples/conduit/#/?tag=roc")
  )
  (steps
    (expect-visible (text "Tag: roc"))
    (expect-visible (text "Loading tags..."))
    (expect-visible (text "Loading articles..."))
    (expect-absent (role link :name "Error envelopes worth rendering #23") :never-drawn)
    (expect-pending-effects 2)

    (stub-http "filtered feed" :url "/api/articles?limit=20&offset=0&tag=roc" :status 200 :body "{\"articles\":[],\"articlesCount\":0}")
    (run-effect 1)
    (expect-visible (text "No articles are here... yet."))
    (stub-http "tags" :url "/api/tags" :status 200 :body "{\"tags\":[\"roc\"]}")
    (run-effect 2)
    (expect-pending-effects 0)
  )
)
