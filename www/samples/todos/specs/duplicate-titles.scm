(test "a title already on the list is not added again"
  (steps
    (fill (label "Title") "Buy milk")
    (submit (role form :name "New todo"))
    (fill (label "Title") "Buy milk")
    (submit (role form :name "New todo"))
    (expect-text (test-id "remaining") "1 item left")
    (expect-value (label "Title") "Buy milk")))
