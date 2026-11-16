(test "Conduit — a tag, an article or a comment the server lists twice is drawn once or refused, never a fault"
  (setup
    (initial-location "/roc-signals/examples/conduit/#/")
  )
  (steps
    ; Tags are a set to the reader: a popular tag and an article's tag that
    ; the server lists twice are each drawn once.
    (stub-http "tags" :url "/api/tags" :status 200 :body "{\"tags\":[\"rust\",\"roc\",\"rust\"]}")
    (run-effect 2)
    (stub-http "feed" :url "/api/articles?limit=20&offset=0" :status 200 :body "{\"articles\":[{\"slug\":\"twice-tagged\",\"title\":\"Twice tagged\",\"description\":\"\",\"tagList\":[\"rust\",\"roc\",\"rust\"],\"createdAt\":\"2026-06-01T08:00:00.000Z\",\"favorited\":false,\"favoritesCount\":0,\"author\":{\"username\":\"anna\",\"bio\":\"\",\"image\":\"\",\"following\":false}}],\"articlesCount\":1}")
    (run-effect 1)
    (expect-visible (text "Twice tagged"))
    (expect-text (label "Tags") "rustroc")
    ; A feed is drawn keyed by slug: a page listing one article twice is
    ; refused where it arrives, naming the slug.
    (click (role link :name "roc"))
    (stub-http "tagged feed" :url "/api/articles?limit=20&offset=0&tag=roc" :status 200 :body "{\"articles\":[{\"slug\":\"twice\",\"title\":\"Listed twice\",\"description\":\"\",\"tagList\":[],\"createdAt\":\"2026-06-01T08:00:00.000Z\",\"favorited\":false,\"favoritesCount\":0,\"author\":{\"username\":\"anna\",\"bio\":\"\",\"image\":\"\",\"following\":false}},{\"slug\":\"twice\",\"title\":\"Listed twice\",\"description\":\"\",\"tagList\":[],\"createdAt\":\"2026-06-01T08:00:00.000Z\",\"favorited\":false,\"favoritesCount\":0,\"author\":{\"username\":\"anna\",\"bio\":\"\",\"image\":\"\",\"following\":false}}],\"articlesCount\":2}")
    (run-effect 3)
    (expect-visible (text "The server listed the article twice twice."))
    (expect-absent (text "Listed twice") :never-drawn)
    ; Comments are drawn keyed by id: a list holding one id twice is refused
    ; the same way, naming the id. A hash route keeps the document, so the
    ; article and its comments are effects 4 and 5.
    (navigate "/roc-signals/examples/conduit/#/article/twice-tagged")
    (stub-http "article" :url "/api/articles/twice-tagged" :status 200 :body "{\"article\":{\"slug\":\"twice-tagged\",\"title\":\"Twice tagged\",\"description\":\"\",\"body\":\"Body.\",\"tagList\":[\"rust\",\"rust\"],\"createdAt\":\"2026-06-01T08:00:00.000Z\",\"favorited\":false,\"favoritesCount\":0,\"author\":{\"username\":\"anna\",\"bio\":\"\",\"image\":\"\",\"following\":false}}}")
    (run-effect 4)
    (expect-visible (text "Body."))
    (stub-http "comments" :url "/api/articles/twice-tagged/comments" :status 200 :body "{\"comments\":[{\"id\":7,\"createdAt\":\"2026-06-01T08:00:00.000Z\",\"body\":\"First.\",\"author\":{\"username\":\"kim\",\"bio\":\"\",\"image\":\"\",\"following\":false}},{\"id\":7,\"createdAt\":\"2026-06-01T08:00:00.000Z\",\"body\":\"Again.\",\"author\":{\"username\":\"kim\",\"bio\":\"\",\"image\":\"\",\"following\":false}}]}")
    (run-effect 5)
    (expect-visible (text "The server listed the comment 7 twice."))
    (expect-absent (text "First.") :never-drawn)
  )
)
