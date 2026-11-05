(test "the list is restored from local storage"
  (setup (local-storage "todos" "+Buy milk\n-Call home"))
  (steps
    (expect-checked (label "Done: Buy milk") true)
    (expect-text (test-id "remaining") "1 item left")))
