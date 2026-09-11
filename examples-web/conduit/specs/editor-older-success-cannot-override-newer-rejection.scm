(test "Conduit — an older publish success cannot override a newer rejection"
  (setup
    (manual-effects)
    (local-storage "conduit.jwt" "jwt.conduit.kim")
    (local-storage "conduit.username" "kim")
    (initial-location "/roc-signals/examples-web/conduit/#/editor")
  )
  (steps
    (fill (label "Title") "Conduit write path")
    (fill (label "Description") "Server-confirmed mutation")
    (fill (label "Body") "A complete draft")
    (click (role button :name "Publish Article"))
    (fill (label "Title") "")
    (click (role button :name "Publish Article"))
    (expect-pending-effects 2)

    ; The newer submission fails validation before the older request finishes.
    (stub-http "newer validation error" :url "/api/articles" :status 422 :body "{\"errors\":{\"title\":[\"can't be blank\"]}}")
    (run-effect 2)
    (expect-visible (text "title can't be blank"))
    (stub-http "older publish accepted" :url "/api/articles" :status 201 :body "{\"article\":{\"slug\":\"conduit-write-path\",\"title\":\"Conduit write path\",\"description\":\"Server-confirmed mutation\",\"body\":\"Published only after the task resolves.\",\"tagList\":[\"signals\",\"realworld\"],\"createdAt\":\"2026-07-01T08:00:00.000Z\",\"favorited\":false,\"favoritesCount\":0,\"author\":{\"username\":\"kim\",\"bio\":\"Reader.\",\"image\":\"\",\"following\":false}}}")
    (run-effect 1)
    (expect-pending-effects 0)
    (expect-current-location "/roc-signals/examples-web/conduit/#/editor")
    (expect-visible (text "title can't be blank"))
    (expect-value (label "Title") "")
  )
)
