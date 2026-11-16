(test "The default construction frame is legal"
  (steps
    (expect-text (role button :name "Trigger construction") "Trigger construction")
    (expect-text (test-id "construction-frame") "Trigger constructionChoose a construction contract")))
