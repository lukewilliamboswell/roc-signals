(test "Conduit URL — slug with space and question mark"
  (setup (initial-location "/roc-signals/examples/conduit/#/article/a%20b%3Fc"))
  (steps
    (stub-http "exact article" :url "/api/articles/a%20b%3Fc" :status 200 :body "{\"article\":{\"slug\":\"a b?c\",\"title\":\"Exact reserved slug\",\"description\":\"Reserved description\",\"body\":\"Reserved body\",\"tagList\":[],\"createdAt\":\"2026-06-01T08:00:00.000Z\",\"favorited\":false,\"favoritesCount\":0,\"author\":{\"username\":\"anna\",\"bio\":\"\",\"image\":\"\",\"following\":false}}}")
    (run-effect 1)
    (expect-document-title "Exact reserved slug - Conduit")
    (expect-visible (text "Reserved body"))
  )
)
