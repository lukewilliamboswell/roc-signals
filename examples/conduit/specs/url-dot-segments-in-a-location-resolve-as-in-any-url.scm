(test "Conduit URL — dot segments in a location resolve as in any url"
  (setup (initial-location "/roc-signals/examples/conduit/#/profile/kim/../anna"))
  (steps
    (expect-document-title "@anna - Conduit")
    (expect-request 1 :url "/api/profiles/anna")
    (expect-request 2 :url "/api/articles?limit=20&offset=0&author=anna")
  )
)
