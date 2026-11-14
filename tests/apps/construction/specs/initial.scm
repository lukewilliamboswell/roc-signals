(test "The default construction frame is legal"
  (steps
    (expect-text (role button :name "Trigger construction") "Trigger construction")
    (expect-text (role main) "Trigger constructionChoose a construction contract")))
