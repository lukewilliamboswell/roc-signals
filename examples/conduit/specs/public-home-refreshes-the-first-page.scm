(test "Conduit — the public home shows seeded articles and refreshes them by key"
  (setup
    (initial-location "/roc-signals/examples/conduit/")
  )
  (steps
    (expect-visible (role link :name "Error envelopes worth rendering #23"))
    (expect-visible (text "Popular Tags"))
    (expect-attr (label "Articles") "aria-busy" "false")
    (expect-pending-effects 2)

    (stub-http "fresh anonymous feed" :url "/api/articles?limit=20&offset=0" :status 200 :body "{\"articles\":[{\"slug\":\"error-envelopes-worth-rendering-23\",\"title\":\"Error envelopes, revised\",\"description\":\"A fresh answer for the same article.\",\"tagList\":[\"webdev\",\"release\"],\"createdAt\":\"2026-06-08T01:00:00.000Z\",\"favorited\":false,\"favoritesCount\":0,\"author\":{\"username\":\"anna\",\"bio\":\"Signals platform notes and release engineering.\",\"image\":\"https://example.test/avatars/anna.png\",\"following\":false}}],\"articlesCount\":23}")
    (mark-metrics)
    (run-effect 1)
    (expect-visible (role link :name "Error envelopes, revised"))
    (expect-absent (role link :name "Error envelopes worth rendering #23"))
    (expect-metric-delta rows_created 0)

    (stub-http "fresh tags" :url "/api/tags" :status 200 :body "{\"tags\":[\"signals\",\"roc\"]}")
    (run-effect 2)
    (expect-pending-effects 0)
  )
)
