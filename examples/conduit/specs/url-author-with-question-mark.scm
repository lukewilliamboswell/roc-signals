(test "Conduit URL — author with question mark"
  (setup (initial-location "/roc-signals/examples/conduit/#/profile/anna%3Fx"))
  (steps
    (stub-http "exact profile" :url "/api/profiles/anna%3Fx" :status 200 :body "{\"profile\":{\"username\":\"anna?x\",\"bio\":\"Reserved name\",\"image\":\"\",\"following\":false}}")
    (run-effect 1)
    (expect-document-title "@anna?x - Conduit")
    (expect-visible (text "Reserved name"))
    (expect-request 1 :url "/api/articles?limit=20&offset=0&author=anna%3Fx")
  )
)
