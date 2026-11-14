(test "Conduit URL — reload of an encoded tag"
  (setup (initial-location "/roc-signals/examples/conduit/#/?tag=caf%C3%A9+au+lait"))
  (steps
    (expect-visible (text "Tag: café au lait"))
    (expect-request 1 :url "/api/articles?limit=20&offset=0&tag=caf%C3%A9+au+lait")
  )
)
